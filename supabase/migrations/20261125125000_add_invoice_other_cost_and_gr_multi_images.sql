-- ============================================================================
-- Migration: Invoice Other Cost (+/- 2 Decimals) + GR Multi-Images (Max 3)
-- Date: 2026-11-25
-- Author: Zen Family Spa Architect
-- Description:
--   1. Add `other_cost` NUMERIC(15,2) and `other_cost_notes` TEXT to `public.purchase_invoices`
--   2. Add `other_cost_deduction` NUMERIC(15,2) to `public.purchase_returns`
--   3. Add `image_url_2` TEXT and `image_url_3` TEXT to `public.goods_receipts`
--   4. Update `public.generate_purchase_invoice` (drop old overloads cleanly)
--   5. Append new columns to `view_report_purchase_invoices`,
--      `view_report_purchase_orders`, and `view_po_details_received`
--   6. Sync `get_po_return_preview()` and `process_purchase_order_return()`
--      with `other_cost` (+/-) & Debit Note integration
-- ============================================================================

-- 1. Schema Extensions
ALTER TABLE public.purchase_invoices
    ADD COLUMN IF NOT EXISTS other_cost NUMERIC(15, 2) NOT NULL DEFAULT 0;

ALTER TABLE public.purchase_invoices
    ADD COLUMN IF NOT EXISTS other_cost_notes TEXT NULL;

ALTER TABLE public.purchase_returns
    ADD COLUMN IF NOT EXISTS other_cost_deduction NUMERIC(15, 2) NOT NULL DEFAULT 0;

ALTER TABLE public.goods_receipts
    ADD COLUMN IF NOT EXISTS image_url_2 TEXT NULL;

ALTER TABLE public.goods_receipts
    ADD COLUMN IF NOT EXISTS image_url_3 TEXT NULL;

