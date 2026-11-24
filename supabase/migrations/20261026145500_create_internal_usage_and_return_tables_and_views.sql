-- ==============================================================================
-- MIGRATION: 20261026145500_create_internal_usage_and_return_tables_and_views.sql
-- Description:
-- 1. Create master_issue_category table and seed default operational categories.
-- 2. Create internal_usage_headers & internal_usage_items with automated doc number & stock triggers.
-- 3. Create internal_return_headers & internal_return_items with automated doc number & stock triggers.
-- 4. Create view_report_internal_usage and view_report_internal_return views.
-- 5. Configure full RLS policies and grants for authenticated and anon users.
-- ==============================================================================

-- 1. MASTER ISSUE CATEGORY TABLE
CREATE TABLE IF NOT EXISTS public.master_issue_category (
    id SERIAL PRIMARY KEY,
    category_name TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID,
    update_at TIMESTAMPTZ DEFAULT now(),
    update_by UUID
);

-- Seed standard categories
INSERT INTO public.master_issue_category (category_name, description) VALUES
    ('Operasional / Treatment', 'Perlengkapan untuk kebutuhan perawatan dan treatment tamu'),
    ('Kebersihan & Sanitasi', 'Bahan pembersih, sabun, desinfektan, dan sanitasi outlet'),
    ('Peralatan & ATK Kantor', 'Alat tulis kantor, kertas kasir, dan perlengkapan administrasi'),
    ('Linen & Perlengkapan Tamu', 'Handuk, kain penutup, kimono, dan perlengkapan sprei'),
    ('Fasilitas & Pemeliharaan', 'Lampu, perkakas, suku cadang, dan perbaikan sarana'),
    ('Kerusakan / Kadaluarsa', 'Penghapusan barang rusak atau kadaluarsa saat pemakaian'),
    ('Lain-lain', 'Kebutuhan operasional mendesak lainnya')
ON CONFLICT (category_name) DO NOTHING;

-- 2. SEQUENCES FOR DOCUMENT NUMBERING
CREATE SEQUENCE IF NOT EXISTS seq_internal_usage_doc START 1;
CREATE SEQUENCE IF NOT EXISTS seq_internal_return_doc START 1;

-- 3. INTERNAL USAGE HEADERS TABLE
CREATE TABLE IF NOT EXISTS public.internal_usage_headers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number TEXT UNIQUE,
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON DELETE RESTRICT,
    transaction_date DATE NOT NULL DEFAULT CURRENT_DATE,
    category_id INT NOT NULL REFERENCES public.master_issue_category(id) ON DELETE RESTRICT,
    requested_by TEXT,
    notes TEXT,
    created_by UUID,
    created_at TIMESTAMPTZ DEFAULT now(),
    update_by UUID,
    update_at TIMESTAMPTZ DEFAULT now()
);

-- Trigger to auto-generate document_number if not provided
CREATE OR REPLACE FUNCTION fn_generate_internal_usage_doc_number()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.document_number IS NULL OR TRIM(NEW.document_number) = '' THEN
        NEW.document_number := 'USG-' || TO_CHAR(COALESCE(NEW.transaction_date, CURRENT_DATE), 'YYYYMMDD') || '-' || LPAD(nextval('seq_internal_usage_doc')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_internal_usage_doc_number ON public.internal_usage_headers;
CREATE TRIGGER trg_internal_usage_doc_number
BEFORE INSERT ON public.internal_usage_headers
FOR EACH ROW
EXECUTE FUNCTION fn_generate_internal_usage_doc_number();

-- 4. INTERNAL USAGE ITEMS TABLE
CREATE TABLE IF NOT EXISTS public.internal_usage_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    header_id UUID NOT NULL REFERENCES public.internal_usage_headers(id) ON DELETE CASCADE,
    barang_id BIGINT NOT NULL REFERENCES public.master_barang(id) ON DELETE RESTRICT,
    qty_used NUMERIC(15, 2) NOT NULL DEFAULT 1,
    uom TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID
);

