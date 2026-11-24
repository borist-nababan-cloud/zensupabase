-- ============================================================================
-- Migration: Kartu Stok (Pure Forward Ledger + Anomaly Detector)
-- Date: 2026-11-24
-- Author: Zen Family Spa Architect
-- Description:
--   Creates RPC public.get_stock_card(p_kode_outlet, p_barang_id, p_mode, p_start_date, p_end_date)
--   computing deterministic pure-forward stock movements across all 11 inventory_balance
--   mutation sources (GR, STO In, STO Out, STO Rejected Reversal, Production FG In,
--   Production Ingredient Out, Internal Usage, Internal Return, Shrinkage, B2B Customer Sale,
--   and Stock Opname COMPLETED) with server-side RBAC outlet scoping and discrepancy detection.
-- ============================================================================

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

  -- Roles 6, 7, 14 strictly locked to their own assigned kode_outlet
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

  -- 2. Header Metadata: Product, Unit, Outlet, and Inventory Balance
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

  -- 3. Collect all 11 mutation sources, calculate Pure Forward running balance from 0,
  --    detect Stock Opname point anomalies, and filter according to requested mode.
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

NOTIFY pgrst, 'reload schema';
