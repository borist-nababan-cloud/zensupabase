-- ============================================================================
-- Migration: Fix HTTP 500 (SQLSTATE 55000) in get_po_return_preview & Hardening
-- Date: 2026-11-26
-- Author: Zen Family Spa Architect
-- Root Cause:
--   In `get_po_return_preview(UUID)`, `v_ap RECORD` was only assigned inside
--   `IF v_inv.id IS NOT NULL THEN ... END IF;`. On any PO without an invoice
--   (ISSUED, PARTIAL, COMPLETED), a fresh PostgreSQL session had no TupleDesc
--   for `v_ap`, so PL/pgSQL raised `55000: record "v_ap" is not assigned yet`
--   when binding parameters for `ELSIF v_inv.id IS NOT NULL AND (... v_ap.*)`
--   and `RETURN jsonb_build_object(..., 'invoice', CASE WHEN ... v_ap.* END)`.
-- Fixes:
--   1. Replace `v_inv RECORD` and `v_ap RECORD` with explicitly typed scalar
--      variables in both `get_po_return_preview()` and
--      `process_purchase_order_return()`, and construct `v_invoice_json` only
--      when `v_inv_id IS NOT NULL`.
--   2. Add `DROP TABLE IF EXISTS pg_temp.tmp_po_return_lines;` before creating
--      the temp table in `process_purchase_order_return()` to prevent `42P07`
--      if invoked multiple times within a single transaction.
--   3. Format stock shortage quantities in `process_purchase_order_return()`
--      using up to 4 decimals (`FM999999990.####`) aligned with NUMERIC(15,4).
-- ============================================================================