-- 2. Update generate_purchase_invoice (drop all existing overloads to avoid PostgREST ambiguity)
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT oid::regprocedure AS sig
        FROM pg_proc
        WHERE proname = 'generate_purchase_invoice'
          AND pronamespace = 'public'::regnamespace
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.sig;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.generate_purchase_invoice(
    target_po_id uuid,
    supplier_inv_ref text,
    payment_due_date date,
    shipping_cost_input numeric DEFAULT 0,
    other_cost_input numeric DEFAULT 0,
    other_cost_notes_input text DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $BODY$
DECLARE
    v_uid uuid := auth.uid();
    v_items_total numeric(15, 2);
    v_shipping_cost numeric(15, 2);
    v_other_cost numeric(15, 2);
    v_other_cost_notes text;
    v_supplier_ref text;
    v_total_amount numeric(15, 2);
    po_record RECORD;
    new_invoice_doc text;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Autentikasi diperlukan.' USING ERRCODE = '42501';
    END IF;

    IF target_po_id IS NULL THEN
        RAISE EXCEPTION 'ID PO wajib diisi.' USING ERRCODE = '22023';
    END IF;

    v_supplier_ref := NULLIF(TRIM(COALESCE(supplier_inv_ref, '')), '');
    IF v_supplier_ref IS NULL THEN
        RAISE EXCEPTION 'Nomor Faktur Pemasok (Invoice Supplier) wajib diisi.' USING ERRCODE = '22023';
    END IF;

    IF payment_due_date IS NULL THEN
        RAISE EXCEPTION 'Tanggal jatuh tempo pembayaran wajib diisi.' USING ERRCODE = '22023';
    END IF;

    -- Lock PO header
    SELECT * INTO po_record
    FROM public.purchase_orders
    WHERE id = target_po_id
    FOR UPDATE;

    IF po_record.id IS NULL THEN
        RAISE EXCEPTION 'Purchase Order tidak ditemukan.' USING ERRCODE = 'P0002';
    END IF;

    IF po_record.status::text <> 'COMPLETED' THEN
        RAISE EXCEPTION 'Hanya PO berstatus COMPLETED yang dapat diterbitkan faktur (status saat ini: %).',
            po_record.status::text USING ERRCODE = '22023';
    END IF;

    v_shipping_cost := ROUND(COALESCE(shipping_cost_input, 0)::numeric, 2);
    IF v_shipping_cost < 0 THEN
        RAISE EXCEPTION 'Ongkos kirim tidak boleh bernilai negatif.' USING ERRCODE = '22023';
    END IF;

    v_other_cost := ROUND(COALESCE(other_cost_input, 0)::numeric, 2);
    v_other_cost_notes := NULLIF(TRIM(COALESCE(other_cost_notes_input, '')), '');

    IF v_other_cost <> 0 AND v_other_cost_notes IS NULL THEN
        RAISE EXCEPTION 'Keterangan biaya lain-lain wajib diisi apabila nominal biaya lain-lain tidak sama dengan 0.' USING ERRCODE = '22023';
    END IF;

    -- Calculate Items Total from RECEIVED items
    SELECT ROUND(COALESCE(SUM(qty_received * price_per_unit), 0)::numeric, 2)
    INTO v_items_total
    FROM public.purchase_order_items
    WHERE po_id = target_po_id;

    -- Grand Total = Items + Shipping + Other Cost (2 decimals, positive or negative other cost allowed)
    v_total_amount := ROUND((v_items_total + v_shipping_cost + v_other_cost)::numeric, 2);

    IF v_total_amount < 0 THEN
        RAISE EXCEPTION 'Total faktur (%) tidak boleh bernilai negatif. Periksa kembali nominal biaya lain-lain.',
            v_total_amount USING ERRCODE = '22023';
    END IF;

    -- Generate Document Number
    new_invoice_doc := 'INV-' || to_char(NOW() AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD') || '-' || substring(cast(target_po_id as text), 1, 4);

    -- Insert Invoice Record (auto_post_ap_ledger trigger posts AP debt using NEW.total_amount)
    INSERT INTO public.purchase_invoices (
        document_number,
        purchase_order_id,
        kode_supplier,
        kode_outlet,
        supplier_invoice_number,
        payment_due_date,
        total_amount,
        shipping_cost,
        other_cost,
        other_cost_notes,
        status,
        created_by
    ) VALUES (
        new_invoice_doc,
        target_po_id,
        po_record.kode_supplier,
        po_record.kode_outlet,
        v_supplier_ref,
        payment_due_date,
        v_total_amount,
        v_shipping_cost,
        v_other_cost,
        v_other_cost_notes,
        'UNPAID',
        v_uid
    );

    -- Update PO Status to INVOICED
    UPDATE public.purchase_orders
    SET status = 'INVOICED'::public.po_status
    WHERE id = target_po_id;

    RETURN v_total_amount;
END;
$BODY$;

REVOKE ALL ON FUNCTION public.generate_purchase_invoice(uuid, text, date, numeric, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.generate_purchase_invoice(uuid, text, date, numeric, numeric, text) TO authenticated, service_role;

-- 3. Reporting Views (Strictly Append New Columns at End)
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
    inv.purchase_return_id,
    inv.other_cost,
    inv.other_cost_notes
FROM public.purchase_invoices inv
JOIN public.purchase_orders po ON inv.purchase_order_id = po.id
JOIN public.master_supplier s ON po.kode_supplier = s.kode_supplier;

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
        SELECT COALESCE(
            NULLIF(TRIM(gr.image_url), ''),
            NULLIF(TRIM(gr.image_url_2), ''),
            NULLIF(TRIM(gr.image_url_3), '')
        )
        FROM public.goods_receipts gr
        WHERE gr.po_id = po.id
          AND (
              NULLIF(TRIM(gr.image_url), '') IS NOT NULL
              OR NULLIF(TRIM(gr.image_url_2), '') IS NOT NULL
              OR NULLIF(TRIM(gr.image_url_3), '') IS NOT NULL
          )
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
    ) AS latest_debit_note_id,
    COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object(
                'gr_id', gr_img.id,
                'gr_doc', gr_img.document_number,
                'received_at', gr_img.received_at,
                'slot', u.slot,
                'url', TRIM(u.url)
            )
            ORDER BY gr_img.received_at DESC NULLS LAST, gr_img.document_number DESC, u.slot ASC
        )
        FROM public.goods_receipts gr_img
        CROSS JOIN LATERAL (
            VALUES
                (1, gr_img.image_url),
                (2, gr_img.image_url_2),
                (3, gr_img.image_url_3)
        ) AS u(slot, url)
        WHERE gr_img.po_id = po.id
          AND NULLIF(TRIM(u.url), '') IS NOT NULL
    ), '[]'::jsonb) AS receipt_images
FROM public.purchase_orders po
JOIN public.master_supplier s ON po.kode_supplier = s.kode_supplier;

