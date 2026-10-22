-- Migration: Enable secure read access for staff to view their own attendance records
-- Date: 2026-10-23
-- Rules:
-- 1. Users can ONLY read attendance records matching their own verified and approved kodekaryawan.
-- 2. Requires approval_status = 'APPROVED' and is_active = true.

GRANT SELECT ON TABLE public.ot_hrd_absen_harian TO authenticated;

DROP POLICY IF EXISTS "Allow staff read own attendance records" ON public.ot_hrd_absen_harian;

CREATE POLICY "Allow staff read own attendance records"
ON public.ot_hrd_absen_harian
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
