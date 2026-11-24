-- Migration: Allow view_report_opname_variance to return all COMPLETED stock opname items (including difference = 0)
-- so the frontend toggle "Tampilkan Hanya yang Berselisih" can show either only discrepancies (difference <> 0)
-- or all stock opname items within the selected date range.

CREATE OR REPLACE VIEW "public"."view_report_opname_variance" AS
SELECT
    soh.document_number,
    soh.opname_date,
    soh.kode_outlet,
    b.sku,
    b.name AS item_name,
    soi.system_qty,
    soi.actual_qty,
    soi.difference,
    COALESCE(p.buy_price, 0::numeric) AS unit_cost,
    soi.difference * COALESCE(p.buy_price, 0::numeric) AS variance_value
FROM stock_opname_items soi
JOIN stock_opname_headers soh ON soi.header_id = soh.id
JOIN master_barang b ON soi.barang_id = b.id
LEFT JOIN barang_prices p ON soi.barang_id = p.barang_id AND soh.kode_outlet = p.kode_outlet
WHERE soh.status = 'COMPLETED'::text;
