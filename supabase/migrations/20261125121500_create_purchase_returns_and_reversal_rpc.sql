-- ============================================================================
-- Migration 2: Procurement Return / Cancellation After GR + Debit Note + Stock Card
-- Date: 2026-11-25
-- Author: Zen Family Spa Architect
-- Description:
--   1. Extend public.purchase_invoices for DEBIT_NOTE (Faktur Pengurang)
--   2. Create public.purchase_returns & public.purchase_return_items (immutable via RPC)
--   3. Guard auto_post_ap_ledger() against DEBIT_NOTE & fix update_ap_status_on_allocation()
--   4. Update view_report_purchase_orders, view_report_purchase_invoices, view_report_po_outstanding
--   5. Update public.get_stock_card() with 12th mutation source: PURCHASE_RETURN
--   6. Create RPCs get_po_return_preview() & process_purchase_order_return()
-- ============================================================================

-- 1. Extend public.purchase_invoices
ALTER TABLE public.purchase_invoices
    ADD COLUMN IF NOT EXISTS invoice_type TEXT NOT NULL DEFAULT 'INVOICE';

ALTER TABLE public.purchase_invoices
    ADD COLUMN IF NOT EXISTS parent_invoice_id UUID REFERENCES public.purchase_invoices(id) ON DELETE SET NULL;

ALTER TABLE public.purchase_invoices
    ADD COLUMN IF NOT EXISTS purchase_return_id UUID;

ALTER TABLE public.purchase_invoices
    ADD COLUMN IF NOT EXISTS notes TEXT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_purchase_invoices_type'
          AND conrelid = 'public.purchase_invoices'::regclass
    ) THEN
        ALTER TABLE public.purchase_invoices
            ADD CONSTRAINT chk_purchase_invoices_type
            CHECK (invoice_type IN ('INVOICE', 'DEBIT_NOTE'));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_purchase_invoices_po_type
    ON public.purchase_invoices (purchase_order_id, invoice_type, created_at);

CREATE INDEX IF NOT EXISTS idx_purchase_invoices_parent
    ON public.purchase_invoices (parent_invoice_id)
    WHERE parent_invoice_id IS NOT NULL;

-- 2. Sequences & Tables: purchase_returns and purchase_return_items
CREATE SEQUENCE IF NOT EXISTS public.seq_purchase_return_doc START 1;
CREATE SEQUENCE IF NOT EXISTS public.seq_purchase_debit_note_doc START 1;

CREATE TABLE IF NOT EXISTS public.purchase_returns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number TEXT NOT NULL UNIQUE,
    po_id UUID NOT NULL REFERENCES public.purchase_orders(id) ON DELETE RESTRICT,
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet),
    kode_supplier UUID NOT NULL REFERENCES public.master_supplier(kode_supplier),
    return_type TEXT NOT NULL CHECK (return_type IN ('FULL_RETURN', 'PARTIAL_RETURN')),
    reason TEXT NOT NULL,
    items_return_amount NUMERIC(15, 2) NOT NULL DEFAULT 0,
    shipping_deduction NUMERIC(15, 2) NOT NULL DEFAULT 0,
    total_return_amount NUMERIC(15, 2) NOT NULL DEFAULT 0,
    linked_invoice_id UUID REFERENCES public.purchase_invoices(id) ON DELETE SET NULL,
    deduction_invoice_id UUID REFERENCES public.purchase_invoices(id) ON DELETE SET NULL,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_by_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.purchase_return_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    return_id UUID NOT NULL REFERENCES public.purchase_returns(id) ON DELETE CASCADE,
    po_item_id UUID NOT NULL REFERENCES public.purchase_order_items(id) ON DELETE RESTRICT,
    barang_id BIGINT NOT NULL REFERENCES public.master_barang(id),
    qty_returned NUMERIC(15, 4) NOT NULL CHECK (qty_returned > 0),
    conversion_rate NUMERIC(15, 4) NOT NULL DEFAULT 1,
    qty_base_unit NUMERIC(15, 4) GENERATED ALWAYS AS (qty_returned * conversion_rate) STORED,
    price_per_unit NUMERIC(15, 2) NOT NULL DEFAULT 0,
    subtotal NUMERIC(15, 2) GENERATED ALWAYS AS (ROUND((qty_returned * price_per_unit)::numeric, 2)) STORED
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'fk_purchase_invoices_return'
          AND conrelid = 'public.purchase_invoices'::regclass
    ) THEN
        ALTER TABLE public.purchase_invoices
            ADD CONSTRAINT fk_purchase_invoices_return
            FOREIGN KEY (purchase_return_id)
            REFERENCES public.purchase_returns(id)
            ON DELETE SET NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_purchase_returns_po_id
    ON public.purchase_returns (po_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_purchase_returns_outlet_created
    ON public.purchase_returns (kode_outlet, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_purchase_return_items_return_id
    ON public.purchase_return_items (return_id);

CREATE INDEX IF NOT EXISTS idx_purchase_return_items_barang_id
    ON public.purchase_return_items (barang_id);

ALTER TABLE public.purchase_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_return_items ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.purchase_returns, public.purchase_return_items FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.purchase_returns, public.purchase_return_items TO authenticated;
GRANT ALL ON public.purchase_returns, public.purchase_return_items TO service_role;

DROP POLICY IF EXISTS "Authenticated users can read purchase_returns" ON public.purchase_returns;
CREATE POLICY "Authenticated users can read purchase_returns"
    ON public.purchase_returns
    FOR SELECT
    TO authenticated
    USING (true);

DROP POLICY IF EXISTS "Service role full access purchase_returns" ON public.purchase_returns;
CREATE POLICY "Service role full access purchase_returns"
    ON public.purchase_returns
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated users can read purchase_return_items" ON public.purchase_return_items;
CREATE POLICY "Authenticated users can read purchase_return_items"
    ON public.purchase_return_items
    FOR SELECT
    TO authenticated
    USING (true);

DROP POLICY IF EXISTS "Service role full access purchase_return_items" ON public.purchase_return_items;
CREATE POLICY "Service role full access purchase_return_items"
    ON public.purchase_return_items
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- 3. Trigger Guard & AP Ledger Fix
CREATE OR REPLACE FUNCTION public.auto_post_ap_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_kode_supplier uuid;
  v_kode_outlet text;
BEGIN
  -- Debit Note / Faktur Pengurang must NOT post a separate negative AP debt row
  IF COALESCE(NEW.invoice_type, 'INVOICE') = 'DEBIT_NOTE' THEN
    RETURN NEW;
  END IF;

  SELECT kode_supplier, kode_outlet INTO v_kode_supplier, v_kode_outlet
  FROM public.purchase_orders
  WHERE id = NEW.purchase_order_id;

  INSERT INTO public.finance_ap_ledger (
      invoice_id,
      kode_supplier,
      kode_outlet,
      original_amount,
      paid_amount,
      due_date,
      is_paid
  ) VALUES (
      NEW.id,
      v_kode_supplier,
      v_kode_outlet,
      NEW.total_amount,
      0,
      NEW.payment_due_date,
      FALSE
  );

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_ap_status_on_allocation()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  current_paid NUMERIC;
  total_debt NUMERIC;
BEGIN
  -- 1. Update AP Ledger (Increase Paid Amount)
  UPDATE public.finance_ap_ledger
  SET paid_amount = paid_amount + NEW.amount_allocated,
      is_paid = (paid_amount + NEW.amount_allocated) >= original_amount
  WHERE invoice_id = NEW.invoice_id;

  -- 2. Update Invoice Status using effective AP ledger debt (reflects partial return reductions)
  SELECT COALESCE(l.original_amount, pi.total_amount), l.paid_amount
  INTO total_debt, current_paid
  FROM public.finance_ap_ledger l
  LEFT JOIN public.purchase_invoices pi ON pi.id = l.invoice_id
  WHERE l.invoice_id = NEW.invoice_id;

  IF total_debt IS NOT NULL THEN
    UPDATE public.purchase_invoices
    SET status = CASE
        WHEN COALESCE(current_paid, 0) >= total_debt THEN 'PAID'
        ELSE 'PARTIAL'
    END
    WHERE id = NEW.invoice_id;
  END IF;

  RETURN NEW;
END;
$function$;

-- 4. Backward-Compatible View Updates
CREATE OR REPLACE VIEW public.view_report_purchase_orders AS
SELECT
    po.id AS po_id,
    po.document_number,
    po.created_at AS po_date,
    po.expected_delivery_date,
    po.status,
    po.grand_total,
    po.kode_outlet,
    s.name AS supplier_name,
    s.kode_supplier,
    (
        SELECT pi1.id
        FROM public.purchase_invoices pi1
        WHERE pi1.purchase_order_id = po.id
          AND COALESCE(pi1.invoice_type, 'INVOICE') = 'INVOICE'
        ORDER BY pi1.created_at ASC
        LIMIT 1
    ) AS linked_invoice_id,
    po.document_number AS po_doc_number,
    (
        SELECT gr.image_url
        FROM public.goods_receipts gr
        WHERE gr.po_id = po.id
          AND gr.image_url IS NOT NULL
        ORDER BY gr.received_at DESC
        LIMIT 1
    ) AS receipt_image_url,
    EXISTS (
        SELECT 1
        FROM public.goods_receipts gr2
        WHERE gr2.po_id = po.id
    ) AS has_goods_receipt,
    (
        SELECT pi2.status
        FROM public.purchase_invoices pi2
        WHERE pi2.purchase_order_id = po.id
          AND COALESCE(pi2.invoice_type, 'INVOICE') = 'INVOICE'
        ORDER BY pi2.created_at ASC
        LIMIT 1
    ) AS invoice_status,
    COALESCE((
        SELECT SUM(fal.paid_amount)
        FROM public.finance_ap_ledger fal
        JOIN public.purchase_invoices pi3 ON pi3.id = fal.invoice_id
        WHERE pi3.purchase_order_id = po.id
          AND COALESCE(pi3.invoice_type, 'INVOICE') = 'INVOICE'
    ), 0::numeric) AS invoice_paid_amount,
    (
        SELECT COUNT(*)::integer
        FROM public.purchase_returns pr
        WHERE pr.po_id = po.id
    ) AS return_count,
    COALESCE((
        SELECT SUM(pr.total_return_amount)
        FROM public.purchase_returns pr
        WHERE pr.po_id = po.id
    ), 0::numeric) AS total_returned_amount,
    (
        SELECT pi4.id
        FROM public.purchase_invoices pi4
        WHERE pi4.purchase_order_id = po.id
          AND pi4.invoice_type = 'DEBIT_NOTE'
        ORDER BY pi4.created_at DESC
        LIMIT 1
    ) AS latest_debit_note_id
FROM public.purchase_orders po
JOIN public.master_supplier s ON po.kode_supplier = s.kode_supplier;

CREATE OR REPLACE VIEW public.view_report_purchase_invoices AS
SELECT
    inv.id AS invoice_id,
    inv.document_number AS invoice_doc,
    inv.supplier_invoice_number,
    inv.invoice_date,
    inv.payment_due_date,
    inv.total_amount,
    inv.shipping_cost,
    inv.status,
    inv.purchase_order_id,
    po.document_number AS po_doc,
    po.kode_outlet,
    s.name AS supplier_name,
    s.kode_supplier,
    (
        SELECT COALESCE(sum(fpa.amount_allocated), 0::numeric) AS "coalesce"
        FROM public.finance_payment_allocations fpa
        WHERE fpa.invoice_id = inv.id
    ) AS total_paid_amount,
    (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'payment_date', fpo.payment_date,
            'document_number', fpo.document_number,
            'method', mfa.account_name,
            'type', mfa.account_type,
            'amount', fpa.amount_allocated
        ) ORDER BY fpo.payment_date DESC), '[]'::jsonb) AS "coalesce"
        FROM public.finance_payment_allocations fpa
        JOIN public.finance_payments_out fpo ON fpa.payment_id = fpo.id
        JOIN public.master_financial_accounts mfa ON fpo.financial_account_id = mfa.id
        WHERE fpa.invoice_id = inv.id
    ) AS payment_history,
    COALESCE(inv.invoice_type, 'INVOICE') AS invoice_type,
    inv.parent_invoice_id,
    inv.purchase_return_id