-- Trigger to maintain inventory_balance on usage
CREATE OR REPLACE FUNCTION fn_internal_usage_stock_movement()
RETURNS TRIGGER AS $$
DECLARE
    v_kode_outlet TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT kode_outlet INTO v_kode_outlet FROM public.internal_usage_headers WHERE id = NEW.header_id;
        IF v_kode_outlet IS NOT NULL THEN
            UPDATE public.inventory_balance
            SET qty_on_hand = qty_on_hand - NEW.qty_used,
                last_movement_at = now()
            WHERE barang_id = NEW.barang_id AND kode_outlet = v_kode_outlet;
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        SELECT kode_outlet INTO v_kode_outlet FROM public.internal_usage_headers WHERE id = OLD.header_id;
        IF v_kode_outlet IS NOT NULL THEN
            UPDATE public.inventory_balance
            SET qty_on_hand = qty_on_hand + OLD.qty_used,
                last_movement_at = now()
            WHERE barang_id = OLD.barang_id AND kode_outlet = v_kode_outlet;
        END IF;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_internal_usage_stock ON public.internal_usage_items;
CREATE TRIGGER trg_internal_usage_stock
AFTER INSERT OR DELETE ON public.internal_usage_items
FOR EACH ROW
EXECUTE FUNCTION fn_internal_usage_stock_movement();

-- 5. INTERNAL RETURN HEADERS TABLE
CREATE TABLE IF NOT EXISTS public.internal_return_headers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number TEXT UNIQUE,
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON DELETE RESTRICT,
    transaction_date DATE NOT NULL DEFAULT CURRENT_DATE,
    category_id INT NOT NULL REFERENCES public.master_issue_category(id) ON DELETE RESTRICT,
    returned_by TEXT,
    notes TEXT,
    created_by UUID,
    created_at TIMESTAMPTZ DEFAULT now(),
    update_by UUID,
    update_at TIMESTAMPTZ DEFAULT now()
);

-- Trigger to auto-generate document_number for returns
CREATE OR REPLACE FUNCTION fn_generate_internal_return_doc_number()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.document_number IS NULL OR TRIM(NEW.document_number) = '' THEN
        NEW.document_number := 'RET-' || TO_CHAR(COALESCE(NEW.transaction_date, CURRENT_DATE), 'YYYYMMDD') || '-' || LPAD(nextval('seq_internal_return_doc')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_internal_return_doc_number ON public.internal_return_headers;
CREATE TRIGGER trg_internal_return_doc_number
BEFORE INSERT ON public.internal_return_headers
FOR EACH ROW
EXECUTE FUNCTION fn_generate_internal_return_doc_number();

-- 6. INTERNAL RETURN ITEMS TABLE
CREATE TABLE IF NOT EXISTS public.internal_return_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    header_id UUID NOT NULL REFERENCES public.internal_return_headers(id) ON DELETE CASCADE,
    barang_id BIGINT NOT NULL REFERENCES public.master_barang(id) ON DELETE RESTRICT,
    qty_returned NUMERIC(15, 2) NOT NULL DEFAULT 1,
    uom TEXT,
    condition_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID
);

-- Trigger to maintain inventory_balance on return
CREATE OR REPLACE FUNCTION fn_internal_return_stock_movement()
RETURNS TRIGGER AS $$
DECLARE
    v_kode_outlet TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT kode_outlet INTO v_kode_outlet FROM public.internal_return_headers WHERE id = NEW.header_id;
        IF v_kode_outlet IS NOT NULL THEN
            INSERT INTO public.inventory_balance (barang_id, kode_outlet, qty_on_hand, opening_balance, last_movement_at)
            VALUES (NEW.barang_id, v_kode_outlet, NEW.qty_returned, 0, now())
            ON CONFLICT (barang_id, kode_outlet)
            DO UPDATE SET 
                qty_on_hand = inventory_balance.qty_on_hand + EXCLUDED.qty_on_hand,
                last_movement_at = now();
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        SELECT kode_outlet INTO v_kode_outlet FROM public.internal_return_headers WHERE id = OLD.header_id;
        IF v_kode_outlet IS NOT NULL THEN
            UPDATE public.inventory_balance
            SET qty_on_hand = inventory_balance.qty_on_hand - OLD.qty_returned,
                last_movement_at = now()
            WHERE barang_id = OLD.barang_id AND kode_outlet = v_kode_outlet;
        END IF;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_internal_return_stock ON public.internal_return_items;
