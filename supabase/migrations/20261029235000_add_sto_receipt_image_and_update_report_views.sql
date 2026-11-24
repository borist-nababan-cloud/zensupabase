-- ============================================================================
-- Migration: 20261029235000_add_sto_receipt_image_and_update_report_views.sql
-- Purpose:
--   1. Add optional `image_url` column to `public.sto_receipts` (STO Goods Receipt photo
--      from Receiver outlet, completing the 2-photo STO chain of custody).
--   2. Append `receipt_image_url` to `public.view_report_sto_receipt_list` alongside
--      `shipment_image_url`.
--   3. Append `latest_gr_id` and `receipt_image_url` to `public.view_po_details_received`
--      for `ReportGrSupplierPage.tsx`.
-- ============================================================================

BEGIN;

-- 1. Add optional image_url column to sto_receipts
ALTER TABLE public.sto_receipts
ADD COLUMN IF NOT EXISTS image_url TEXT NULL;

-- 2. Append receipt_image_url to view_report_sto_receipt_list
CREATE OR REPLACE VIEW public.view_report_sto_receipt_list AS
SELECT
    r.id,
    r.received_at,
    r.document_number,
    o.document_number AS order_number,
    o.from_outlet,
    mo_from.name_outlet AS from_outlet_name,
    o.to_outlet,
    mo_to.name_outlet AS to_outlet_name,
    COALESCE(o.grand_total, 0::numeric) AS grand_total,
    r.sto_id,
    (
        SELECT ss.image_url
        FROM public.sto_shipments ss
        WHERE ss.sto_id = o.id
          AND ss.image_url IS NOT NULL
        ORDER BY ss.shipped_at DESC
        LIMIT 1
    ) AS shipment_image_url,
    r.image_url AS receipt_image_url
FROM public.sto_receipts r
JOIN public.sto_orders o ON o.id = r.sto_id
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

-- 3. Append latest_gr_id and receipt_image_url to view_po_details_received
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
        SELECT gr.image_url
        FROM public.goods_receipts gr
        WHERE gr.po_id = po.id
          AND gr.image_url IS NOT NULL
        ORDER BY gr.received_at DESC
        LIMIT 1
    ) AS receipt_image_url
FROM public.purchase_order_items poi
JOIN public.master_barang b ON poi.barang_id = b.id
JOIN public.purchase_orders po ON poi.po_id = po.id;

COMMIT;

