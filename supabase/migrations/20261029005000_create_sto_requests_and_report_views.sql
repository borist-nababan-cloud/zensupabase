-- ==============================================================================
-- MIGRATION: 20261029005000_create_sto_requests_and_report_views.sql
-- Description:
-- 1. Create sto_requests & sto_request_items tables with auto-numbering trigger.
-- 2. Add sto_request_id & request_number link columns to public.sto_orders.
-- 3. Create view_report_sto_requests and view_report_sto_request_items views.
-- 4. Configure full RLS policies and grants for authenticated and anon users.
-- ==============================================================================

-- 1. SEQUENCE FOR DOCUMENT NUMBERING
CREATE SEQUENCE IF NOT EXISTS public.seq_sto_request_doc START 1;

-- 2. STO REQUESTS HEADER TABLE
CREATE TABLE IF NOT EXISTS public.sto_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number TEXT UNIQUE,
    request_date DATE NOT NULL DEFAULT CURRENT_DATE,
    requesting_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON DELETE RESTRICT,
    target_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON DELETE RESTRICT,
    status TEXT NOT NULL DEFAULT 'SUBMITTED' CHECK (status IN ('DRAFT', 'SUBMITTED', 'FULFILLED', 'CANCELLED')),
    notes TEXT,
    created_by UUID,
    created_at TIMESTAMPTZ DEFAULT now(),
    update_by UUID,
    update_at TIMESTAMPTZ DEFAULT now()
);

