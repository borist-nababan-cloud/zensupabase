-- ==============================================================================
-- MIGRATION: 20261114123500_create_hrd_kpi_variable_and_kpi_master_faults.sql
-- Description:
-- Creates Master Data tables for Departmental KPI (non-TR/TB):
-- 1. public.hrd_kpi_variable (Evaluation variables per department & category)
-- 2. public.hrd_kpi_master_faults (Master faults & deduction points for KPI)
-- ==============================================================================

-- 1. Master KPI Variables
CREATE TABLE IF NOT EXISTS public.hrd_kpi_variable (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id UUID NOT NULL REFERENCES public.hrd_report_tr_category(uid) ON DELETE RESTRICT,
    departemen TEXT NOT NULL,
    nama_variable TEXT NOT NULL,
    deskripsi TEXT,
    urutan INTEGER NOT NULL DEFAULT 0,
    active BOOLEAN NOT NULL DEFAULT true,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hrd_kpi_variable_departemen ON public.hrd_kpi_variable(departemen);
CREATE INDEX IF NOT EXISTS idx_hrd_kpi_variable_category ON public.hrd_kpi_variable(category_id);
CREATE INDEX IF NOT EXISTS idx_hrd_kpi_variable_active ON public.hrd_kpi_variable(active);

-- 2. Master KPI Faults (same structure as public.hrd_master_faults)
CREATE TABLE IF NOT EXISTS public.hrd_kpi_master_faults (
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

CREATE INDEX IF NOT EXISTS idx_hrd_kpi_master_faults_active ON public.hrd_kpi_master_faults(active);
CREATE INDEX IF NOT EXISTS idx_hrd_kpi_master_faults_kategori ON public.hrd_kpi_master_faults(kategori);

-- 3. Enable Row Level Security & Grants
ALTER TABLE public.hrd_kpi_variable ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hrd_kpi_master_faults ENABLE ROW LEVEL SECURITY;

GRANT ALL ON TABLE public.hrd_kpi_variable TO authenticated, service_role;
GRANT ALL ON TABLE public.hrd_kpi_master_faults TO authenticated, service_role;

-- Policies for hrd_kpi_variable
DO $$
BEGIN
    DROP POLICY IF EXISTS "Allow authenticated read hrd_kpi_variable" ON public.hrd_kpi_variable;
    CREATE POLICY "Allow authenticated read hrd_kpi_variable"
        ON public.hrd_kpi_variable FOR SELECT
        TO authenticated, service_role
        USING (true);

    DROP POLICY IF EXISTS "Allow authenticated insert hrd_kpi_variable" ON public.hrd_kpi_variable;
    CREATE POLICY "Allow authenticated insert hrd_kpi_variable"
        ON public.hrd_kpi_variable FOR INSERT
        TO authenticated, service_role
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated update hrd_kpi_variable" ON public.hrd_kpi_variable;
    CREATE POLICY "Allow authenticated update hrd_kpi_variable"
        ON public.hrd_kpi_variable FOR UPDATE
        TO authenticated, service_role
        USING (true)
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated delete hrd_kpi_variable" ON public.hrd_kpi_variable;
    CREATE POLICY "Allow authenticated delete hrd_kpi_variable"
        ON public.hrd_kpi_variable FOR DELETE
        TO authenticated, service_role
        USING (true);
END $$;

-- Policies for hrd_kpi_master_faults
DO $$
BEGIN
    DROP POLICY IF EXISTS "Allow authenticated read hrd_kpi_master_faults" ON public.hrd_kpi_master_faults;
    CREATE POLICY "Allow authenticated read hrd_kpi_master_faults"
        ON public.hrd_kpi_master_faults FOR SELECT
        TO authenticated, service_role
        USING (true);

    DROP POLICY IF EXISTS "Allow authenticated insert hrd_kpi_master_faults" ON public.hrd_kpi_master_faults;
    CREATE POLICY "Allow authenticated insert hrd_kpi_master_faults"
        ON public.hrd_kpi_master_faults FOR INSERT
        TO authenticated, service_role
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated update hrd_kpi_master_faults" ON public.hrd_kpi_master_faults;
    CREATE POLICY "Allow authenticated update hrd_kpi_master_faults"
        ON public.hrd_kpi_master_faults FOR UPDATE
        TO authenticated, service_role
        USING (true)
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated delete hrd_kpi_master_faults" ON public.hrd_kpi_master_faults;
    CREATE POLICY "Allow authenticated delete hrd_kpi_master_faults"
        ON public.hrd_kpi_master_faults FOR DELETE
        TO authenticated, service_role
        USING (true);
END $$;

NOTIFY pgrst, 'reload schema';