CREATE OR REPLACE VIEW public.view_po_details_received AS
SELECT
    poi.id AS po_item_id,
    poi.po_id,
    po.kode_outlet,
    po.created_at AS po_created_at,
    po.document_number,
    b.name AS item_name,
    b.sku,
    poi.uom_purchase,
    poi.qty_ordered,
    poi.qty_received AS qty_already_received,
    poi.qty_ordered - poi.qty_received AS qty_remaining,
    poi.price_per_unit,
    poi.qty_ordered * poi.price_per_unit AS total_price_po,
    poi.qty_received * poi.price_per_unit AS total_price_received,
    (
        SELECT gr.id
        FROM public.goods_receipts gr
        WHERE gr.po_id = po.id
        ORDER BY gr.received_at DESC
        LIMIT 1
    ) AS latest_gr_id,
    (
        SELECT COALESCE(
            NULLIF(TRIM(gr.image_url), ''),
            NULLIF(TRIM(gr.image_url_2), ''),
            NULLIF(TRIM(gr.image_url_3), '')
        )
        FROM public.goods_receipts gr
        WHERE gr.po_id = po.id
          AND (
              NULLIF(TRIM(gr.image_url), '') IS NOT NULL
              OR NULLIF(TRIM(gr.image_url_2), '') IS NOT NULL
              OR NULLIF(TRIM(gr.image_url_3), '') IS NOT NULL
          )
        ORDER BY gr.received_at DESC
        LIMIT 1
    ) AS receipt_image_url,
    COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object(
                'gr_id', gr_img.id,
                'gr_doc', gr_img.document_number,
                'received_at', gr_img.received_at,
                'slot', u.slot,
                'url', TRIM(u.url)
            )
            ORDER BY gr_img.received_at DESC NULLS LAST, gr_img.document_number DESC, u.slot ASC
        )
        FROM public.goods_receipts gr_img
        CROSS JOIN LATERAL (
            VALUES
                (1, gr_img.image_url),
                (2, gr_img.image_url_2),
                (3, gr_img.image_url_3)
        ) AS u(slot, url)
        WHERE gr_img.po_id = po.id
          AND NULLIF(TRIM(u.url), '') IS NOT NULL
    ), '[]'::jsonb) AS receipt_images
FROM public.purchase_order_items poi
JOIN public.master_barang b ON poi.barang_id = b.id
JOIN public.purchase_orders po ON poi.po_id = po.id;

-- 4. Update Purchase Return Preview RPC (with other_cost +/- support)
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
    v_other_cost_returned NUMERIC(15, 2) := 0;
    v_remaining_other_cost NUMERIC(15, 2) := 0;
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
        COALESCE(pi.shipping_cost, 0) AS shipping_cost,
        COALESCE(pi.other_cost, 0) AS other_cost,
        pi.other_cost_notes
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

        SELECT
            COALESCE(SUM(pr.shipping_deduction), 0)::numeric(15, 2),
            COALESCE(SUM(pr.other_cost_deduction), 0)::numeric(15, 2)
        INTO v_shipping_returned, v_other_cost_returned
        FROM public.purchase_returns pr
        WHERE pr.po_id = p_po_id
          AND pr.linked_invoice_id = v_inv.id;

        v_remaining_shipping := GREATEST(0, COALESCE(v_inv.shipping_cost, 0) - v_shipping_returned);
        -- Allow negative or positive other_cost remaining without clamping to 0
        v_remaining_other_cost := ROUND((COALESCE(v_inv.other_cost, 0) - v_other_cost_returned)::numeric, 2);
    END IF;

    SELECT COALESCE(SUM(COALESCE(qty_received, 0)), 0)
    INTO v_total_qty_received
    FROM public.purchase_order_items
    WHERE po_id = p_po_id;

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

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', pr.id,
            'document_number', pr.document_number,
            'return_type', pr.return_type,
            'reason', pr.reason,
            'items_return_amount', pr.items_return_amount,
            'shipping_deduction', pr.shipping_deduction,
            'other_cost_deduction', pr.other_cost_deduction,
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
                'other_cost', v_inv.other_cost,
                'other_cost_notes', v_inv.other_cost_notes,
                'ap_original_amount', COALESCE(v_ap.original_amount, v_inv.total_amount),
                'ap_paid_amount', COALESCE(v_ap.paid_amount, 0),
                'ap_remaining_balance', COALESCE(v_ap.remaining_balance, v_inv.total_amount),
                'payment_allocations_count', v_alloc_count,
                'shipping_already_returned', v_shipping_returned,
                'remaining_shipping_refundable', v_remaining_shipping,
                'other_cost_already_returned', v_other_cost_returned,
                'remaining_other_cost_refundable', v_remaining_other_cost
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

