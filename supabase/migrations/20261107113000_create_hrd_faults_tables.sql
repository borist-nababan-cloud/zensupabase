-- ==============================================================================
-- MIGRATION: 20261107113000_create_hrd_faults_tables.sql
-- Description:
-- 1. Ensure Roles 15, 16, 19 exist in role_user
-- 2. Create hrd_master_faults (Master data jenis kesalahan & bobot pengurang)
-- 3. Create hrd_tr_faults (Pencatatan insiden/pelanggaran harian terapis)
-- 4. Seed initial 7 sample faults
-- 5. Create database view view_hrd_tr_faults
-- 6. Setup RLS policies & permissions
-- ==============================================================================

-- 1. Ensure Roles Exist in role_user
INSERT INTO public.role_user (id, role_name, created_at)
VALUES 
    (15, 'role_15_evaluator', now()),
    (16, 'role_16_hr', now()),
    (19, 'reception', now())
ON CONFLICT (id) DO UPDATE SET
    role_name = EXCLUDED.role_name;

-- 2. Master Faults Table
CREATE TABLE IF NOT EXISTS public.hrd_master_faults (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nama_faults TEXT NOT NULL,
    pengurang INTEGER NOT NULL CHECK (pengurang > 0),
    kategori TEXT NOT NULL CHECK (kategori IN ('Ringan', 'Sedang', 'Berat')),
    urutan INTEGER NOT NULL DEFAULT 0,
    active BOOLEAN NOT NULL DEFAULT true,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hrd_master_faults_active ON public.hrd_master_faults(active);
CREATE INDEX IF NOT EXISTS idx_hrd_master_faults_kategori ON public.hrd_master_faults(kategori);

-- 3. Therapist Faults Transaction Table
CREATE TABLE IF NOT EXISTS public.hrd_tr_faults (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tanggal DATE NOT NULL DEFAULT CURRENT_DATE,
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON UPDATE CASCADE,
    kodekaryawan TEXT NOT NULL REFERENCES public.ot_hrd_karyawan_info(kodekaryawan) ON UPDATE CASCADE,
    idkaryawan INTEGER NOT NULL,
    fault_id UUID REFERENCES public.hrd_master_faults(uid) ON DELETE SET NULL,
    nama_faults TEXT NOT NULL,
    kategori TEXT NOT NULL CHECK (kategori IN ('Ringan', 'Sedang', 'Berat')),
    pengurang INTEGER NOT NULL CHECK (pengurang > 0),
    keterangan TEXT,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hrd_tr_faults_tanggal_outlet ON public.hrd_tr_faults(tanggal, kode_outlet);
CREATE INDEX IF NOT EXISTS idx_hrd_tr_faults_karyawan ON public.hrd_tr_faults(kodekaryawan);
CREATE INDEX IF NOT EXISTS idx_hrd_tr_faults_fault_id ON public.hrd_tr_faults(fault_id);

-- 4. Seed Initial 7 Faults
INSERT INTO public.hrd_master_faults (nama_faults, pengurang, kategori, urutan, active)
SELECT * FROM (VALUES
    ('Tidak menggunakan masker ketika sakit', 3, 'Ringan', 1, true),
    ('Bau badan', 3, 'Ringan', 2, true),
    ('Tidak dapat berbahasa asing', 3, 'Ringan', 3, true),
    ('Tekanan dan Teknik', 6, 'Sedang', 4, true),
    ('Pijatan berbeda dengan therapis lain', 6, 'Sedang', 5, true),
    ('Therapis mengantuk / tertidur', 9, 'Berat', 6, true),
    ('Pengurangan waktu', 9, 'Berat', 7, true)
) AS v(nama_faults, pengurang, kategori, urutan, active)
WHERE NOT EXISTS (
    SELECT 1 FROM public.hrd_master_faults WHERE nama_faults = v.nama_faults
);

-- 5. View for Reporting & Easy Frontend Querying
CREATE OR REPLACE VIEW public.view_hrd_tr_faults AS
SELECT 
    f.uid,
    f.tanggal,
    f.kode_outlet,
    o.name_outlet,
    o.city,
    f.kodekaryawan,
    f.idkaryawan,
    k.namakaryawan,
    k.departemen,
    f.fault_id,
    f.nama_faults,
    f.kategori,
    f.pengurang,
    f.keterangan,
    f.created_by,
    f.created_at,
    f.update_by,
    f.update_at,
    COALESCE(u_upd.full_name, u_upd.email, 'Petugas') AS update_by_name,
    COALESCE(u_crt.full_name, u_crt.email, 'Petugas') AS created_by_name
FROM public.hrd_tr_faults f
LEFT JOIN public.master_outlet o ON f.kode_outlet = o.kode_outlet
LEFT JOIN public.ot_hrd_karyawan_info k ON f.kodekaryawan = k.kodekaryawan
LEFT JOIN public.users_profile u_upd ON f.update_by = u_upd.uid
LEFT JOIN public.users_profile u_crt ON f.created_by = u_crt.uid;

ALTER VIEW public.view_hrd_tr_faults SET (security_invoker = true);

-- 6. RLS & Permissions
ALTER TABLE public.hrd_master_faults ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hrd_tr_faults ENABLE ROW LEVEL SECURITY;

GRANT ALL ON TABLE public.hrd_master_faults TO authenticated, service_role;
GRANT ALL ON TABLE public.hrd_tr_faults TO authenticated, service_role;
GRANT SELECT ON TABLE public.view_hrd_tr_faults TO authenticated, service_role;

-- Master Faults Policies
DO $$
BEGIN
    DROP POLICY IF EXISTS "Allow authenticated read hrd_master_faults" ON public.hrd_master_faults;
    CREATE POLICY "Allow authenticated read hrd_master_faults"
        ON public.hrd_master_faults FOR SELECT
        TO authenticated, service_role
        USING (true);

    DROP POLICY IF EXISTS "Allow authenticated insert hrd_master_faults" ON public.hrd_master_faults;
    CREATE POLICY "Allow authenticated insert hrd_master_faults"
        ON public.hrd_master_faults FOR INSERT
        TO authenticated, service_role
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated update hrd_master_faults" ON public.hrd_master_faults;
    CREATE POLICY "Allow authenticated update hrd_master_faults"
        ON public.hrd_master_faults FOR UPDATE
        TO authenticated, service_role
        USING (true)
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated delete hrd_master_faults" ON public.hrd_master_faults;
    CREATE POLICY "Allow authenticated delete hrd_master_faults"
        ON public.hrd_master_faults FOR DELETE
        TO authenticated, service_role
        USING (true);
END $$;

-- TR Faults Policies
DO $$
BEGIN
    DROP POLICY IF EXISTS "Allow authenticated read hrd_tr_faults" ON public.hrd_tr_faults;
    CREATE POLICY "Allow authenticated read hrd_tr_faults"
        ON public.hrd_tr_faults FOR SELECT
        TO authenticated, service_role
        USING (true);

    DROP POLICY IF EXISTS "Allow authenticated insert hrd_tr_faults" ON public.hrd_tr_faults;
    CREATE POLICY "Allow authenticated insert hrd_tr_faults"
        ON public.hrd_tr_faults FOR INSERT
        TO authenticated, service_role
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated update hrd_tr_faults" ON public.hrd_tr_faults;
    CREATE POLICY "Allow authenticated update hrd_tr_faults"
        ON public.hrd_tr_faults FOR UPDATE
        TO authenticated, service_role
        USING (true)
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated delete hrd_tr_faults" ON public.hrd_tr_faults;
    CREATE POLICY "Allow authenticated delete hrd_tr_faults"
        ON public.hrd_tr_faults FOR DELETE
        TO authenticated, service_role
        USING (true);
END $$;

