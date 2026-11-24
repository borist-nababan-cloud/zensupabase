-- ==============================================================================
-- MIGRATION: 20261029002000_seed_and_harden_shrinkage_categories.sql
-- Description:
-- 1. Ensure is_active, audit columns, and update_at trigger on public.master_shrinkage_categories.
-- 2. Enforce strict NO DELETE policy on public.master_shrinkage_categories (SELECT, INSERT, UPDATE only).
-- 3. Seed 6 authoritative Bahasa Indonesia shrinkage categories idempotently.
-- 4. Ensure RLS policies and grants on public.inventory_shrinkage_logs.
-- ==============================================================================

-- 1. ENSURE COLUMNS & DEFAULTS ON public.master_shrinkage_categories
ALTER TABLE public.master_shrinkage_categories
    ALTER COLUMN is_active SET DEFAULT true;

UPDATE public.master_shrinkage_categories
SET is_active = true
WHERE is_active IS NULL;

ALTER TABLE public.master_shrinkage_categories
    ALTER COLUMN is_active SET NOT NULL;

-- 2. AUTOMATIC TIMESTAMP TRIGGER FOR update_at
CREATE OR REPLACE FUNCTION public.fn_update_master_shrinkage_categories_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.update_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_master_shrinkage_categories_timestamp ON public.master_shrinkage_categories;
CREATE TRIGGER trg_master_shrinkage_categories_timestamp
BEFORE UPDATE ON public.master_shrinkage_categories
FOR EACH ROW
EXECUTE FUNCTION public.fn_update_master_shrinkage_categories_timestamp();

-- 3. RLS POLICIES & NO-DELETE ENFORCEMENT ON public.master_shrinkage_categories
ALTER TABLE public.master_shrinkage_categories ENABLE ROW LEVEL SECURITY;

-- Drop any delete policies
DROP POLICY IF EXISTS "Allow authenticated delete master_shrinkage_categories" ON public.master_shrinkage_categories;
DROP POLICY IF EXISTS "Allow anon delete master_shrinkage_categories" ON public.master_shrinkage_categories;

-- Ensure SELECT policy
DROP POLICY IF EXISTS "Allow authenticated select master_shrinkage_categories" ON public.master_shrinkage_categories;
DROP POLICY IF EXISTS "Allow authenticated read master_shrinkage_categories" ON public.master_shrinkage_categories;
CREATE POLICY "Allow authenticated read master_shrinkage_categories"
ON public.master_shrinkage_categories FOR SELECT
TO authenticated, anon
USING (true);

-- Ensure INSERT policy
DROP POLICY IF EXISTS "Allow authenticated insert master_shrinkage_categories" ON public.master_shrinkage_categories;
CREATE POLICY "Allow authenticated insert master_shrinkage_categories"
ON public.master_shrinkage_categories FOR INSERT
TO authenticated
WITH CHECK (true);

-- Ensure UPDATE policy
DROP POLICY IF EXISTS "Allow authenticated update master_shrinkage_categories" ON public.master_shrinkage_categories;
CREATE POLICY "Allow authenticated update master_shrinkage_categories"
ON public.master_shrinkage_categories FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

-- Revoke DELETE privilege & grant SELECT/INSERT/UPDATE
REVOKE DELETE ON public.master_shrinkage_categories FROM authenticated, anon;
GRANT SELECT, INSERT, UPDATE ON public.master_shrinkage_categories TO authenticated;
GRANT SELECT ON public.master_shrinkage_categories TO anon;

-- 4. ENSURE RLS & GRANTS ON public.inventory_shrinkage_logs
ALTER TABLE public.inventory_shrinkage_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow authenticated select inventory_shrinkage_logs" ON public.inventory_shrinkage_logs;
CREATE POLICY "Allow authenticated select inventory_shrinkage_logs"
ON public.inventory_shrinkage_logs FOR SELECT
TO authenticated, anon
USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert inventory_shrinkage_logs" ON public.inventory_shrinkage_logs;
CREATE POLICY "Allow authenticated insert inventory_shrinkage_logs"
ON public.inventory_shrinkage_logs FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update inventory_shrinkage_logs" ON public.inventory_shrinkage_logs;
CREATE POLICY "Allow authenticated update inventory_shrinkage_logs"
ON public.inventory_shrinkage_logs FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE ON public.inventory_shrinkage_logs TO authenticated;
GRANT SELECT ON public.inventory_shrinkage_logs TO anon;

-- 5. SEED AUTHORITATIVE BAHASA INDONESIA SHRINKAGE CATEGORIES
INSERT INTO public.master_shrinkage_categories (id, name, description, kode_outlet, is_active)
VALUES
    ('2c7dde90-c28c-4c78-aef9-6c8c5e9873f4', 'Barang Rusak / Pecah', 'Kemasan bocor, botol pecah, atau kerusakan fisik barang', '111', true),
    ('ef258f4c-7cb2-4e3b-8a0d-07dd7e9e77fa', 'Kadaluarsa / Busuk', 'Bahan baku atau produk melewati masa berlaku atau berubah kualitas', '111', true),
    ('3b8e9a12-4d5c-4f8a-9b1e-7c2d3e4f5a6b', 'Tumpah / Terkontaminasi', 'Cairan atau minyak tumpah maupun terkontaminasi saat penyimpanan dan penanganan', '111', true),
    ('9d9d9c09-1f53-4cc0-9cf7-42a01f77deab', 'Limbah Produksi (Scrap)', 'Sisa bahan baku yang terbuang atau gagal saat proses produksi', '111', true),
    ('ba22b3fe-990c-4ec8-ba35-63c2e164dfdd', 'Hilang / Selisih Stok', 'Kehilangan barang atau penyusutan fisik di luar pemakaian normal', '111', true),
    ('a0a69bd3-2cb7-4f33-8f9f-467e196071db', 'Koreksi Kesalahan Input', 'Penyesuaian penghapusan stok akibat kesalahan pencatatan sebelumnya', '111', true)
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    is_active = EXCLUDED.is_active,
    update_at = now();

NOTIFY pgrst, 'reload schema';

