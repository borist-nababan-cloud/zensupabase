-- Migration: Enable secure read access for staff to view their own payroll details and employee info
-- Date: 2026-10-23
-- Rules:
-- 1. Users can ONLY read payroll records matching their own verified and approved kodekaryawan.
-- 2. Requires approval_status = 'APPROVED' and is_active = true.

-- 1. Policies for ot_hrd_karyawan_payroll_details
DROP POLICY IF EXISTS "Allow staff read own payroll details" ON public.ot_hrd_karyawan_payroll_details;

CREATE POLICY "Allow staff read own payroll details"
ON public.ot_hrd_karyawan_payroll_details
FOR SELECT
TO authenticated
USING (
    kodekaryawan IN (
        SELECT kodekaryawan
        FROM public.users_profile
        WHERE uid = auth.uid()
          AND approval_status = 'APPROVED'
          AND is_active = true
          AND kodekaryawan IS NOT NULL
    )
);

-- 2. Policies for ot_hrd_karyawan_info (for header card display: idkaryawan, namakaryawan, kode_outlet)
DROP POLICY IF EXISTS "Allow staff read own employee info" ON public.ot_hrd_karyawan_info;

CREATE POLICY "Allow staff read own employee info"
ON public.ot_hrd_karyawan_info
FOR SELECT
TO authenticated
USING (
    kodekaryawan IN (
        SELECT kodekaryawan
        FROM public.users_profile
        WHERE uid = auth.uid()
          AND approval_status = 'APPROVED'
          AND is_active = true
          AND kodekaryawan IS NOT NULL
    )
);

-- 3. Ensure master_outlet is readable by authenticated users for branch name resolution
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'public' AND tablename = 'master_outlet' AND policyname = 'Allow authenticated read master_outlet'
    ) THEN
        CREATE POLICY "Allow authenticated read master_outlet" 
        ON public.master_outlet FOR SELECT TO authenticated USING (true);
    END IF;
END $$;
