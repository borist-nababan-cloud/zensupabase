-- ==============================================================================
-- MIGRATION: 20261107123000_enable_management_payroll_read_and_evaluation_fields.sql
-- Description:
-- 1. Enable secure read access for management/evaluator roles on ot_hrd_karyawan_payroll_details
-- 2. Add payrollperiode and total_pengurang to hrd_report_tr
-- ==============================================================================

SET ROLE postgres;

-- 1. Allow management/evaluator roles to read payroll details for evaluation
DROP POLICY IF EXISTS "Allow management read all payroll details" ON public.ot_hrd_karyawan_payroll_details;

CREATE POLICY "Allow management read all payroll details"
ON public.ot_hrd_karyawan_payroll_details
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.users_profile
        WHERE uid = auth.uid()
          AND user_role IN (1, 5, 6, 8, 13, 14, 15, 16, 18)
    )
);

-- 2. Add payrollperiode and total_pengurang to hrd_report_tr
DO $$
BEGIN
    ALTER TABLE public.hrd_report_tr 
    ADD COLUMN IF NOT EXISTS payrollperiode TEXT;
EXCEPTION
    WHEN duplicate_column THEN null;
END $$;

DO $$
BEGIN
    ALTER TABLE public.hrd_report_tr 
    ADD COLUMN IF NOT EXISTS total_pengurang INTEGER DEFAULT 0;
EXCEPTION
    WHEN duplicate_column THEN null;
END $$;

