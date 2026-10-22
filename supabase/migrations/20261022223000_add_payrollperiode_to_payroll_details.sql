-- Supabase Migration: Add payrollperiode column and index to ot_hrd_karyawan_payroll_details
-- Enables fast B-Tree indexed queries by outlet and payroll period without JSONB extraction overhead.
SET ROLE postgres;

DO $$ 
BEGIN
    ALTER TABLE public.ot_hrd_karyawan_payroll_details ADD COLUMN IF NOT EXISTS payrollperiode TEXT;
EXCEPTION
    WHEN duplicate_column THEN null;
END $$;

CREATE INDEX IF NOT EXISTS idx_payroll_details_outlet_periode 
ON public.ot_hrd_karyawan_payroll_details (kode_outlet, payrollperiode);

-- Backfill existing records from payroll_data JSONB if present
UPDATE public.ot_hrd_karyawan_payroll_details 
SET payrollperiode = payroll_data->>'payrollperiode'
WHERE payrollperiode IS NULL 
  AND payroll_data IS NOT NULL 
  AND payroll_data ? 'payrollperiode';
