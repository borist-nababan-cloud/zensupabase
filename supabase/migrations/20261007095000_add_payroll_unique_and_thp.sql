-- Supabase Migration: Add nilaithp and Unique Constraint for Upsert
SET ROLE postgres;
-- Description: Adds nilaithp explicitly for fast dashboard summaries and adds unique constraint for REST UPSERT.

DO $$ 
BEGIN
    ALTER TABLE public.ot_hrd_karyawan_payroll_details ADD COLUMN nilaithp DECIMAL(15,2);
EXCEPTION
    WHEN duplicate_column THEN null;
END $$;

DO $$ 
BEGIN
    ALTER TABLE public.ot_hrd_karyawan_payroll_details ADD CONSTRAINT uq_payroll_details_outlet_autonum UNIQUE (kode_outlet, local_autonum);
EXCEPTION
    WHEN duplicate_table THEN null;
    WHEN duplicate_object THEN null;
    WHEN others THEN
        IF SQLSTATE = '42P07' THEN null; -- relation already exists
        ELSE RAISE; END IF;
END $$;
