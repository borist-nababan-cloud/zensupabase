-- ============================================================================
-- Migration: Add sender_status & recipient_status to view_report_sto_order_items
-- Date: 2026-11-26
-- Author: Zen Family Spa Architect
-- Description:
--   Strictly append `sender_status` and `recipient_status` from `sto_orders`
--   to `public.view_report_sto_order_items` (100% backward-compatible) to
--   power the new "Ringkasan Items STO" report page.
-- ============================================================================

CREATE OR REPLACE VIEW public.view_report_sto_order_items AS
SELECT
    si.id,
    o.created_at::date AS order_date,
    o.document_number,
    o.from_outlet,
    mo_from.name_outlet AS from_outlet_name,
    o.to_outlet,
    mo_to.name_outlet AS to_outlet_name,
    mb.sku,
    mb.name AS item_name,
    si.qty_requested,
    si.price_unit,
    si.subtotal,
    o.sender_status,
    o.recipient_status
FROM public.sto_items si
JOIN public.sto_orders o ON o.id = si.sto_id
LEFT JOIN public.master_barang mb ON mb.id = si.barang_id
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

GRANT SELECT ON public.view_report_sto_order_items TO authenticated, anon, service_role;

NOTIFY pgrst, 'reload schema';