-- 1. Fix public.get_po_return_preview(UUID)
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

    -- Explicitly typed invoice scalars (eliminates unassigned RECORD SQLSTATE 55000)
    v_inv_id UUID := NULL;
    v_inv_doc_number TEXT := NULL;
    v_inv_supplier_number TEXT := NULL;
    v_inv_status TEXT := NULL;
    v_inv_total_amount NUMERIC(15, 2) := 0;
    v_inv_shipping_cost NUMERIC(15, 2) := 0;
    v_inv_other_cost NUMERIC(15, 2) := 0;
    v_inv_other_cost_notes TEXT := NULL;

    -- Explicitly typed AP ledger scalars (eliminates unassigned RECORD SQLSTATE 55000)
    v_ap_id UUID := NULL;
    v_ap_original_amount NUMERIC(15, 2) := NULL;
    v_ap_paid_amount NUMERIC(15, 2) := 0;
    v_ap_remaining_balance NUMERIC(15, 2) := NULL;
    v_ap_is_paid BOOLEAN := false;

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

    v_invoice_json JSONB := NULL;
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
        COALESCE(pi.total_amount, 0)::numeric(15, 2),
        COALESCE(pi.shipping_cost, 0)::numeric(15, 2),
        COALESCE(pi.other_cost, 0)::numeric(15, 2),
        pi.other_cost_notes
    INTO
        v_inv_id,
        v_inv_doc_number,
        v_inv_supplier_number,
        v_inv_status,
        v_inv_total_amount,
        v_inv_shipping_cost,
        v_inv_other_cost,
        v_inv_other_cost_notes
    FROM public.purchase_invoices pi
    WHERE pi.purchase_order_id = p_po_id
      AND COALESCE(pi.invoice_type, 'INVOICE') = 'INVOICE'
    ORDER BY pi.created_at ASC
    LIMIT 1;

    IF v_inv_id IS NOT NULL THEN
        SELECT
            fal.id,
            COALESCE(fal.original_amount, 0)::numeric(15, 2),
            COALESCE(fal.paid_amount, 0)::numeric(15, 2),
            COALESCE(fal.remaining_balance, 0)::numeric(15, 2),
            COALESCE(fal.is_paid, false)
        INTO
            v_ap_id,
            v_ap_original_amount,
            v_ap_paid_amount,
            v_ap_remaining_balance,
            v_ap_is_paid
        FROM public.finance_ap_ledger fal
        WHERE fal.invoice_id = v_inv_id
        LIMIT 1;

        SELECT COUNT(*)::integer
        INTO v_alloc_count
        FROM public.finance_payment_allocations fpa
        WHERE fpa.invoice_id = v_inv_id;

        SELECT
            COALESCE(SUM(pr.shipping_deduction), 0)::numeric(15, 2),
            COALESCE(SUM(pr.other_cost_deduction), 0)::numeric(15, 2)
        INTO v_shipping_returned, v_other_cost_returned
        FROM public.purchase_returns pr
        WHERE pr.po_id = p_po_id
          AND pr.linked_invoice_id = v_inv_id;

        v_remaining_shipping := GREATEST(0, COALESCE(v_inv_shipping_cost, 0) - COALESCE(v_shipping_returned, 0));
        -- Allow negative or positive other_cost remaining without clamping to 0
        v_remaining_other_cost := ROUND((COALESCE(v_inv_other_cost, 0) - COALESCE(v_other_cost_returned, 0))::numeric, 2);

        v_invoice_json := jsonb_build_object(
            'id', v_inv_id,
            'document_number', v_inv_doc_number,
            'supplier_invoice_number', v_inv_supplier_number,
            'status', v_inv_status,
            'total_amount', COALESCE(v_inv_total_amount, 0),
            'shipping_cost', COALESCE(v_inv_shipping_cost, 0),
            'other_cost', COALESCE(v_inv_other_cost, 0),
            'other_cost_notes', v_inv_other_cost_notes,
            'ap_original_amount', COALESCE(v_ap_original_amount, v_inv_total_amount, 0),
            'ap_paid_amount', COALESCE(v_ap_paid_amount, 0),
            'ap_remaining_balance', COALESCE(v_ap_remaining_balance, v_inv_total_amount, 0),
            'payment_allocations_count', COALESCE(v_alloc_count, 0),
            'shipping_already_returned', COALESCE(v_shipping_returned, 0),
            'remaining_shipping_refundable', COALESCE(v_remaining_shipping, 0),
            'other_cost_already_returned', COALESCE(v_other_cost_returned, 0),
            'remaining_other_cost_refundable', COALESCE(v_remaining_other_cost, 0)
        );
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
    ELSIF v_inv_id IS NOT NULL AND (
        v_inv_status IN ('PAID', 'PARTIAL')
        OR COALESCE(v_ap_paid_amount, 0) > 0
        OR COALESCE(v_ap_is_paid, false) = true
        OR COALESCE(v_alloc_count, 0) > 0
    ) THEN
        v_mode_type := 'BLOCKED';
        v_can_process := false;
        v_blocked_reason := 'Faktur PO (' || v_inv_doc_number || ') sudah memiliki pembayaran (status ' || v_inv_status || '), sehingga tidak dapat dibatalkan atau diretur.';
    ELSIF v_po.status_text = 'ISSUED' AND NOT v_has_gr AND v_inv_id IS NULL THEN
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
        'invoice', v_invoice_json,
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