FROM public.purchase_invoices inv
JOIN public.purchase_orders po ON inv.purchase_order_id = po.id
JOIN public.master_supplier s ON po.kode_supplier = s.kode_supplier;

CREATE OR REPLACE VIEW public.view_report_po_outstanding AS
SELECT
    v.po_item_id,
    v.po_id,
    v.kode_outlet,
    v.document_number,
    v.po_created_at,
    s.name AS supplier_name,
    s.phone AS supplier_phone,
    v.sku,
    v.item_name,
    v.uom_purchase,
    v.qty_ordered,
    v.qty_already_received,
    v.qty_remaining,
    (v.qty_remaining * v.price_per_unit)::numeric(15, 2) AS estimated_pending_value
FROM public.view_po_details_received v
JOIN public.purchase_orders po ON v.po_id = po.id
JOIN public.master_supplier s ON po.kode_supplier = s.kode_supplier
WHERE v.qty_remaining > 0::numeric
  AND (po.status <> ALL (ARRAY[
      'CANCELLED'::public.po_status,
      'COMPLETED'::public.po_status,
      'RETURNED'::public.po_status,
      'INVOICED'::public.po_status,
      'PAID'::public.po_status
  ]));

-- 5. Update Kartu Stok RPC public.get_stock_card (12 Mutation Sources incl. PURCHASE_RETURN)
CREATE OR REPLACE FUNCTION public.get_stock_card(
  p_kode_outlet TEXT,
  p_barang_id BIGINT,
  p_mode TEXT DEFAULT 'ALL',
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_user_role INTEGER;
  v_user_outlet TEXT;
  v_outlet TEXT;
  v_mode TEXT := CASE
    WHEN UPPER(COALESCE(p_mode, 'ALL')) = 'RANGE' AND p_start_date IS NOT NULL THEN 'RANGE'
    ELSE 'ALL'
  END;

  v_barang RECORD;
  v_outlet_rec RECORD;
  v_uom TEXT := 'PCS';
  v_system_qty NUMERIC(15, 2) := 0;
  v_db_opening_balance NUMERIC(15, 2) := 0;
  v_date_ob DATE;
  v_last_movement_at TIMESTAMPTZ;

  v_opening_balance NUMERIC(15, 2) := 0;
  v_opening_date DATE;
  v_opening_label TEXT;
  v_total_in NUMERIC(15, 2) := 0;
  v_total_out NUMERIC(15, 2) := 0;
  v_closing_balance NUMERIC(15, 2) := 0;
  v_calculated_current NUMERIC(15, 2) := 0;
  v_discrepancy NUMERIC(15, 2) := 0;
  v_opname_mismatch_count INTEGER := 0;
  v_earliest_date DATE;
  v_rows JSONB := '[]'::jsonb;
BEGIN
  -- 1. Auth & RBAC Validation (Roles 5, 6, 7, 8, 13, 14 ONLY)
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Autentikasi diperlukan' USING ERRCODE = '42501';
  END IF;

  SELECT user_role, kode_outlet
  INTO v_user_role, v_user_outlet
  FROM public.users_profile
  WHERE uid = v_uid;

  IF v_user_role IS NULL OR v_user_role NOT IN (5, 6, 7, 8, 13, 14) THEN
    RAISE EXCEPTION 'Akses ditolak. Role Anda tidak berwenang membuka Kartu Stok.' USING ERRCODE = '42501';
  END IF;

  IF v_user_role IN (6, 7, 14) THEN
    v_outlet := NULLIF(TRIM(v_user_outlet), '');
  ELSE
    v_outlet := COALESCE(NULLIF(TRIM(p_kode_outlet), ''), NULLIF(TRIM(v_user_outlet), ''));
  END IF;

  IF v_outlet IS NULL THEN
    RAISE EXCEPTION 'Kode outlet wajib dipilih atau terdaftar pada profil pengguna.' USING ERRCODE = '22023';
  END IF;

  IF p_barang_id IS NULL THEN
    RAISE EXCEPTION 'ID barang wajib dipilih.' USING ERRCODE = '22023';
  END IF;

  IF v_mode = 'RANGE' AND p_end_date IS NOT NULL AND p_start_date > p_end_date THEN
    RAISE EXCEPTION 'Tanggal mulai tidak boleh lebih besar dari tanggal akhir.' USING ERRCODE = '22023';
  END IF;

  -- 2. Header Metadata
  SELECT
    mb.id,
    mb.sku,
    mb.name,
    mb.kode_outlet AS owner_outlet,
    NULLIF(TRIM(mb.image1_url), '') AS image1_url,
    COALESCE(NULLIF(TRIM(mb.image2_url), ''), NULLIF(TRIM(mb.iamge2_url), '')) AS image2_url
  INTO v_barang
  FROM public.master_barang mb
  WHERE mb.id = p_barang_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Data barang tidak ditemukan.' USING ERRCODE = 'P0002';
  END IF;

  SELECT
    kode_outlet,
    name_outlet,
    alamat,
    city,
    no_telp,
    email
  INTO v_outlet_rec
  FROM public.master_outlet
  WHERE kode_outlet = v_outlet;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Data outlet % tidak ditemukan.', v_outlet USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(NULLIF(TRIM(bu.base_uom), ''), NULLIF(TRIM(bu.purchase_uom), ''), 'PCS')
  INTO v_uom
  FROM public.barang_units bu
  WHERE bu.barang_id = p_barang_id
    AND bu.kode_outlet IN (v_outlet, v_barang.owner_outlet, '901')
  ORDER BY CASE
    WHEN bu.kode_outlet = v_outlet THEN 1
    WHEN bu.kode_outlet = v_barang.owner_outlet THEN 2
    WHEN bu.kode_outlet = '901' THEN 3
    ELSE 4
  END
  LIMIT 1;
  v_uom := COALESCE(v_uom, 'PCS');

  SELECT
    COALESCE(ib.qty_on_hand, 0),
    COALESCE(ib.opening_balance, 0),
    ib.date_ob,
    ib.last_movement_at
  INTO v_system_qty, v_db_opening_balance, v_date_ob, v_last_movement_at
  FROM public.inventory_balance ib
  WHERE ib.barang_id = p_barang_id
    AND ib.kode_outlet = v_outlet;

  v_system_qty := COALESCE(v_system_qty, 0);
  v_db_opening_balance := COALESCE(v_db_opening_balance, 0);

  -- 3. Collect all 12 mutation sources (Pure Forward Ledger from 0)
  WITH raw_events AS (
    -- 1. Penerimaan Supplier (GR) -> MASUK
    SELECT
      gri.id::text AS row_seq,
      COALESCE(gr.received_at, now()) AS event_ts,
      'GR'::text AS source_code,
      'Penerimaan Supplier (GR)'::text AS source_label,
      gr.document_number AS doc_number,
      CONCAT(
        'Penerimaan Supplier (GR) • ', gr.document_number,
        CASE WHEN ms.name IS NOT NULL AND TRIM(ms.name) <> '' THEN ' — Supplier: ' || ms.name ELSE '' END,
        CASE WHEN po.document_number IS NOT NULL THEN ' (PO: ' || po.document_number || ')' ELSE '' END,
        CASE WHEN NULLIF(TRIM(gr.supplier_delivery_note), '') IS NOT NULL AND TRIM(gr.supplier_delivery_note) <> '-'
             THEN ' [SJ: ' || TRIM(gr.supplier_delivery_note) || ']' ELSE '' END
      ) AS description,
      ROUND(COALESCE(gri.qty_base_unit, gri.qty_received * COALESCE(gri.conversion_rate, 1), 0), 2) AS in_qty,
      0::numeric(15, 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.goods_receipt_items gri
    JOIN public.goods_receipts gr ON gr.id = gri.receipt_id
    LEFT JOIN public.purchase_orders po ON po.id = gr.po_id
    LEFT JOIN public.master_supplier ms ON ms.kode_supplier = po.kode_supplier
    WHERE gr.kode_outlet = v_outlet
      AND gri.barang_id = p_barang_id

    UNION ALL

    -- 2. Terima STO Antar Cabang -> MASUK
    SELECT
      sri.id::text AS row_seq,
      COALESCE(sr.received_at, now()) AS event_ts,
      'STO_IN'::text AS source_code,
      'Terima STO'::text AS source_label,
      COALESCE(sr.document_number, so.document_number) AS doc_number,
      CONCAT(
        'Terima STO • ', COALESCE(sr.document_number, '-'),
        ' (Order: ', so.document_number, ')',
        ' — Dari: ', COALESCE(mo.name_outlet, so.from_outlet), ' [', so.from_outlet, ']'
      ) AS description,
      ROUND(COALESCE(sri.qty_received, 0), 2) AS in_qty,
      0::numeric(15, 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.sto_receipt_items sri
    JOIN public.sto_receipts sr ON sr.id = sri.receipt_id
    JOIN public.sto_orders so ON so.id = sr.sto_id
    LEFT JOIN public.master_outlet mo ON mo.kode_outlet = so.from_outlet
    WHERE so.to_outlet = v_outlet
      AND sri.barang_id = p_barang_id

    UNION ALL

    -- 3. Kirim STO Antar Cabang -> KELUAR
    SELECT
      ssi.id::text AS row_seq,
      COALESCE(ss.shipped_at, now()) AS event_ts,
      'STO_OUT'::text AS source_code,
      'Kirim STO'::text AS source_label,
      COALESCE(ss.document_number, so.document_number) AS doc_number,
      CONCAT(
        'Kirim STO • ', COALESCE(ss.document_number, '-'),
        ' (Order: ', so.document_number, ')',
        ' — Ke: ', COALESCE(mo.name_outlet, so.to_outlet), ' [', so.to_outlet, ']'
      ) AS description,
      0::numeric(15, 2) AS in_qty,
      ROUND(COALESCE(ssi.qty_shipped, 0), 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.sto_shipment_items ssi
    JOIN public.sto_shipments ss ON ss.id = ssi.shipment_id
    JOIN public.sto_orders so ON so.id = ss.sto_id
    LEFT JOIN public.master_outlet mo ON mo.kode_outlet = so.to_outlet
    WHERE so.from_outlet = v_outlet
      AND ssi.barang_id = p_barang_id

    UNION ALL

    -- 4. Pengembalian STO Ditolak -> MASUK
    SELECT
      ssi.id::text || '-REJ' AS row_seq,
      COALESCE(ss.shipped_at, so.created_at, now()) + INTERVAL '1 second' AS event_ts,
      'STO_REJECT'::text AS source_code,
      'STO Ditolak (Retur)'::text AS source_label,
      so.document_number AS doc_number,
      CONCAT(
        'Pengembalian STO Ditolak • ', so.document_number,
        ' — Ditolak oleh: ', COALESCE(mo.name_outlet, so.to_outlet), ' [', so.to_outlet, ']'
      ) AS description,
      ROUND(COALESCE(ssi.qty_shipped, 0), 2) AS in_qty,
      0::numeric(15, 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.sto_shipment_items ssi
    JOIN public.sto_shipments ss ON ss.id = ssi.shipment_id
    JOIN public.sto_orders so ON so.id = ss.sto_id
    LEFT JOIN public.master_outlet mo ON mo.kode_outlet = so.to_outlet
    WHERE so.from_outlet = v_outlet
      AND ssi.barang_id = p_barang_id
      AND so.recipient_status = 'REJECTED'
      AND so.sender_status = 'SHIPPED'

    UNION ALL

    -- 5. Produksi Hasil Barang Jadi -> MASUK
    SELECT
      pro.id::text AS row_seq,
      COALESCE(pr.created_at, (pr.transaction_date::timestamp AT TIME ZONE 'Asia/Jakarta')) AS event_ts,
      'PROD_IN'::text AS source_code,
      'Produksi (Hasil Jadi)'::text AS source_label,
      pr.document_number AS doc_number,
      CONCAT(
        'Produksi (Hasil Barang Jadi) • ', pr.document_number,
        CASE WHEN NULLIF(TRIM(pr.notes), '') IS NOT NULL THEN ' — ' || TRIM(pr.notes) ELSE '' END
      ) AS description,
      ROUND(COALESCE(pro.qty_produced, 0), 2) AS in_qty,
      0::numeric(15, 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.production_run_outputs pro
    JOIN public.production_runs pr ON pr.id = pro.run_id
    WHERE pr.kode_outlet = v_outlet
      AND pro.barang_id = p_barang_id
      AND pr.status = 'COMPLETED'

    UNION ALL

    -- 6. Produksi Pemakaian Bahan Baku -> KELUAR
    SELECT
      pri.id::text AS row_seq,
      COALESCE(pr.created_at, (pr.transaction_date::timestamp AT TIME ZONE 'Asia/Jakarta')) AS event_ts,
      'PROD_OUT'::text AS source_code,
      'Produksi (Bahan Baku)'::text AS source_label,
      pr.document_number AS doc_number,
      CONCAT(
        'Produksi (Pemakaian Bahan Baku) • ', pr.document_number,
        CASE WHEN NULLIF(TRIM(pr.notes), '') IS NOT NULL THEN ' — ' || TRIM(pr.notes) ELSE '' END
      ) AS description,
      0::numeric(15, 2) AS in_qty,
      ROUND(COALESCE(pri.qty_used, 0), 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.production_run_ingredients pri
    JOIN public.production_runs pr ON pr.id = pri.run_id
    WHERE pr.kode_outlet = v_outlet
      AND pri.barang_id = p_barang_id
      AND pr.status = 'COMPLETED'

    UNION ALL

    -- 7. Pemakaian Internal -> KELUAR
    SELECT
      iui.id::text AS row_seq,
      COALESCE(iuh.created_at, (iuh.transaction_date::timestamp AT TIME ZONE 'Asia/Jakarta')) AS event_ts,
      'USAGE'::text AS source_code,
      'Pemakaian Internal'::text AS source_label,
      COALESCE(iuh.document_number, 'USG') AS doc_number,
      CONCAT(
        'Pemakaian Internal • ', COALESCE(iuh.document_number, '-'),
        CASE WHEN mic.category_name IS NOT NULL THEN ' — Kategori: ' || mic.category_name ELSE '' END,
        CASE WHEN NULLIF(TRIM(iuh.requested_by), '') IS NOT NULL THEN ' (Oleh: ' || TRIM(iuh.requested_by) || ')' ELSE '' END,
        CASE WHEN NULLIF(TRIM(COALESCE(iui.notes, iuh.notes)), '') IS NOT NULL
             THEN ' — ' || TRIM(COALESCE(iui.notes, iuh.notes)) ELSE '' END
      ) AS description,
      0::numeric(15, 2) AS in_qty,
      ROUND(COALESCE(iui.qty_used, 0), 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.internal_usage_items iui
    JOIN public.internal_usage_headers iuh ON iuh.id = iui.header_id
    LEFT JOIN public.master_issue_category mic ON mic.id = iuh.category_id
    WHERE iuh.kode_outlet = v_outlet
      AND iui.barang_id = p_barang_id

    UNION ALL

    -- 8. Retur Internal -> MASUK
    SELECT
      iri.id::text AS row_seq,
      COALESCE(irh.created_at, (irh.transaction_date::timestamp AT TIME ZONE 'Asia/Jakarta')) AS event_ts,
      'RETURN'::text AS source_code,
      'Retur Internal'::text AS source_label,
      COALESCE(irh.document_number, 'RET') AS doc_number,
      CONCAT(
        'Retur Internal • ', COALESCE(irh.document_number, '-'),
        CASE WHEN mic.category_name IS NOT NULL THEN ' — Kategori: ' || mic.category_name ELSE '' END,
        CASE WHEN NULLIF(TRIM(irh.returned_by), '') IS NOT NULL THEN ' (Dari: ' || TRIM(irh.returned_by) || ')' ELSE '' END,
        CASE WHEN NULLIF(TRIM(COALESCE(iri.condition_notes, irh.notes)), '') IS NOT NULL
             THEN ' — ' || TRIM(COALESCE(iri.condition_notes, irh.notes)) ELSE '' END
      ) AS description,
      ROUND(COALESCE(iri.qty_returned, 0), 2) AS in_qty,
      0::numeric(15, 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.internal_return_items iri
    JOIN public.internal_return_headers irh ON irh.id = iri.header_id
    LEFT JOIN public.master_issue_category mic ON mic.id = irh.category_id
    WHERE irh.kode_outlet = v_outlet
      AND iri.barang_id = p_barang_id

    UNION ALL

    -- 9. Penyusutan / Pemusnahan -> KELUAR
    SELECT
      isl.id::text AS row_seq,
      COALESCE(isl.created_at, (isl.transaction_date::timestamp AT TIME ZONE 'Asia/Jakarta')) AS event_ts,
      'SHRINKAGE'::text AS source_code,
      'Penyusutan'::text AS source_label,
      isl.document_number AS doc_number,
      CONCAT(
        'Penyusutan • ', isl.document_number,
        CASE WHEN msc.name IS NOT NULL THEN ' — Kategori: ' || msc.name ELSE '' END,
        CASE WHEN NULLIF(TRIM(isl.notes), '') IS NOT NULL THEN ' (' || TRIM(isl.notes) || ')' ELSE '' END
      ) AS description,
      0::numeric(15, 2) AS in_qty,
      ROUND(COALESCE(isl.qty_lost, 0), 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.inventory_shrinkage_logs isl
    LEFT JOIN public.master_shrinkage_categories msc ON msc.id = isl.shrinkage_category_id
    WHERE isl.kode_outlet = v_outlet
      AND isl.barang_id = p_barang_id

    UNION ALL

    -- 10. Penjualan Customer B2B (Surat Jalan) -> KELUAR
    SELECT
      csi.id::text AS row_seq,
      COALESCE(cs.shipment_date, cs.created_at, now()) AS event_ts,
      'CST_SALE'::text AS source_code,
      'Jual Customer'::text AS source_label,
      cs.document_number AS doc_number,
      CONCAT(
        'Penjualan Customer • ', cs.document_number,
        CASE WHEN mc.name IS NOT NULL AND TRIM(mc.name) <> '' THEN ' — Customer: ' || mc.name ELSE '' END,
        CASE WHEN NULLIF(TRIM(cs.notes), '') IS NOT NULL THEN ' (' || TRIM(cs.notes) || ')' ELSE '' END
      ) AS description,
      0::numeric(15, 2) AS in_qty,
      ROUND(COALESCE(csi.qty_shipped, 0), 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.cst_shipment_items csi
    JOIN public.cst_shipments cs ON cs.id = csi.shipment_id
    LEFT JOIN public.master_customer mc ON mc.kode_customer = cs.kode_customer
    WHERE cs.kode_outlet = v_outlet
      AND csi.barang_id = p_barang_id

    UNION ALL

    -- 11. Stock Opname (COMPLETED) -> SELISIH (+/-)
    SELECT
      soi.id::text AS row_seq,
      COALESCE(soh.created_at, (soh.opname_date::timestamp AT TIME ZONE 'Asia/Jakarta')) AS event_ts,
      'OPNAME'::text AS source_code,
      'Stock Opname'::text AS source_label,
      soh.document_number AS doc_number,
      CONCAT(
        'Penyesuaian Stock Opname • ', soh.document_number,
        ' (Sistem: ', TRIM(TO_CHAR(COALESCE(soi.system_qty, 0), 'FM999999990.##')),
        ' → Fisik: ', TRIM(TO_CHAR(COALESCE(soi.actual_qty, 0), 'FM999999990.##')), ')'
      ) AS description,
      ROUND(GREATEST(COALESCE(soi.difference, soi.actual_qty - soi.system_qty, 0), 0), 2) AS in_qty,
      ROUND(GREATEST(-(COALESCE(soi.difference, soi.actual_qty - soi.system_qty, 0)), 0), 2) AS out_qty,
      ROUND(COALESCE(soi.system_qty, 0), 2) AS opname_system_qty,
      ROUND(COALESCE(soi.actual_qty, 0), 2) AS opname_actual_qty
    FROM public.stock_opname_items soi
    JOIN public.stock_opname_headers soh ON soh.id = soi.header_id
    WHERE soh.kode_outlet = v_outlet
      AND soi.barang_id = p_barang_id
      AND soh.status = 'COMPLETED'

    UNION ALL

    -- 12. Retur Pembelian ke Supplier (PO Return) -> KELUAR
    SELECT
      pri.id::text AS row_seq,
      pr.created_at AS event_ts,
      'PURCHASE_RETURN'::text AS source_code,
      'Retur Pembelian (PO)'::text AS source_label,
      pr.document_number AS doc_number,
      CONCAT(
        'Retur Pembelian • ', pr.document_number,
        CASE WHEN ms.name IS NOT NULL AND TRIM(ms.name) <> '' THEN ' — Supplier: ' || ms.name ELSE '' END,
        CASE WHEN po.document_number IS NOT NULL THEN ' (PO: ' || po.document_number || ')' ELSE '' END,
        CASE WHEN NULLIF(TRIM(pr.reason), '') IS NOT NULL THEN ' — ' || TRIM(pr.reason) ELSE '' END
      ) AS description,
      0::numeric(15, 2) AS in_qty,
      ROUND(COALESCE(pri.qty_base_unit, pri.qty_returned * COALESCE(pri.conversion_rate, 1), 0), 2) AS out_qty,
      NULL::numeric(15, 2) AS opname_system_qty,
      NULL::numeric(15, 2) AS opname_actual_qty
    FROM public.purchase_return_items pri
    JOIN public.purchase_returns pr ON pr.id = pri.return_id
    LEFT JOIN public.purchase_orders po ON po.id = pr.po_id
    LEFT JOIN public.master_supplier ms ON ms.kode_supplier = pr.kode_supplier
    WHERE pr.kode_outlet = v_outlet
      AND pri.barang_id = p_barang_id
  ),
  ordered_events AS (
    SELECT
      re.*,
      (re.event_ts AT TIME ZONE 'Asia/Jakarta')::date AS event_date,
      SUM(re.in_qty - re.out_qty) OVER (
        ORDER BY re.event_ts ASC, re.doc_number ASC, re.source_code ASC, re.row_seq ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS balance_after
    FROM raw_events re
  ),
  enriched_events AS (
    SELECT
      oe.*,
      (oe.balance_after - (oe.in_qty - oe.out_qty)) AS balance_before,
      (
        oe.source_code = 'OPNAME'
        AND ABS((oe.balance_after - (oe.in_qty - oe.out_qty)) - COALESCE(oe.opname_system_qty, 0)) > 0.001
      ) AS has_opname_mismatch
    FROM ordered_events oe
  ),
  totals AS (
    SELECT
      MIN(event_date) AS earliest_date,
      COALESCE(SUM(in_qty - out_qty), 0)::numeric(15, 2) AS full_net,
      COALESCE(SUM(in_qty - out_qty) FILTER (
        WHERE v_mode = 'RANGE' AND event_date < p_start_date
      ), 0)::numeric(15, 2) AS before_start_net,
      COUNT(*) FILTER (WHERE has_opname_mismatch)::integer AS mismatch_cnt
    FROM enriched_events
  ),
  filtered_events AS (
    SELECT *
    FROM enriched_events ee
    WHERE
      v_mode = 'ALL'
      OR (
        ee.event_date >= p_start_date
        AND (p_end_date IS NULL OR ee.event_date <= p_end_date)
      )
  ),
  period_totals AS (
    SELECT
      COALESCE(SUM(in_qty), 0)::numeric(15, 2) AS p_in,
      COALESCE(SUM(out_qty), 0)::numeric(15, 2) AS p_out
    FROM filtered_events
  )
  SELECT
    t.earliest_date,
    t.full_net,
    t.before_start_net,
    t.mismatch_cnt,
    pt.p_in,
    pt.p_out,
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', fe.row_seq,
          'event_ts', fe.event_ts,
          'event_date', fe.event_date,
          'source_code', fe.source_code,
          'source_label', fe.source_label,
          'doc_number', fe.doc_number,
          'description', fe.description,
          'in_qty', fe.in_qty,
          'out_qty', fe.out_qty,
          'balance_before', fe.balance_before,
          'balance', fe.balance_after,
          'opname_system_qty', fe.opname_system_qty,
          'opname_actual_qty', fe.opname_actual_qty,
          'has_opname_mismatch', fe.has_opname_mismatch
        )
        ORDER BY fe.event_ts ASC, fe.doc_number ASC, fe.source_code ASC, fe.row_seq ASC
      )
      FROM filtered_events fe
    ), '[]'::jsonb)
  INTO
    v_earliest_date,
    v_calculated_current,
    v_opening_balance,
    v_opname_mismatch_count,
    v_total_in,
    v_total_out,
    v_rows
  FROM totals t
  CROSS JOIN period_totals pt;

  IF v_mode = 'RANGE' THEN
    v_opening_date := p_start_date;
    v_opening_label := 'Saldo Awal per ' || TO_CHAR(p_start_date, 'DD/MM/YYYY');
  ELSE
    v_opening_balance := 0;
    v_opening_date := COALESCE(v_earliest_date, v_date_ob, (now() AT TIME ZONE 'Asia/Jakarta')::date);
    v_opening_label := 'Saldo Awal (Awal Pencatatan = 0)';
  END IF;

  v_closing_balance := ROUND((COALESCE(v_opening_balance, 0) + COALESCE(v_total_in, 0) - COALESCE(v_total_out, 0))::numeric, 2);
  v_discrepancy := ROUND((v_system_qty - COALESCE(v_calculated_current, 0))::numeric, 2);

  RETURN jsonb_build_object(
    'item', jsonb_build_object(
      'barang_id', v_barang.id,
      'sku', v_barang.sku,
      'name', v_barang.name,
      'uom', v_uom,
      'image1_url', v_barang.image1_url,
      'image2_url', v_barang.image2_url
    ),
    'outlet', jsonb_build_object(
      'kode_outlet', v_outlet_rec.kode_outlet,
      'name_outlet', v_outlet_rec.name_outlet,
      'alamat', v_outlet_rec.alamat,
      'city', v_outlet_rec.city,
      'no_telp', v_outlet_rec.no_telp,
      'email', v_outlet_rec.email
    ),
    'filter', jsonb_build_object(
      'mode', v_mode,
      'start_date', p_start_date,
      'end_date', p_end_date
    ),
    'summary', jsonb_build_object(
      'opening_balance', COALESCE(v_opening_balance, 0),
      'opening_date', v_opening_date,
      'opening_label', v_opening_label,
      'total_in', COALESCE(v_total_in, 0),
      'total_out', COALESCE(v_total_out, 0),
      'closing_balance', COALESCE(v_closing_balance, 0),
      'calculated_current_balance', COALESCE(v_calculated_current, 0),
      'system_qty_on_hand', v_system_qty,
      'db_opening_balance_snapshot', v_db_opening_balance,
      'db_date_ob', v_date_ob,
      'last_movement_at', v_last_movement_at,
      'discrepancy', v_discrepancy,
      'is_balanced', ABS(v_discrepancy) <= 0.001,
      'opname_mismatch_count', COALESCE(v_opname_mismatch_count, 0)
    ),
    'rows', v_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_stock_card(TEXT, BIGINT, TEXT, DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_stock_card(TEXT, BIGINT, TEXT, DATE, DATE) TO authenticated, service_role;

-- 6. RPC Read Preview: public.get_po_return_preview(p_po_id UUID)
CREATE OR REPLACE FUNCTION public.get_po_return_preview(p_po_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_user_role INTEGER;
    v_user_outlet TEXT;

    v_po RECORD;
    v_inv RECORD;
    v_ap RECORD;
    v_has_gr BOOLEAN := false;
    v_alloc_count INTEGER := 0;
    v_return_count INTEGER := 0;
    v_total_returned NUMERIC(15, 2) := 0;
    v_shipping_returned NUMERIC(15, 2) := 0;
    v_remaining_shipping NUMERIC(15, 2) := 0;
    v_total_qty_received NUMERIC(15, 4) := 0;

    v_mode_type TEXT := 'BLOCKED';
    v_can_process BOOLEAN := false;
    v_blocked_reason TEXT := NULL;

    v_items JSONB := '[]'::jsonb;
    v_history JSONB := '[]'::jsonb;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Autentikasi diperlukan.' USING ERRCODE = '42501';
    END IF;

    SELECT user_role, kode_outlet
    INTO v_user_role, v_user_outlet
    FROM public.users_profile
    WHERE uid = v_uid;

    IF v_user_role IS NULL OR v_user_role NOT IN (5, 6, 8, 10, 14) THEN
        RAISE EXCEPTION 'Akses ditolak. Role Anda tidak berwenang membatalkan atau meretur PO.' USING ERRCODE = '42501';
    END IF;

    IF p_po_id IS NULL THEN
        RAISE EXCEPTION 'ID PO wajib diisi.' USING ERRCODE = '22023';
    END IF;

    SELECT
        po.id,
        po.document_number,
        po.status::text AS status_text,
        po.kode_outlet,
        mo.name_outlet,
        po.kode_supplier,
        ms.name AS supplier_name,
        po.created_at,
        COALESCE(po.grand_total, 0) AS grand_total
    INTO v_po
    FROM public.purchase_orders po
    LEFT JOIN public.master_outlet mo ON mo.kode_outlet = po.kode_outlet
    LEFT JOIN public.master_supplier ms ON ms.kode_supplier = po.kode_supplier
    WHERE po.id = p_po_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Order tidak ditemukan.' USING ERRCODE = 'P0002';
    END IF;

    IF v_user_role IN (6, 10, 14) AND NULLIF(TRIM(v_user_outlet), '') IS DISTINCT FROM v_po.kode_outlet THEN
        RAISE EXCEPTION 'Akses ditolak. Anda hanya dapat mengelola PO milik cabang Anda sendiri (%).', COALESCE(v_user_outlet, '-') USING ERRCODE = '42501';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.goods_receipts gr WHERE gr.po_id = p_po_id
    ) INTO v_has_gr;

    SELECT
        COUNT(*)::integer,
        COALESCE(SUM(total_return_amount), 0)::numeric(15, 2)
    INTO v_return_count, v_total_returned
    FROM public.purchase_returns
    WHERE po_id = p_po_id;

    SELECT
        pi.id,
        pi.document_number,
        pi.supplier_invoice_number,
        pi.status,
        COALESCE(pi.total_amount, 0) AS total_amount,
        COALESCE(pi.shipping_cost, 0) AS shipping_cost
    INTO v_inv
    FROM public.purchase_invoices pi
    WHERE pi.purchase_order_id = p_po_id
      AND COALESCE(pi.invoice_type, 'INVOICE') = 'INVOICE'
    ORDER BY pi.created_at ASC
    LIMIT 1;

    IF v_inv.id IS NOT NULL THEN
        SELECT
            fal.id,
            COALESCE(fal.original_amount, 0) AS original_amount,
            COALESCE(fal.paid_amount, 0) AS paid_amount,
            COALESCE(fal.remaining_balance, 0) AS remaining_balance,
            COALESCE(fal.is_paid, false) AS is_paid
        INTO v_ap
        FROM public.finance_ap_ledger fal
        WHERE fal.invoice_id = v_inv.id
        LIMIT 1;

        SELECT COUNT(*)::integer
        INTO v_alloc_count
        FROM public.finance_payment_allocations fpa
        WHERE fpa.invoice_id = v_inv.id;

        SELECT COALESCE(SUM(pr.shipping_deduction), 0)::numeric(15, 2)
        INTO v_shipping_returned
        FROM public.purchase_returns pr
        WHERE pr.po_id = p_po_id
          AND pr.linked_invoice_id = v_inv.id;

        v_remaining_shipping := GREATEST(0, COALESCE(v_inv.shipping_cost, 0) - v_shipping_returned);
    END IF;

    SELECT COALESCE(SUM(COALESCE(qty_received, 0)), 0)
    INTO v_total_qty_received
    FROM public.purchase_order_items
    WHERE po_id = p_po_id;

    -- Determine action eligibility
    IF v_po.status_text = 'PAID' THEN
        v_mode_type := 'BLOCKED';
        v_can_process := false;
        v_blocked_reason := 'PO dengan status PAID (Lunas) tidak diperbolehkan untuk dibatalkan atau diretur.';
    ELSIF v_po.status_text IN ('CANCELLED', 'RETURNED', 'DRAFT') THEN
        v_mode_type := 'BLOCKED';
        v_can_process := false;
        v_blocked_reason := 'PO dengan status ' || v_po.status_text || ' tidak dapat diproses untuk pembatalan/retur.';
    ELSIF v_inv.id IS NOT NULL AND (
        v_inv.status IN ('PAID', 'PARTIAL')
        OR COALESCE(v_ap.paid_amount, 0) > 0
        OR COALESCE(v_ap.is_paid, false) = true
        OR v_alloc_count > 0
    ) THEN
        v_mode_type := 'BLOCKED';
        v_can_process := false;
        v_blocked_reason := 'Faktur PO (' || v_inv.document_number || ') sudah memiliki pembayaran (status ' || v_inv.status || '), sehingga tidak dapat dibatalkan atau diretur.';
    ELSIF v_po.status_text = 'ISSUED' AND NOT v_has_gr AND v_inv.id IS NULL THEN
        v_mode_type := 'SIMPLE_CANCEL';
        v_can_process := true;
    ELSIF NOT v_has_gr THEN
        v_mode_type := 'BLOCKED';
        v_can_process := false;
        v_blocked_reason := 'PO belum memiliki catatan penerimaan barang (GR).';
    ELSIF v_total_qty_received <= 0 THEN
        v_mode_type := 'BLOCKED';
        v_can_process := false;
        v_blocked_reason := 'Seluruh item pada PO ini belum diterima atau sudah habis diretur.';
    ELSE
        v_mode_type := 'RETURN_AFTER_GR';
        v_can_process := true;
    END IF;

    -- Build item list
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'po_item_id', poi.id,
            'barang_id', poi.barang_id,
            'sku', COALESCE(mb.sku, '-'),
            'item_name', COALESCE(mb.name, 'Tanpa Nama'),
            'uom_purchase', poi.uom_purchase,
            'base_uom', COALESCE((
                SELECT COALESCE(NULLIF(TRIM(bu.base_uom), ''), NULLIF(TRIM(bu.purchase_uom), ''), 'PCS')
                FROM public.barang_units bu
                WHERE bu.barang_id = poi.barang_id
                  AND bu.kode_outlet IN (v_po.kode_outlet, mb.kode_outlet, '901')
                ORDER BY CASE
                    WHEN bu.kode_outlet = v_po.kode_outlet THEN 1
                    WHEN bu.kode_outlet = mb.kode_outlet THEN 2
                    WHEN bu.kode_outlet = '901' THEN 3
                    ELSE 4
                END
                LIMIT 1
            ), 'PCS'),
            'conversion_rate', COALESCE(poi.conversion_rate, 1),
            'price_per_unit', COALESCE(poi.price_per_unit, 0),
            'qty_ordered', COALESCE(poi.qty_ordered, 0),
            'qty_received', COALESCE(poi.qty_received, 0),
            'qty_base_received', ROUND((COALESCE(poi.qty_received, 0) * COALESCE(poi.conversion_rate, 1))::numeric, 4),
            'current_stock_on_hand', COALESCE((
                SELECT ib.qty_on_hand
                FROM public.inventory_balance ib
                WHERE ib.barang_id = poi.barang_id
                  AND ib.kode_outlet = v_po.kode_outlet
                LIMIT 1
            ), 0)
        )
        ORDER BY mb.name ASC, poi.id ASC
    ), '[]'::jsonb)
    INTO v_items
    FROM public.purchase_order_items poi
    JOIN public.master_barang mb ON mb.id = poi.barang_id
    WHERE poi.po_id = p_po_id
      AND (v_mode_type = 'SIMPLE_CANCEL' OR COALESCE(poi.qty_received, 0) > 0);

    -- Build return history for this PO
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', pr.id,
            'document_number', pr.document_number,
            'return_type', pr.return_type,
            'reason', pr.reason,
            'items_return_amount', pr.items_return_amount,
            'shipping_deduction', pr.shipping_deduction,
            'total_return_amount', pr.total_return_amount,
            'deduction_invoice_id', pr.deduction_invoice_id,
            'deduction_invoice_doc', dn.document_number,
            'created_by_name', pr.created_by_name,
            'created_at', pr.created_at,
            'items', COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'barang_id', pri.barang_id,
                        'sku', COALESCE(mb2.sku, '-'),
                        'item_name', COALESCE(mb2.name, 'Tanpa Nama'),
                        'uom_purchase', COALESCE(poi2.uom_purchase, 'UNIT'),
                        'qty_returned', pri.qty_returned,
                        'qty_base_unit', pri.qty_base_unit,
                        'price_per_unit', pri.price_per_unit,
                        'subtotal', pri.subtotal
                    )
                    ORDER BY mb2.name ASC
                )
                FROM public.purchase_return_items pri
                JOIN public.master_barang mb2 ON mb2.id = pri.barang_id
                LEFT JOIN public.purchase_order_items poi2 ON poi2.id = pri.po_item_id
                WHERE pri.return_id = pr.id
            ), '[]'::jsonb)
        )
        ORDER BY pr.created_at DESC
    ), '[]'::jsonb)
    INTO v_history
    FROM public.purchase_returns pr
    LEFT JOIN public.purchase_invoices dn ON dn.id = pr.deduction_invoice_id
    WHERE pr.po_id = p_po_id;

    RETURN jsonb_build_object(
        'po', jsonb_build_object(
            'id', v_po.id,
            'document_number', v_po.document_number,
            'status', v_po.status_text,
            'kode_outlet', v_po.kode_outlet,
            'name_outlet', COALESCE(v_po.name_outlet, v_po.kode_outlet),
            'kode_supplier', v_po.kode_supplier,
            'supplier_name', COALESCE(v_po.supplier_name, '-'),
            'created_at', v_po.created_at,
            'grand_total', v_po.grand_total,
            'has_goods_receipt', v_has_gr,
            'return_count', v_return_count,
            'total_returned_amount', v_total_returned
        ),
        'invoice', CASE
            WHEN v_inv.id IS NULL THEN NULL
            ELSE jsonb_build_object(
                'id', v_inv.id,
                'document_number', v_inv.document_number,
                'supplier_invoice_number', v_inv.supplier_invoice_number,
                'status', v_inv.status,
                'total_amount', v_inv.total_amount,
                'shipping_cost', v_inv.shipping_cost,
                'ap_original_amount', COALESCE(v_ap.original_amount, v_inv.total_amount),
                'ap_paid_amount', COALESCE(v_ap.paid_amount, 0),
                'ap_remaining_balance', COALESCE(v_ap.remaining_balance, v_inv.total_amount),
                'payment_allocations_count', v_alloc_count,
                'shipping_already_returned', v_shipping_returned,
                'remaining_shipping_refundable', v_remaining_shipping
            )
        END,
        'mode_type', v_mode_type,
        'can_process', v_can_process,
        'blocked_reason', v_blocked_reason,
        'items', v_items,
        'history', v_history
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_po_return_preview(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_po_return_preview(UUID) TO authenticated, service_role;

-- 7. RPC Write Atomic: public.process_purchase_order_return(...)
CREATE OR REPLACE FUNCTION public.process_purchase_order_return(
    p_po_id UUID,
    p_mode TEXT,
    p_reason TEXT,
    p_items JSONB DEFAULT '[]'::jsonb,
    p_shipping_deduction NUMERIC DEFAULT 0,
    p_reopen_to_partial BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_user_role INTEGER;
    v_user_outlet TEXT;
    v_actor_name TEXT;

    v_mode TEXT := UPPER(TRIM(COALESCE(p_mode, '')));
    v_reason TEXT := TRIM(COALESCE(p_reason, ''));
    v_ts_label TEXT := TO_CHAR(now() AT TIME ZONE 'Asia/Jakarta', 'DD/MM/YYYY HH24:MI');

    v_po RECORD;
    v_has_gr BOOLEAN := false;
    v_inv RECORD;
    v_ap RECORD;
    v_alloc_count INTEGER := 0;

    v_item_row RECORD;
    v_stock_avail NUMERIC(15, 4) := 0;
    v_req_count INTEGER := 0;
    v_distinct_req_count INTEGER := 0;
    v_remaining_po_qty NUMERIC(15, 4) := 0;
    v_effective_type TEXT;

    v_items_return_total NUMERIC(15, 2) := 0;
    v_shipping_already_returned NUMERIC(15, 2) := 0;
    v_remaining_shipping NUMERIC(15, 2) := 0;
    v_shipping_ded NUMERIC(15, 2) := 0;
    v_total_return_amount NUMERIC(15, 2) := 0;

    v_return_id UUID;
    v_return_doc_no TEXT;
    v_dn_id UUID;
    v_dn_doc_no TEXT;
    v_new_ap_original NUMERIC(15, 2);
    v_new_po_status public.po_status;
    v_audit_note TEXT;
BEGIN
    -- 1. Auth & RBAC Validation (Roles 5, 6, 8, 10, 14)
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Autentikasi diperlukan.' USING ERRCODE = '42501';
    END IF;

    SELECT
        user_role,
        kode_outlet,
        COALESCE(NULLIF(TRIM(full_name), ''), NULLIF(TRIM(email), ''), 'Admin')
    INTO v_user_role, v_user_outlet, v_actor_name
    FROM public.users_profile
    WHERE uid = v_uid;

    IF v_user_role IS NULL OR v_user_role NOT IN (5, 6, 8, 10, 14) THEN
        RAISE EXCEPTION 'Akses ditolak. Role Anda tidak berwenang membatalkan atau meretur PO.' USING ERRCODE = '42501';
    END IF;

    IF p_po_id IS NULL THEN
        RAISE EXCEPTION 'ID PO wajib diisi.' USING ERRCODE = '22023';
    END IF;

    IF LENGTH(v_reason) < 10 THEN
        RAISE EXCEPTION 'Alasan pembatalan/retur wajib diisi minimal 10 karakter.' USING ERRCODE = '22023';
    END IF;

    -- 2. Lock PO row
    SELECT
        po.*,
        po.status::text AS status_text
    INTO v_po
    FROM public.purchase_orders po
    WHERE po.id = p_po_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Order tidak ditemukan.' USING ERRCODE = 'P0002';
    END IF;

    IF v_user_role IN (6, 10, 14) AND NULLIF(TRIM(v_user_outlet), '') IS DISTINCT FROM v_po.kode_outlet THEN
        RAISE EXCEPTION 'Akses ditolak. Anda hanya dapat memproses PO milik cabang Anda sendiri (%).', COALESCE(v_user_outlet, '-') USING ERRCODE = '42501';
    END IF;

    IF v_po.status_text = 'PAID' THEN
        RAISE EXCEPTION 'PO berstatus PAID (Lunas) tidak dapat dibatalkan atau diretur.' USING ERRCODE = '22023';
    END IF;

    IF v_po.status_text IN ('CANCELLED', 'RETURNED', 'DRAFT') THEN
        RAISE EXCEPTION 'PO dengan status % tidak dapat diproses lagi.', v_po.status_text USING ERRCODE = '22023';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.goods_receipts gr WHERE gr.po_id = p_po_id
    ) INTO v_has_gr;

    -- 3. Lock primary invoice & AP ledger if exists
    SELECT *
    INTO v_inv
    FROM public.purchase_invoices pi
    WHERE pi.purchase_order_id = p_po_id
      AND COALESCE(pi.invoice_type, 'INVOICE') = 'INVOICE'
    ORDER BY pi.created_at ASC
    LIMIT 1
    FOR UPDATE;

    IF v_inv.id IS NOT NULL THEN
        SELECT *
        INTO v_ap
        FROM public.finance_ap_ledger fal
        WHERE fal.invoice_id = v_inv.id
        LIMIT 1
        FOR UPDATE;

        SELECT COUNT(*)::integer
        INTO v_alloc_count
        FROM public.finance_payment_allocations fpa
        WHERE fpa.invoice_id = v_inv.id;

        IF v_inv.status IN ('PAID', 'PARTIAL')
           OR COALESCE(v_ap.paid_amount, 0) > 0
           OR COALESCE(v_ap.is_paid, false) = true
           OR v_alloc_count > 0 THEN
            RAISE EXCEPTION 'Faktur PO (%) sudah memiliki pembayaran (status %), sehingga tidak dapat dibatalkan atau diretur.',
                v_inv.document_number, v_inv.status USING ERRCODE = '22023';
        END IF;
    END IF;

    -- 4. Path A: Simple cancel for ISSUED PO with NO Goods Receipt and NO Invoice
    IF NOT v_has_gr THEN
        IF v_po.status_text = 'ISSUED' AND v_inv.id IS NULL THEN
            IF v_mode NOT IN ('', 'SIMPLE_CANCEL', 'FULL_RETURN') THEN
                RAISE EXCEPTION 'Mode tidak valid untuk PO yang belum memiliki penerimaan barang.' USING ERRCODE = '22023';
            END IF;

            v_audit_note := FORMAT('[BATAL PO %s WIB oleh %s] %s', v_ts_label, v_actor_name, v_reason);

            UPDATE public.purchase_orders
            SET status = 'CANCELLED'::public.po_status,
                notes = CASE
                    WHEN NULLIF(TRIM(notes), '') IS NULL THEN v_audit_note
                    ELSE TRIM(notes) || E'\n' || v_audit_note
                END
            WHERE id = p_po_id;

            RETURN jsonb_build_object(
                'success', true,
                'action', 'CANCELLED_NO_GR',
                'po_id', p_po_id,
                'po_document_number', v_po.document_number,
                'new_po_status', 'CANCELLED',
                'return_id', NULL,
                'return_document_number', NULL,
                'deduction_invoice_id', NULL,
                'deduction_invoice_number', NULL,
                'total_return_amount', 0,
                'message', FORMAT('PO %s berhasil dibatalkan (CANCELLED) tanpa dokumen retur stok.', v_po.document_number)
            );
        ELSE
            RAISE EXCEPTION 'PO belum memiliki catatan penerimaan barang (GR).' USING ERRCODE = '22023';
        END IF;
    END IF;

    -- 5. Path B: Reversal / Return after Goods Receipt (PARTIAL, COMPLETED, INVOICED)
    IF v_mode NOT IN ('FULL_RETURN', 'PARTIAL_RETURN') THEN
        RAISE EXCEPTION 'Mode retur harus FULL_RETURN atau PARTIAL_RETURN.' USING ERRCODE = '22023';
    END IF;

    CREATE TEMP TABLE tmp_po_return_lines (
        po_item_id UUID PRIMARY KEY,
        barang_id BIGINT NOT NULL,
        sku TEXT NOT NULL,
        item_name TEXT NOT NULL,
        qty_received NUMERIC(15, 4) NOT NULL,
        qty_return NUMERIC(15, 4) NOT NULL,
        conversion_rate NUMERIC(15, 4) NOT NULL,
        qty_base_return NUMERIC(15, 4) NOT NULL,
        price_per_unit NUMERIC(15, 2) NOT NULL
    ) ON COMMIT DROP;

    IF v_mode = 'FULL_RETURN' THEN
        INSERT INTO tmp_po_return_lines (
            po_item_id, barang_id, sku, item_name,
            qty_received, qty_return, conversion_rate, qty_base_return, price_per_unit
        )
        SELECT
            poi.id,
            poi.barang_id,
            COALESCE(mb.sku, '-'),
            COALESCE(mb.name, 'Tanpa Nama'),
            COALESCE(poi.qty_received, 0),
            COALESCE(poi.qty_received, 0),
            COALESCE(poi.conversion_rate, 1),
            ROUND((COALESCE(poi.qty_received, 0) * COALESCE(poi.conversion_rate, 1))::numeric, 4),
            COALESCE(poi.price_per_unit, 0)
        FROM public.purchase_order_items poi
        JOIN public.master_barang mb ON mb.id = poi.barang_id
        WHERE poi.po_id = p_po_id
          AND COALESCE(poi.qty_received, 0) > 0
        ORDER BY poi.id;
    ELSE
        IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
            RAISE EXCEPTION 'Daftar item retur (p_items) harus berupa array.' USING ERRCODE = '22023';
        END IF;

        SELECT
            COUNT(*)::integer,
            COUNT(DISTINCT (elem->>'po_item_id'))::integer
        INTO v_req_count, v_distinct_req_count
        FROM jsonb_array_elements(p_items) elem;

        IF v_req_count = 0 THEN
            RAISE EXCEPTION 'Pilih minimal 1 item dengan kuantitas retur lebih dari 0.' USING ERRCODE = '22023';
        END IF;

        IF v_req_count <> v_distinct_req_count THEN
            RAISE EXCEPTION 'Terdapat duplikasi item PO pada daftar retur.' USING ERRCODE = '22023';
        END IF;

        FOR v_item_row IN
            SELECT
                (elem->>'po_item_id')::uuid AS req_po_item_id,
                COALESCE((elem->>'qty_returned')::numeric, 0) AS req_qty
            FROM jsonb_array_elements(p_items) elem
        LOOP
            IF v_item_row.req_qty <= 0 THEN
                RAISE EXCEPTION 'Kuantitas retur tiap item yang dipilih harus lebih dari 0.' USING ERRCODE = '22023';
            END IF;

            INSERT INTO tmp_po_return_lines (
                po_item_id, barang_id, sku, item_name,
                qty_received, qty_return, conversion_rate, qty_base_return, price_per_unit
            )
            SELECT
                poi.id,
                poi.barang_id,
                COALESCE(mb.sku, '-'),
                COALESCE(mb.name, 'Tanpa Nama'),
                COALESCE(poi.qty_received, 0),
                ROUND(v_item_row.req_qty::numeric, 4),
                COALESCE(poi.conversion_rate, 1),
                ROUND((v_item_row.req_qty * COALESCE(poi.conversion_rate, 1))::numeric, 4),
                COALESCE(poi.price_per_unit, 0)
            FROM public.purchase_order_items poi
            JOIN public.master_barang mb ON mb.id = poi.barang_id
            WHERE poi.id = v_item_row.req_po_item_id
              AND poi.po_id = p_po_id
            FOR UPDATE OF poi;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Item PO (%) tidak ditemukan pada PO ini.', v_item_row.req_po_item_id USING ERRCODE = '22023';
            END IF;
        END LOOP;

        -- Validate qty_return <= qty_received
        FOR v_item_row IN
            SELECT * FROM tmp_po_return_lines WHERE qty_return > qty_received
        LOOP
            RAISE EXCEPTION 'Qty retur item "%" (%) melebihi qty diterima yang tersedia (%).',
                v_item_row.item_name, v_item_row.qty_return, v_item_row.qty_received USING ERRCODE = '22023';
        END LOOP;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tmp_po_return_lines) THEN
        RAISE EXCEPTION 'Tidak ada item diterima yang dapat diretur pada PO ini.' USING ERRCODE = '22023';
    END IF;

    -- Lock inventory_balance rows in deterministic order (per barang_id) and verify sufficient stock
    FOR v_item_row IN
        SELECT
            t.barang_id,
            MIN(t.sku) AS sku,
            MIN(t.item_name) AS item_name,
            SUM(t.qty_base_return) AS total_base_return
        FROM tmp_po_return_lines t
        GROUP BY t.barang_id
        ORDER BY t.barang_id
    LOOP
        SELECT ib.qty_on_hand
        INTO v_stock_avail
        FROM public.inventory_balance ib
        WHERE ib.barang_id = v_item_row.barang_id
          AND ib.kode_outlet = v_po.kode_outlet
        FOR UPDATE;

        v_stock_avail := COALESCE(v_stock_avail, 0);

        IF v_stock_avail < v_item_row.total_base_return THEN
            RAISE EXCEPTION 'Stok gudang untuk "%" (SKU: %) tidak mencukupi untuk diretur. Dibutuhkan: %, tersedia saat ini: %.',
                v_item_row.item_name,
                v_item_row.sku,
                TRIM(TO_CHAR(v_item_row.total_base_return, 'FM999999990.##')),
                TRIM(TO_CHAR(v_stock_avail, 'FM999999990.##'))
            USING ERRCODE = '22023';
        END IF;
    END LOOP;

    -- Determine if all received quantities on this PO will become 0 after this return
    SELECT COALESCE(SUM(
        GREATEST(0, COALESCE(poi.qty_received, 0) - COALESCE(t.qty_return, 0))
    ), 0)
    INTO v_remaining_po_qty
    FROM public.purchase_order_items poi
    LEFT JOIN tmp_po_return_lines t ON t.po_item_id = poi.id
    WHERE poi.po_id = p_po_id;

    v_effective_type := CASE
        WHEN v_remaining_po_qty <= 0.0001 THEN 'FULL_RETURN'
        ELSE 'PARTIAL_RETURN'
    END;

    -- Totals
    SELECT COALESCE(SUM(ROUND((qty_return * price_per_unit)::numeric, 2)), 0)::numeric(15, 2)
    INTO v_items_return_total
    FROM tmp_po_return_lines;

    IF v_inv.id IS NOT NULL THEN
        SELECT COALESCE(SUM(pr.shipping_deduction), 0)::numeric(15, 2)
        INTO v_shipping_already_returned
        FROM public.purchase_returns pr
        WHERE pr.po_id = p_po_id
          AND pr.linked_invoice_id = v_inv.id;

        v_remaining_shipping := GREATEST(0, COALESCE(v_inv.shipping_cost, 0) - v_shipping_already_returned);

        IF v_effective_type = 'FULL_RETURN' THEN
            v_shipping_ded := v_remaining_shipping;
        ELSE
            v_shipping_ded := ROUND(COALESCE(p_shipping_deduction, 0)::numeric, 2);
            IF v_shipping_ded < 0 OR v_shipping_ded > v_remaining_shipping THEN
                RAISE EXCEPTION 'Potongan ongkos kirim harus antara 0 hingga sisa ongkir yang tersedia (%).',
                    v_remaining_shipping USING ERRCODE = '22023';
            END IF;
        END IF;
    ELSE
        v_shipping_ded := 0;
    END IF;

    v_total_return_amount := ROUND((v_items_return_total + v_shipping_ded)::numeric, 2);

    IF v_inv.id IS NOT NULL THEN
        IF v_effective_type = 'FULL_RETURN'
           AND ABS(COALESCE(v_ap.original_amount, v_inv.total_amount) - v_total_return_amount) <= 1.00 THEN
            v_total_return_amount := COALESCE(v_ap.original_amount, v_inv.total_amount);
        END IF;

        IF v_total_return_amount > COALESCE(v_ap.original_amount, v_inv.total_amount) THEN
            RAISE EXCEPTION 'Total nilai retur (%) melebihi sisa hutang AP faktur saat ini (%).',
                v_total_return_amount, COALESCE(v_ap.original_amount, v_inv.total_amount) USING ERRCODE = '22023';
        END IF;
    END IF;

    -- 6. Insert purchase_returns & purchase_return_items
    v_return_doc_no := 'PR-' || TO_CHAR(now() AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD') || '-' ||
                       LPAD(nextval('public.seq_purchase_return_doc')::text, 4, '0');

    INSERT INTO public.purchase_returns (
        document_number,
        po_id,
        kode_outlet,
        kode_supplier,
        return_type,
        reason,
        items_return_amount,
        shipping_deduction,
        total_return_amount,
        linked_invoice_id,
        created_by,
        created_by_name
    ) VALUES (
        v_return_doc_no,
        p_po_id,
        v_po.kode_outlet,
        v_po.kode_supplier,
        v_effective_type,
        v_reason,
        v_items_return_total,
        v_shipping_ded,
        v_total_return_amount,
        v_inv.id,
        v_uid,
        v_actor_name
    )
    RETURNING id INTO v_return_id;

    INSERT INTO public.purchase_return_items (
        return_id,
        po_item_id,
        barang_id,
        qty_returned,
        conversion_rate,
        price_per_unit
    )
    SELECT
        v_return_id,
        t.po_item_id,
        t.barang_id,
        t.qty_return,
        t.conversion_rate,
        t.price_per_unit
    FROM tmp_po_return_lines t;

    -- 7. Deduct inventory_balance & purchase_order_items.qty_received
    UPDATE public.inventory_balance ib
    SET qty_on_hand = ib.qty_on_hand - agg.total_base_return,
        last_movement_at = now()
    FROM (
        SELECT barang_id, SUM(qty_base_return) AS total_base_return
        FROM tmp_po_return_lines
        GROUP BY barang_id
    ) agg
    WHERE ib.barang_id = agg.barang_id
      AND ib.kode_outlet = v_po.kode_outlet;

    UPDATE public.purchase_order_items poi
    SET qty_received = GREATEST(0, COALESCE(poi.qty_received, 0) - t.qty_return)
    FROM tmp_po_return_lines t
    WHERE poi.id = t.po_item_id;

    -- 8. If INVOICED: Create DEBIT_NOTE & adjust/close AP Ledger
    IF v_inv.id IS NOT NULL THEN
        v_dn_doc_no := 'DN-' || TO_CHAR(now() AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD') || '-' ||
                       LPAD(nextval('public.seq_purchase_debit_note_doc')::text, 4, '0');

        INSERT INTO public.purchase_invoices (
            document_number,
            purchase_order_id,
            kode_supplier,
            kode_outlet,
            supplier_invoice_number,
            invoice_date,
            payment_due_date,
            total_amount,
            shipping_cost,
            status,
            created_by,
            invoice_type,
            parent_invoice_id,
            purchase_return_id,
            notes
        ) VALUES (
            v_dn_doc_no,
            p_po_id,
            v_po.kode_supplier,
            v_po.kode_outlet,
            'RETUR-' || COALESCE(v_inv.supplier_invoice_number, v_inv.document_number),
            (now() AT TIME ZONE 'Asia/Jakarta')::date,
            v_inv.payment_due_date,
            -v_total_return_amount,
            -v_shipping_ded,
            'RETURNED',
            v_uid,
            'DEBIT_NOTE',
            v_inv.id,
            v_return_id,
            FORMAT('Faktur Pengurang / Nota Debet untuk Retur %s (Faktur Asli: %s). Alasan: %s',
                v_return_doc_no, v_inv.document_number, v_reason)
        )
        RETURNING id INTO v_dn_id;

        UPDATE public.purchase_returns
        SET deduction_invoice_id = v_dn_id
        WHERE id = v_return_id;

        v_new_ap_original := ROUND(GREATEST(0, COALESCE(v_ap.original_amount, v_inv.total_amount) - v_total_return_amount)::numeric, 2);

        IF v_effective_type = 'FULL_RETURN' OR v_new_ap_original <= 0 THEN
            UPDATE public.finance_ap_ledger
            SET original_amount = 0,
                is_paid = true
            WHERE invoice_id = v_inv.id;

            UPDATE public.purchase_invoices
            SET status = 'CANCELLED',
                notes = CASE
                    WHEN NULLIF(TRIM(notes), '') IS NULL THEN FORMAT('[DIBATALKAN via %s / %s] %s', v_return_doc_no, v_dn_doc_no, v_reason)
                    ELSE TRIM(notes) || E'\n' || FORMAT('[DIBATALKAN via %s / %s] %s', v_return_doc_no, v_dn_doc_no, v_reason)
                END
            WHERE id = v_inv.id;
        ELSE
            UPDATE public.finance_ap_ledger
            SET original_amount = v_new_ap_original,
                is_paid = false
            WHERE invoice_id = v_inv.id;

            UPDATE public.purchase_invoices
            SET notes = CASE
                WHEN NULLIF(TRIM(notes), '') IS NULL THEN FORMAT('[DIKURANGI %s via %s / %s] %s', v_total_return_amount, v_return_doc_no, v_dn_doc_no, v_reason)
                ELSE TRIM(notes) || E'\n' || FORMAT('[DIKURANGI %s via %s / %s] %s', v_total_return_amount, v_return_doc_no, v_dn_doc_no, v_reason)
            END
            WHERE id = v_inv.id;
        END IF;
    END IF;

    -- 9. Determine & update next PO status + audit note
    v_new_po_status := CASE
        WHEN v_effective_type = 'FULL_RETURN' THEN 'RETURNED'::public.po_status
        WHEN v_po.status_text = 'INVOICED' THEN 'INVOICED'::public.po_status
        WHEN v_po.status_text = 'COMPLETED' AND COALESCE(p_reopen_to_partial, false) THEN 'PARTIAL'::public.po_status
        WHEN v_po.status_text = 'COMPLETED' THEN 'COMPLETED'::public.po_status
        ELSE 'PARTIAL'::public.po_status
    END;

    v_audit_note := FORMAT(
        '[%s %s WIB | %s%s oleh %s] %s',
        CASE WHEN v_effective_type = 'FULL_RETURN' THEN 'RETUR PENUH PO' ELSE 'RETUR SEBAGIAN PO' END,
        v_ts_label,
        v_return_doc_no,
        CASE WHEN v_dn_doc_no IS NOT NULL THEN ' / Nota Debet ' || v_dn_doc_no ELSE '' END,
        v_actor_name,
        v_reason
    );

    UPDATE public.purchase_orders
    SET status = v_new_po_status,
        notes = CASE
            WHEN NULLIF(TRIM(notes), '') IS NULL THEN v_audit_note
            ELSE TRIM(notes) || E'\n' || v_audit_note
        END
    WHERE id = p_po_id;

    RETURN jsonb_build_object(
        'success', true,
        'action', v_effective_type,
        'po_id', p_po_id,
        'po_document_number', v_po.document_number,
        'new_po_status', v_new_po_status::text,
        'return_id', v_return_id,
        'return_document_number', v_return_doc_no,
        'deduction_invoice_id', v_dn_id,
        'deduction_invoice_number', v_dn_doc_no,
        'items_return_amount', v_items_return_total,
        'shipping_deduction', v_shipping_ded,
        'total_return_amount', v_total_return_amount,
        'message', FORMAT(
            'Retur %s untuk PO %s berhasil diproses (%s).%s',
            v_return_doc_no,
            v_po.document_number,
            CASE WHEN v_effective_type = 'FULL_RETURN' THEN 'Status PO: RETURNED' ELSE 'Status PO: ' || v_new_po_status::text END,
            CASE WHEN v_dn_doc_no IS NOT NULL THEN ' Nota Debet: ' || v_dn_doc_no || '.' ELSE '' END
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.process_purchase_order_return(UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_purchase_order_return(UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
