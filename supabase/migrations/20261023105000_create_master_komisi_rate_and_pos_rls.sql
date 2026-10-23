-- Migration: Create master_komisi_rate configuration table and enable secure therapist read access to ot_pos_trans_detail
-- Date: 2026-10-23

-- 1. Create master_komisi_rate table
CREATE TABLE IF NOT EXISTS public.master_komisi_rate (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    departemen TEXT UNIQUE NOT NULL,
    nama_departemen TEXT NOT NULL,
    rate_percent DECIMAL(5,2) NOT NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Seed initial commission rates (TR = 15%, TB = 10%)
INSERT INTO public.master_komisi_rate (departemen, nama_departemen, rate_percent, is_active)
VALUES
    ('TR', 'Terapis Reguler', 15.00, true),
    ('TB', 'Terapis Baru', 10.00, true)
ON CONFLICT (departemen) DO UPDATE 
SET 
    rate_percent = EXCLUDED.rate_percent,
    nama_departemen = EXCLUDED.nama_departemen,
    is_active = EXCLUDED.is_active,
    updated_at = NOW();

-- 3. Enable RLS and grants for master_komisi_rate
ALTER TABLE public.master_komisi_rate ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON TABLE public.master_komisi_rate TO anon, authenticated;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'public' AND tablename = 'master_komisi_rate' AND policyname = 'Allow all read master_komisi_rate'
    ) THEN
        CREATE POLICY "Allow all read master_komisi_rate"
            ON public.master_komisi_rate
            FOR SELECT
            USING (true);
    END IF;
END $$;

-- 4. Enable secure read access for staff on ot_pos_trans_detail
GRANT SELECT ON TABLE public.ot_pos_trans_detail TO authenticated;

DROP POLICY IF EXISTS "Allow staff read own trans detail" ON public.ot_pos_trans_detail;

CREATE POLICY "Allow staff read own trans detail"
ON public.ot_pos_trans_detail
FOR SELECT
TO authenticated
USING (
    kode_karyawan IN (
        SELECT kodekaryawan
        FROM public.users_profile
        WHERE uid = auth.uid()
          AND approval_status = 'APPROVED'
          AND is_active = true
          AND kodekaryawan IS NOT NULL
    )
    OR
    therapist_id IN (
        SELECT idkaryawan
        FROM public.ot_hrd_karyawan_info
        WHERE kodekaryawan IN (
            SELECT kodekaryawan
            FROM public.users_profile
            WHERE uid = auth.uid()
              AND approval_status = 'APPROVED'
              AND is_active = true
              AND kodekaryawan IS NOT NULL
        )
    )
);