-- 5. Update process_purchase_order_return (drop all overloads first to avoid PostgREST ambiguity)
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT oid::regprocedure AS sig
        FROM pg_proc
        WHERE proname = 'process_purchase_order_return'
          AND pronamespace = 'public'::regnamespace
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.sig;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.process_purchase_order_return(
    p_po_id UUID,
    p_mode TEXT,
    p_reason TEXT,
    p_items JSONB DEFAULT '[]'::jsonb,
    p_shipping_deduction NUMERIC DEFAULT 0,
    p_reopen_to_partial BOOLEAN DEFAULT false,
    p_other_cost_deduction NUMERIC DEFAULT 0
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
    v_other_cost_already_returned NUMERIC(15, 2) := 0;
    v_remaining_other_cost NUMERIC(15, 2) := 0;
    v_other_cost_ded NUMERIC(15, 2) := 0;
    v_total_return_amount NUMERIC(15, 2) := 0;

    v_return_id UUID;
    v_return_doc_no TEXT;
    v_dn_id UUID;
    v_dn_doc_no TEXT;
    v_dn_other_notes TEXT;
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
                'items_return_amount', 0,
                'shipping_deduction', 0,
                'other_cost_deduction', 0,
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
        SELECT
            COALESCE(SUM(pr.shipping_deduction), 0)::numeric(15, 2),
            COALESCE(SUM(pr.other_cost_deduction), 0)::numeric(15, 2)
        INTO v_shipping_already_returned, v_other_cost_already_returned
        FROM public.purchase_returns pr
        WHERE pr.po_id = p_po_id
          AND pr.linked_invoice_id = v_inv.id;

        v_remaining_shipping := GREATEST(0, COALESCE(v_inv.shipping_cost, 0) - v_shipping_already_returned);
        v_remaining_other_cost := ROUND((COALESCE(v_inv.other_cost, 0) - v_other_cost_already_returned)::numeric, 2);

        IF v_effective_type = 'FULL_RETURN' THEN
            v_shipping_ded := v_remaining_shipping;
            v_other_cost_ded := v_remaining_other_cost;
        ELSE
            v_shipping_ded := ROUND(COALESCE(p_shipping_deduction, 0)::numeric, 2);
            IF v_shipping_ded < 0 OR v_shipping_ded > v_remaining_shipping THEN
                RAISE EXCEPTION 'Potongan ongkos kirim harus antara 0 hingga sisa ongkir yang tersedia (%).',
                    v_remaining_shipping USING ERRCODE = '22023';
            END IF;

            v_other_cost_ded := ROUND(COALESCE(p_other_cost_deduction, 0)::numeric, 2);
            IF v_remaining_other_cost >= 0 THEN
                IF v_other_cost_ded < 0 OR v_other_cost_ded > v_remaining_other_cost THEN
                    RAISE EXCEPTION 'Penyesuaian biaya lain-lain harus antara 0 hingga sisa biaya lain-lain yang tersedia (%).',
                        v_remaining_other_cost USING ERRCODE = '22023';
                END IF;
            ELSE
                IF v_other_cost_ded > 0 OR v_other_cost_ded < v_remaining_other_cost THEN
                    RAISE EXCEPTION 'Penyesuaian potongan biaya lain-lain harus antara % hingga 0.',
                        v_remaining_other_cost USING ERRCODE = '22023';
                END IF;
            END IF;
        END IF;
    ELSE
        v_shipping_ded := 0;
        v_other_cost_ded := 0;
    END IF;

    v_total_return_amount := ROUND((v_items_return_total + v_shipping_ded + v_other_cost_ded)::numeric, 2);

    IF v_total_return_amount < 0 THEN
        RAISE EXCEPTION 'Total nilai retur (%) tidak boleh bernilai negatif.',
            v_total_return_amount USING ERRCODE = '22023';
    END IF;

    IF v_inv.id IS NOT NULL THEN
        IF v_effective_type = 'FULL_RETURN'
           AND ABS(COALESCE(v_ap.original_amount, v_inv.total_amount) - v_total_return_amount) <= 1.00 THEN
            v_total_return_amount := COALESCE(v_ap.original_amount, v_inv.total_amount);
        END IF;

        IF v_total_return_amount > COALESCE(v_ap.original_amount, v_inv.total_amount) THEN
            IF v_remaining_other_cost < 0 THEN
                RAISE EXCEPTION 'Total nilai retur (%) melebihi sisa hutang AP faktur saat ini (%). Sesuaikan nilai penyesuaian potongan biaya lain-lain agar tidak melebihi sisa hutang AP.',
                    v_total_return_amount, COALESCE(v_ap.original_amount, v_inv.total_amount) USING ERRCODE = '22023';
            ELSE
                RAISE EXCEPTION 'Total nilai retur (%) melebihi sisa hutang AP faktur saat ini (%).',
                    v_total_return_amount, COALESCE(v_ap.original_amount, v_inv.total_amount) USING ERRCODE = '22023';
            END IF;
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
        other_cost_deduction,
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
        v_other_cost_ded,
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

        v_dn_other_notes := CASE
            WHEN v_other_cost_ded <> 0 THEN COALESCE(NULLIF(TRIM(v_inv.other_cost_notes), ''), 'Penyesuaian Biaya Lain-lain')
            ELSE NULL
        END;

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
            other_cost,
            other_cost_notes,
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
            -v_other_cost_ded,
            v_dn_other_notes,
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
        'other_cost_deduction', v_other_cost_ded,
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

REVOKE ALL ON FUNCTION public.process_purchase_order_return(UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_purchase_order_return(UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN, NUMERIC) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