-- 2. Harden public.process_purchase_order_return(...)
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

    -- Explicitly typed invoice scalars
    v_inv_id UUID := NULL;
    v_inv_doc_number TEXT := NULL;
    v_inv_supplier_number TEXT := NULL;
    v_inv_status TEXT := NULL;
    v_inv_total_amount NUMERIC(15, 2) := 0;
    v_inv_shipping_cost NUMERIC(15, 2) := 0;
    v_inv_other_cost NUMERIC(15, 2) := 0;
    v_inv_other_cost_notes TEXT := NULL;
    v_inv_due_date DATE := NULL;

    -- Explicitly typed AP ledger scalars
    v_ap_id UUID := NULL;
    v_ap_original_amount NUMERIC(15, 2) := NULL;
    v_ap_paid_amount NUMERIC(15, 2) := 0;
    v_ap_is_paid BOOLEAN := false;

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
    SELECT
        pi.id,
        pi.document_number,
        pi.supplier_invoice_number,
        pi.status,
        COALESCE(pi.total_amount, 0)::numeric(15, 2),
        COALESCE(pi.shipping_cost, 0)::numeric(15, 2),
        COALESCE(pi.other_cost, 0)::numeric(15, 2),
        pi.other_cost_notes,
        pi.payment_due_date
    INTO
        v_inv_id,
        v_inv_doc_number,
        v_inv_supplier_number,
        v_inv_status,
        v_inv_total_amount,
        v_inv_shipping_cost,
        v_inv_other_cost,
        v_inv_other_cost_notes,
        v_inv_due_date
    FROM public.purchase_invoices pi
    WHERE pi.purchase_order_id = p_po_id
      AND COALESCE(pi.invoice_type, 'INVOICE') = 'INVOICE'
    ORDER BY pi.created_at ASC
    LIMIT 1
    FOR UPDATE;

    IF v_inv_id IS NOT NULL THEN
        SELECT
            fal.id,
            COALESCE(fal.original_amount, 0)::numeric(15, 2),
            COALESCE(fal.paid_amount, 0)::numeric(15, 2),
            COALESCE(fal.is_paid, false)
        INTO
            v_ap_id,
            v_ap_original_amount,
            v_ap_paid_amount,
            v_ap_is_paid
        FROM public.finance_ap_ledger fal
        WHERE fal.invoice_id = v_inv_id
        LIMIT 1
        FOR UPDATE;

        SELECT COUNT(*)::integer
        INTO v_alloc_count
        FROM public.finance_payment_allocations fpa
        WHERE fpa.invoice_id = v_inv_id;

        IF v_inv_status IN ('PAID', 'PARTIAL')
           OR COALESCE(v_ap_paid_amount, 0) > 0
           OR COALESCE(v_ap_is_paid, false) = true
           OR COALESCE(v_alloc_count, 0) > 0 THEN
            RAISE EXCEPTION 'Faktur PO (%) sudah memiliki pembayaran (status %), sehingga tidak dapat dibatalkan atau diretur.',
                v_inv_doc_number, v_inv_status USING ERRCODE = '22023';
        END IF;
    END IF;

    -- 4. Path A: Simple cancel for ISSUED PO with NO Goods Receipt and NO Invoice
    IF NOT v_has_gr THEN
        IF v_po.status_text = 'ISSUED' AND v_inv_id IS NULL THEN
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

    DROP TABLE IF EXISTS pg_temp.tmp_po_return_lines;

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
                RTRIM(TRIM(TO_CHAR(v_item_row.total_base_return, 'FM999999990.####')), '.'),
                RTRIM(TRIM(TO_CHAR(v_stock_avail, 'FM999999990.####')), '.')
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

    IF v_inv_id IS NOT NULL THEN
        SELECT
            COALESCE(SUM(pr.shipping_deduction), 0)::numeric(15, 2),
            COALESCE(SUM(pr.other_cost_deduction), 0)::numeric(15, 2)
        INTO v_shipping_already_returned, v_other_cost_already_returned
        FROM public.purchase_returns pr
        WHERE pr.po_id = p_po_id
          AND pr.linked_invoice_id = v_inv_id;

        v_remaining_shipping := GREATEST(0, COALESCE(v_inv_shipping_cost, 0) - COALESCE(v_shipping_already_returned, 0));
        v_remaining_other_cost := ROUND((COALESCE(v_inv_other_cost, 0) - COALESCE(v_other_cost_already_returned, 0))::numeric, 2);

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

    IF v_inv_id IS NOT NULL THEN
        IF v_effective_type = 'FULL_RETURN'
           AND ABS(COALESCE(v_ap_original_amount, v_inv_total_amount) - v_total_return_amount) <= 1.00 THEN
            v_total_return_amount := COALESCE(v_ap_original_amount, v_inv_total_amount);
        END IF;

        IF v_total_return_amount > COALESCE(v_ap_original_amount, v_inv_total_amount) THEN
            IF v_remaining_other_cost < 0 THEN
                RAISE EXCEPTION 'Total nilai retur (%) melebihi sisa hutang AP faktur saat ini (%). Sesuaikan nilai penyesuaian potongan biaya lain-lain agar tidak melebihi sisa hutang AP.',
                    v_total_return_amount, COALESCE(v_ap_original_amount, v_inv_total_amount) USING ERRCODE = '22023';
            ELSE
                RAISE EXCEPTION 'Total nilai retur (%) melebihi sisa hutang AP faktur saat ini (%).',
                    v_total_return_amount, COALESCE(v_ap_original_amount, v_inv_total_amount) USING ERRCODE = '22023';
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
        v_inv_id,
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
    IF v_inv_id IS NOT NULL THEN
        v_dn_doc_no := 'DN-' || TO_CHAR(now() AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDD') || '-' ||
                       LPAD(nextval('public.seq_purchase_debit_note_doc')::text, 4, '0');

        v_dn_other_notes := CASE
            WHEN v_other_cost_ded <> 0 THEN COALESCE(NULLIF(TRIM(v_inv_other_cost_notes), ''), 'Penyesuaian Biaya Lain-lain')
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
            'RETUR-' || COALESCE(v_inv_supplier_number, v_inv_doc_number),
            (now() AT TIME ZONE 'Asia/Jakarta')::date,
            v_inv_due_date,
            -v_total_return_amount,
            -v_shipping_ded,
            -v_other_cost_ded,
            v_dn_other_notes,
            'RETURNED',
            v_uid,
            'DEBIT_NOTE',
            v_inv_id,
            v_return_id,
            FORMAT('Faktur Pengurang / Nota Debet untuk Retur %s (Faktur Asli: %s). Alasan: %s',
                v_return_doc_no, v_inv_doc_number, v_reason)
        )
        RETURNING id INTO v_dn_id;

        UPDATE public.purchase_returns
        SET deduction_invoice_id = v_dn_id
        WHERE id = v_return_id;

        v_new_ap_original := ROUND(GREATEST(0, COALESCE(v_ap_original_amount, v_inv_total_amount) - v_total_return_amount)::numeric, 2);

        IF v_effective_type = 'FULL_RETURN' OR v_new_ap_original <= 0 THEN
            UPDATE public.finance_ap_ledger
            SET original_amount = 0,
                is_paid = true
            WHERE invoice_id = v_inv_id;

            UPDATE public.purchase_invoices
            SET status = 'CANCELLED',
                notes = CASE
                    WHEN NULLIF(TRIM(notes), '') IS NULL THEN FORMAT('[DIBATALKAN via %s / %s] %s', v_return_doc_no, v_dn_doc_no, v_reason)
                    ELSE TRIM(notes) || E'\n' || FORMAT('[DIBATALKAN via %s / %s] %s', v_return_doc_no, v_dn_doc_no, v_reason)
                END
            WHERE id = v_inv_id;
        ELSE
            UPDATE public.finance_ap_ledger
            SET original_amount = v_new_ap_original,
                is_paid = false
            WHERE invoice_id = v_inv_id;

            UPDATE public.purchase_invoices
            SET notes = CASE
                WHEN NULLIF(TRIM(notes), '') IS NULL THEN FORMAT('[DIKURANGI %s via %s / %s] %s', v_total_return_amount, v_return_doc_no, v_dn_doc_no, v_reason)
                ELSE TRIM(notes) || E'\n' || FORMAT('[DIKURANGI %s via %s / %s] %s', v_total_return_amount, v_return_doc_no, v_dn_doc_no, v_reason)
            END
            WHERE id = v_inv_id;
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