CREATE TRIGGER trg_internal_return_stock
AFTER INSERT OR DELETE ON public.internal_return_items
FOR EACH ROW
EXECUTE FUNCTION fn_internal_return_stock_movement();

-- 7. REPORT VIEW 1: view_report_internal_usage
CREATE OR REPLACE VIEW public.view_report_internal_usage AS
SELECT 
    iui.id::text AS item_id,
    iuh.document_number,
    iuh.transaction_date,
    iuh.kode_outlet,
    COALESCE(mo.name_outlet, iuh.kode_outlet) AS name_outlet,
    COALESCE(mic.category_name, 'Umum') AS category_name,
    iuh.requested_by,
    COALESCE(p.full_name, p.email, 'Petugas') AS created_by_name,
    mb.sku,
    mb.name AS item_name,
    COALESCE(iui.uom, bu.base_uom, 'PCS') AS uom,
    COALESCE(iui.qty_used, 0) AS qty_used,
    COALESCE(bp.buy_price, 0) AS unit_cost_estimate,
    ROUND((COALESCE(iui.qty_used, 0) * COALESCE(bp.buy_price, 0))::numeric, 2) AS total_expense_value,
    iui.notes AS item_notes,
    iuh.notes AS header_notes
FROM public.internal_usage_items iui
JOIN public.internal_usage_headers iuh ON iuh.id = iui.header_id
LEFT JOIN public.master_issue_category mic ON mic.id = iuh.category_id
LEFT JOIN public.master_outlet mo ON mo.kode_outlet = iuh.kode_outlet
LEFT JOIN public.master_barang mb ON mb.id = iui.barang_id
LEFT JOIN public.barang_units bu ON bu.barang_id = iui.barang_id
LEFT JOIN public.barang_prices bp ON bp.barang_id = iui.barang_id AND bp.kode_outlet = iuh.kode_outlet
LEFT JOIN public.profiles p ON p.id::text = iuh.created_by::text;

-- 8. REPORT VIEW 2: view_report_internal_return
CREATE OR REPLACE VIEW public.view_report_internal_return AS
SELECT 
    iri.id::text AS item_id,
    irh.document_number,
    irh.transaction_date,
    irh.kode_outlet,
    COALESCE(mo.name_outlet, irh.kode_outlet) AS name_outlet,
    COALESCE(mic.category_name, 'Umum') AS category_name,
    irh.returned_by,
    COALESCE(p.full_name, p.email, 'Petugas') AS created_by_name,
    mb.sku,
    mb.name AS item_name,
    COALESCE(iri.uom, bu.base_uom, 'PCS') AS uom,
    COALESCE(iri.qty_returned, 0) AS qty_returned,
    iri.condition_notes,
    COALESCE(bp.buy_price, 0) AS unit_cost_estimate,
    ROUND((COALESCE(iri.qty_returned, 0) * COALESCE(bp.buy_price, 0))::numeric, 2) AS total_value_recovered,
    irh.notes AS header_notes
FROM public.internal_return_items iri
JOIN public.internal_return_headers irh ON irh.id = iri.header_id
LEFT JOIN public.master_issue_category mic ON mic.id = irh.category_id
LEFT JOIN public.master_outlet mo ON mo.kode_outlet = irh.kode_outlet
LEFT JOIN public.master_barang mb ON mb.id = iri.barang_id
LEFT JOIN public.barang_units bu ON bu.barang_id = iri.barang_id
LEFT JOIN public.barang_prices bp ON bp.barang_id = iri.barang_id AND bp.kode_outlet = irh.kode_outlet
LEFT JOIN public.profiles p ON p.id::text = irh.created_by::text;

-- 9. ROW LEVEL SECURITY (RLS) POLICIES
ALTER TABLE public.master_issue_category ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.internal_usage_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.internal_usage_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.internal_return_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.internal_return_items ENABLE ROW LEVEL SECURITY;

-- Policies for master_issue_category
DROP POLICY IF EXISTS "Allow authenticated read master_issue_category" ON public.master_issue_category;
CREATE POLICY "Allow authenticated read master_issue_category" ON public.master_issue_category FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert master_issue_category" ON public.master_issue_category;
CREATE POLICY "Allow authenticated insert master_issue_category" ON public.master_issue_category FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update master_issue_category" ON public.master_issue_category;
CREATE POLICY "Allow authenticated update master_issue_category" ON public.master_issue_category FOR UPDATE TO authenticated USING (true);