-- Trigger to auto-generate document_number if not provided
CREATE OR REPLACE FUNCTION public.fn_generate_sto_request_doc_number()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.document_number IS NULL OR TRIM(NEW.document_number) = '' THEN
        NEW.document_number := 'REQ-' || TO_CHAR(COALESCE(NEW.request_date, CURRENT_DATE), 'YYYYMMDD') || '-' || LPAD(nextval('public.seq_sto_request_doc')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sto_request_doc_number ON public.sto_requests;
CREATE TRIGGER trg_sto_request_doc_number
BEFORE INSERT ON public.sto_requests
FOR EACH ROW
EXECUTE FUNCTION public.fn_generate_sto_request_doc_number();

-- 3. STO REQUEST ITEMS TABLE
CREATE TABLE IF NOT EXISTS public.sto_request_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id UUID NOT NULL REFERENCES public.sto_requests(id) ON DELETE CASCADE,
    barang_id BIGINT NOT NULL REFERENCES public.master_barang(id) ON DELETE RESTRICT,
    qty_requested NUMERIC(15, 2) NOT NULL DEFAULT 1,
    uom TEXT DEFAULT 'PCS',
    notes TEXT,
    created_by UUID,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- 4. ADD LINK COLUMNS TO public.sto_orders
ALTER TABLE public.sto_orders
    ADD COLUMN IF NOT EXISTS sto_request_id UUID REFERENCES public.sto_requests(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS request_number TEXT;

-- 5. VIEW 1: view_report_sto_requests (Header Summary Report)
DROP VIEW IF EXISTS public.view_report_sto_requests;
CREATE VIEW public.view_report_sto_requests AS
SELECT
    r.id,
    r.request_date,
    r.document_number,
    r.requesting_outlet,
    mo_req.name_outlet AS requesting_outlet_name,
    r.target_outlet,
    mo_tgt.name_outlet AS target_outlet_name,
    r.status,
    r.notes,
    r.created_at,
    COALESCE(u.full_name, u.email, '-') AS created_by_name,
    COALESCE(
        (SELECT COUNT(*)::int FROM public.sto_request_items sri WHERE sri.request_id = r.id),
        0
    ) AS total_items,
    COALESCE(
        (SELECT SUM(sri.qty_requested) FROM public.sto_request_items sri WHERE sri.request_id = r.id),
        0
    ) AS total_qty_requested,
    COALESCE(
        (
            SELECT string_agg(mb.name || ' (' || ROUND(sri.qty_requested, 2)::text || ' ' || COALESCE(sri.uom, 'PCS') || ')', ', ')
            FROM public.sto_request_items sri
            JOIN public.master_barang mb ON mb.id = sri.barang_id
            WHERE sri.request_id = r.id
        ),
        '-'
    ) AS items_summary,
    so.id AS linked_sto_id,
    so.document_number AS linked_sto_number
FROM public.sto_requests r
LEFT JOIN public.master_outlet mo_req ON mo_req.kode_outlet = r.requesting_outlet
LEFT JOIN public.master_outlet mo_tgt ON mo_tgt.kode_outlet = r.target_outlet
LEFT JOIN public.profiles u ON u.id = r.created_by::text
LEFT JOIN LATERAL (
    SELECT o.id, o.document_number
    FROM public.sto_orders o
    WHERE o.sto_request_id = r.id OR (o.request_number IS NOT NULL AND o.request_number = r.document_number)
    ORDER BY o.created_at DESC
    LIMIT 1
) so ON true;

-- 6. VIEW 2: view_report_sto_request_items (Detailed Item Report)
DROP VIEW IF EXISTS public.view_report_sto_request_items;
CREATE VIEW public.view_report_sto_request_items AS
SELECT
    ri.id,
    r.id AS request_id,
    r.request_date,
    r.document_number,
    r.requesting_outlet,
    mo_req.name_outlet AS requesting_outlet_name,
    r.target_outlet,
    mo_tgt.name_outlet AS target_outlet_name,
    r.status,
    ri.barang_id,
    mb.sku,
    mb.name AS item_name,
    ri.qty_requested,
    COALESCE(ri.uom, 'PCS') AS uom,
    ri.notes AS item_notes,
    r.notes AS header_notes,
    COALESCE(u.full_name, u.email, '-') AS created_by_name,
    so.document_number AS linked_sto_number
FROM public.sto_request_items ri
JOIN public.sto_requests r ON r.id = ri.request_id
LEFT JOIN public.master_barang mb ON mb.id = ri.barang_id
LEFT JOIN public.master_outlet mo_req ON mo_req.kode_outlet = r.requesting_outlet
LEFT JOIN public.master_outlet mo_tgt ON mo_tgt.kode_outlet = r.target_outlet
LEFT JOIN public.profiles u ON u.id = r.created_by::text
LEFT JOIN LATERAL (
    SELECT o.document_number
    FROM public.sto_orders o
    WHERE o.sto_request_id = r.id OR (o.request_number IS NOT NULL AND o.request_number = r.document_number)
    ORDER BY o.created_at DESC
    LIMIT 1
) so ON true;

-- 7. RLS POLICIES & GRANTS
ALTER TABLE public.sto_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sto_request_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow authenticated read sto_requests" ON public.sto_requests;
CREATE POLICY "Allow authenticated read sto_requests"
ON public.sto_requests FOR SELECT
TO authenticated, anon
USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert sto_requests" ON public.sto_requests;
CREATE POLICY "Allow authenticated insert sto_requests"
ON public.sto_requests FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update sto_requests" ON public.sto_requests;
CREATE POLICY "Allow authenticated update sto_requests"
ON public.sto_requests FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated read sto_request_items" ON public.sto_request_items;
CREATE POLICY "Allow authenticated read sto_request_items"
ON public.sto_request_items FOR SELECT
TO authenticated, anon
USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert sto_request_items" ON public.sto_request_items;
CREATE POLICY "Allow authenticated insert sto_request_items"
ON public.sto_request_items FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update sto_request_items" ON public.sto_request_items;
CREATE POLICY "Allow authenticated update sto_request_items"
ON public.sto_request_items FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

GRANT USAGE, SELECT ON SEQUENCE public.seq_sto_request_doc TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE ON public.sto_requests TO authenticated;
GRANT SELECT ON public.sto_requests TO anon;
GRANT SELECT, INSERT, UPDATE ON public.sto_request_items TO authenticated;
GRANT SELECT ON public.sto_request_items TO anon;
GRANT SELECT ON public.view_report_sto_requests TO authenticated, anon;
GRANT SELECT ON public.view_report_sto_request_items TO authenticated, anon;

NOTIFY pgrst, 'reload schema';

