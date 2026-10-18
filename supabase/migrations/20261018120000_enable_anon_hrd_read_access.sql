-- Supabase Migration: Enable anon read access for HR tables in Zen Dashboard
-- Description: Grants SELECT privileges and creates RLS read policies for anon role on ot_hrd_absen_harian and ot_hrd_karyawan_info.

SET ROLE postgres;

-- 1. Table Grants to anon
GRANT SELECT ON TABLE public.ot_hrd_absen_harian TO anon;
GRANT SELECT ON TABLE public.ot_hrd_karyawan_info TO anon;

-- 2. RLS Policies for anon SELECT
DO $$ 
BEGIN
    -- ot_hrd_absen_harian
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_hrd_absen_harian' AND policyname = 'Allow anon read ot_hrd_absen_harian'
    ) THEN
        CREATE POLICY "Allow anon read ot_hrd_absen_harian" 
            ON public.ot_hrd_absen_harian 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;

    -- ot_hrd_karyawan_info
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_hrd_karyawan_info' AND policyname = 'Allow anon read ot_hrd_karyawan_info'
    ) THEN
        CREATE POLICY "Allow anon read ot_hrd_karyawan_info" 
            ON public.ot_hrd_karyawan_info 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;
END $$;