-- Policies for internal_usage_headers
DROP POLICY IF EXISTS "Allow authenticated select internal_usage_headers" ON public.internal_usage_headers;
CREATE POLICY "Allow authenticated select internal_usage_headers" ON public.internal_usage_headers FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert internal_usage_headers" ON public.internal_usage_headers;
CREATE POLICY "Allow authenticated insert internal_usage_headers" ON public.internal_usage_headers FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update internal_usage_headers" ON public.internal_usage_headers;
CREATE POLICY "Allow authenticated update internal_usage_headers" ON public.internal_usage_headers FOR UPDATE TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated delete internal_usage_headers" ON public.internal_usage_headers;
CREATE POLICY "Allow authenticated delete internal_usage_headers" ON public.internal_usage_headers FOR DELETE TO authenticated USING (true);

-- Policies for internal_usage_items
DROP POLICY IF EXISTS "Allow authenticated select internal_usage_items" ON public.internal_usage_items;
CREATE POLICY "Allow authenticated select internal_usage_items" ON public.internal_usage_items FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert internal_usage_items" ON public.internal_usage_items;
CREATE POLICY "Allow authenticated insert internal_usage_items" ON public.internal_usage_items FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update internal_usage_items" ON public.internal_usage_items;
CREATE POLICY "Allow authenticated update internal_usage_items" ON public.internal_usage_items FOR UPDATE TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated delete internal_usage_items" ON public.internal_usage_items;
CREATE POLICY "Allow authenticated delete internal_usage_items" ON public.internal_usage_items FOR DELETE TO authenticated USING (true);

-- Policies for internal_return_headers
DROP POLICY IF EXISTS "Allow authenticated select internal_return_headers" ON public.internal_return_headers;
CREATE POLICY "Allow authenticated select internal_return_headers" ON public.internal_return_headers FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert internal_return_headers" ON public.internal_return_headers;
CREATE POLICY "Allow authenticated insert internal_return_headers" ON public.internal_return_headers FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update internal_return_headers" ON public.internal_return_headers;
CREATE POLICY "Allow authenticated update internal_return_headers" ON public.internal_return_headers FOR UPDATE TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated delete internal_return_headers" ON public.internal_return_headers;
CREATE POLICY "Allow authenticated delete internal_return_headers" ON public.internal_return_headers FOR DELETE TO authenticated USING (true);

-- Policies for internal_return_items
DROP POLICY IF EXISTS "Allow authenticated select internal_return_items" ON public.internal_return_items;
CREATE POLICY "Allow authenticated select internal_return_items" ON public.internal_return_items FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert internal_return_items" ON public.internal_return_items;
CREATE POLICY "Allow authenticated insert internal_return_items" ON public.internal_return_items FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update internal_return_items" ON public.internal_return_items;
CREATE POLICY "Allow authenticated update internal_return_items" ON public.internal_return_items FOR UPDATE TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated delete internal_return_items" ON public.internal_return_items;
CREATE POLICY "Allow authenticated delete internal_return_items" ON public.internal_return_items FOR DELETE TO authenticated USING (true);

-- 10. GRANTS
GRANT SELECT, INSERT, UPDATE, DELETE ON public.master_issue_category TO authenticated;
GRANT SELECT ON public.master_issue_category TO anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.internal_usage_headers TO authenticated;
GRANT SELECT ON public.internal_usage_headers TO anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.internal_usage_items TO authenticated;
GRANT SELECT ON public.internal_usage_items TO anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.internal_return_headers TO authenticated;
GRANT SELECT ON public.internal_return_headers TO anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.internal_return_items TO authenticated;
GRANT SELECT ON public.internal_return_items TO anon;

GRANT SELECT ON public.view_report_internal_usage TO authenticated, anon;
GRANT SELECT ON public.view_report_internal_return TO authenticated, anon;

GRANT USAGE, SELECT ON SEQUENCE public.master_issue_category_id_seq TO authenticated, anon;
GRANT USAGE, SELECT ON SEQUENCE seq_internal_usage_doc TO authenticated, anon;
GRANT USAGE, SELECT ON SEQUENCE seq_internal_return_doc TO authenticated, anon;
