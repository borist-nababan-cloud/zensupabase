-- Migration: 20261114114000_fix_view_report_opname_variance_pending_approval.sql
-- Description:
-- 1. Updates view_report_opname_variance to include both PENDING_APPROVAL and COMPLETED stock opname batches
--    so outlet staff (e.g. Role 6) can view and print the 4-signature A4 Stock Opname Variance report immediately
--    after submitting a batch, while still preserving the inter-outlet pricing privacy rule.
-- 2. Ensures SELECT privileges are granted on view_report_opname_variance and view_inventory_report.

CREATE OR REPLACE VIEW public.view_report_opname_variance AS
SELECT 
  soh.id AS header_id,
  soh.document_number,
  soh.opname_date,
  soh.kode_outlet,
  soh.status,
  b.id AS barang_id,
  b.sku,
  b.name AS item_name,
  soi.system_qty,
  soi.actual_qty,
  soi.difference,
  -- Privacy rule: If item belongs to another outlet, use sell_price as unit_cost
  CASE 
    WHEN soh.kode_outlet = b.kode_outlet THEN COALESCE(p.buy_price, 0::numeric)
    ELSE COALESCE(p.sell_price, p.buy_price, 0::numeric)
  END AS unit_cost,
  (soi.difference * CASE 
    WHEN soh.kode_outlet = b.kode_outlet THEN COALESCE(p.buy_price, 0::numeric)
    ELSE COALESCE(p.sell_price, p.buy_price, 0::numeric)
  END)::numeric(15,2) AS variance_value
FROM public.stock_opname_items soi
  JOIN public.stock_opname_headers soh ON soi.header_id = soh.id
  JOIN public.master_barang b ON soi.barang_id = b.id
  LEFT JOIN LATERAL (
    SELECT p.buy_price, p.sell_price
    FROM public.barang_prices p
    WHERE p.barang_id = soi.barang_id
    ORDER BY 
      CASE 
        WHEN p.kode_outlet = soh.kode_outlet THEN 1
        WHEN p.kode_outlet = b.kode_outlet THEN 2
        WHEN p.kode_outlet = '901' THEN 3
        ELSE 4
      END
    LIMIT 1
  ) p ON true
WHERE soh.status = ANY (ARRAY['PENDING_APPROVAL'::text, 'COMPLETED'::text]);

GRANT SELECT ON public.view_report_opname_variance TO anon, authenticated, service_role;
GRANT SELECT ON public.view_inventory_report TO anon, authenticated, service_role;
