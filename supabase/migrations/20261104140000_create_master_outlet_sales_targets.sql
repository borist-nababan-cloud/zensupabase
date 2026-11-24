-- Migration: Create master_outlet_sales_targets table
-- Description: Stores annual, monthly, and daily sales targets per outlet for POS Dashboards

CREATE TABLE IF NOT EXISTS public.master_outlet_sales_targets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_outlet TEXT NOT NULL,
    year INTEGER NOT NULL,
    target_tahunan NUMERIC(15, 2) NOT NULL DEFAULT 0,
    target_bulanan NUMERIC(15, 2) NOT NULL DEFAULT 0,
    target_harian NUMERIC(15, 2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id),
    CONSTRAINT uq_outlet_sales_target_year UNIQUE (kode_outlet, year)
);

-- Index for fast lookup by outlet and year
CREATE INDEX IF NOT EXISTS idx_outlet_sales_targets_lookup 
ON public.master_outlet_sales_targets (kode_outlet, year);

-- Enable RLS
ALTER TABLE public.master_outlet_sales_targets ENABLE ROW LEVEL SECURITY;

-- Policies:
-- Read access: All authenticated users and anon can view targets
DROP POLICY IF EXISTS "Allow read access to master_outlet_sales_targets" ON public.master_outlet_sales_targets;
CREATE POLICY "Allow read access to master_outlet_sales_targets"
ON public.master_outlet_sales_targets
FOR SELECT
USING (true);

-- Insert/Update/Delete access: Authenticated users
DROP POLICY IF EXISTS "Allow manage access to master_outlet_sales_targets" ON public.master_outlet_sales_targets;
CREATE POLICY "Allow manage access to master_outlet_sales_targets"
ON public.master_outlet_sales_targets
FOR ALL
TO authenticated
USING (true)
WITH CHECK (true);

-- Grant permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON public.master_outlet_sales_targets TO authenticated;
GRANT SELECT ON public.master_outlet_sales_targets TO anon;
GRANT ALL ON public.master_outlet_sales_targets TO service_role;

