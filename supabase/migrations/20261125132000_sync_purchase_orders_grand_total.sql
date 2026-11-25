-- ============================================================================
-- Migration: Sync purchase_orders.grand_total with total_amount + tax_amount
-- Date: 2026-11-25
-- Author: Zen Family Spa Architect
-- Purpose:
--   1. Backfill existing purchase_orders rows where grand_total is 0/NULL while
--      total_amount or tax_amount is non-zero.
--   2. Add BEFORE INSERT OR UPDATE trigger `trigger_sync_po_grand_total` on
--      `public.purchase_orders` so grand_total never stays at 0 when total_amount changes.
--   3. Add defensive COALESCE fallback in `public.view_report_purchase_orders`.
-- ============================================================================

-- 1. Backfill existing POs
UPDATE public.purchase_orders
SET grand_total = ROUND((COALESCE(total_amount, 0) + COALESCE(tax_amount, 0))::numeric, 2)
WHERE COALESCE(grand_total, 0) = 0
  AND (COALESCE(total_amount, 0) <> 0 OR COALESCE(tax_amount, 0) <> 0);

-- 2. Trigger function & trigger on purchase_orders
CREATE OR REPLACE FUNCTION public.sync_purchase_order_grand_total()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_computed_total NUMERIC(15, 2);
BEGIN
    v_computed_total := ROUND((COALESCE(NEW.total_amount, 0) + COALESCE(NEW.tax_amount, 0))::numeric, 2);

    IF TG_OP = 'INSERT' THEN
        IF NEW.grand_total IS NULL OR (NEW.grand_total = 0 AND v_computed_total <> 0) THEN
            NEW.grand_total := v_computed_total;
        END IF;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.total_amount IS DISTINCT FROM OLD.total_amount
           OR NEW.tax_amount IS DISTINCT FROM OLD.tax_amount THEN
            IF NEW.grand_total IS NOT DISTINCT FROM OLD.grand_total OR COALESCE(NEW.grand_total, 0) = 0 THEN
                NEW.grand_total := v_computed_total;
            END IF;
        ELSIF NEW.grand_total IS NULL OR (NEW.grand_total = 0 AND v_computed_total <> 0) THEN
            NEW.grand_total := v_computed_total;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_sync_po_grand_total ON public.purchase_orders;
CREATE TRIGGER trigger_sync_po_grand_total
    BEFORE INSERT OR UPDATE ON public.purchase_orders
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_purchase_order_grand_total();

-- 3. Defensive fallback on view_report_purchase_orders (preserving exact column order & types)
CREATE OR REPLACE VIEW public.view_report_purchase_orders AS
SELECT
    po.id AS po_id,
    po.document_number,
    po.created_at AS po_date,
    po.expected_delivery_date,
    po.status,
    COALESCE(NULLIF(po.grand_total, 0::numeric), COALESCE(po.total_amount, 0::numeric) + COALESCE(po.tax_amount, 0::numeric))::numeric(15, 2) AS grand_total,
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

NOTIFY pgrst, 'reload schema';
