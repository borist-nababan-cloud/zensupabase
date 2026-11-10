-- Migration: 20261110140000_stock_opname_approval_and_pricing_privacy.sql
-- Description:
-- 1. Updates view_inventory_report to apply privacy pricing rule:
--    If item belongs to another outlet (e.g. STO), load sell_price as buy_price and sell_price.
-- 2. Updates view_report_opname_variance to apply privacy pricing rule for unit_cost and variance_value.
-- 3. Adds approve_stock_opname and reject_stock_opname RPC functions for Role 5, 8, 14 approval flow.

-- ==============================================================================
-- 1. UPDATE view_inventory_report
-- ==============================================================================
CREATE OR REPLACE VIEW public.view_inventory_report AS
SELECT 
  inv.kode_outlet,
  o.name_outlet,
  inv.barang_id,
  m.sku,
  m.name AS item_name,
  m.image1_url,
  COALESCE(u.base_uom, 'PCS'::text) AS base_uom,
  COALESCE(u.purchase_uom, 'PCS'::text) AS purchase_uom,
  inv.qty_on_hand,
  -- Privacy rule: If item belongs to another outlet, use sell_price as buy_price to hide confidential buy_price
  CASE 
    WHEN inv.kode_outlet = m.kode_outlet THEN COALESCE(p.buy_price, 0::numeric)
    ELSE COALESCE(p.sell_price, p.buy_price, 0::numeric)
  END AS buy_price,
  COALESCE(p.sell_price, 0::numeric) AS sell_price,
  (inv.qty_on_hand * CASE 
    WHEN inv.kode_outlet = m.kode_outlet THEN COALESCE(p.buy_price, 0::numeric)
    ELSE COALESCE(p.sell_price, p.buy_price, 0::numeric)
  END)::numeric(15,2) AS valuation_buy_total,
  (inv.qty_on_hand * COALESCE(p.sell_price, 0::numeric))::numeric(15,2) AS valuation_sell_total
FROM public.inventory_balance inv
  JOIN public.master_outlet o ON inv.kode_outlet = o.kode_outlet
  JOIN public.master_barang m ON inv.barang_id = m.id
  LEFT JOIN LATERAL (
    SELECT p.buy_price, p.sell_price, p.kode_outlet AS price_outlet
    FROM public.barang_prices p
    WHERE p.barang_id = inv.barang_id
    ORDER BY 
      CASE 
        WHEN p.kode_outlet = inv.kode_outlet THEN 1
        WHEN p.kode_outlet = m.kode_outlet THEN 2
        WHEN p.kode_outlet = '901' THEN 3
        ELSE 4
      END
    LIMIT 1
  ) p ON true
  LEFT JOIN LATERAL (
    SELECT u.base_uom, u.purchase_uom, u.kode_outlet AS unit_outlet
    FROM public.barang_units u
    WHERE u.barang_id = inv.barang_id
    ORDER BY 
      CASE 
        WHEN u.kode_outlet = inv.kode_outlet THEN 1
        WHEN u.kode_outlet = m.kode_outlet THEN 2
        WHEN u.kode_outlet = '901' THEN 3
        ELSE 4
      END
    LIMIT 1
  ) u ON true;

-- ==============================================================================
-- 2. UPDATE view_report_opname_variance
-- ==============================================================================
DROP VIEW IF EXISTS public.view_report_opname_variance;

CREATE VIEW public.view_report_opname_variance AS
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
WHERE soh.status = 'COMPLETED'::text;

-- ==============================================================================
-- 3. RPC FUNCTIONS FOR OPNAME APPROVAL & REJECTION
-- ==============================================================================

-- Function to approve stock opname batch and apply stock to inventory_balance
CREATE OR REPLACE FUNCTION public.approve_stock_opname(
  p_header_id uuid,
  p_user_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_header record;
  v_item record;
  v_count integer := 0;
BEGIN
  -- 1. Check header
  SELECT * INTO v_header
  FROM public.stock_opname_headers
  WHERE id = p_header_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Dokumen Stock Opname tidak ditemukan');
  END IF;

  IF v_header.status = 'COMPLETED' THEN
    RETURN json_build_object('success', false, 'error', 'Dokumen Stock Opname sudah pernah disetujui sebelumnya');
  END IF;

  IF v_header.status = 'REJECTED' THEN
    RETURN json_build_object('success', false, 'error', 'Dokumen Stock Opname yang ditolak tidak dapat disetujui');
  END IF;

  -- 2. Update stock_opname_headers to COMPLETED
  UPDATE public.stock_opname_headers
  SET 
    status = 'COMPLETED',
    notes = COALESCE(notes, '') || ' [Disetujui oleh: ' || p_user_id::text || ' pada ' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ']'
  WHERE id = p_header_id;

  -- 3. Update inventory_balance for each item in the batch
  FOR v_item IN 
    SELECT barang_id, actual_qty 
    FROM public.stock_opname_items 
    WHERE header_id = p_header_id
  LOOP
    INSERT INTO public.inventory_balance (
      barang_id, kode_outlet, qty_on_hand, opening_balance, date_ob, last_movement_at
    )
    VALUES (
      v_item.barang_id, v_header.kode_outlet, v_item.actual_qty, v_item.actual_qty, CURRENT_DATE, now()
    )
    ON CONFLICT (barang_id, kode_outlet) DO UPDATE SET
      qty_on_hand = EXCLUDED.qty_on_hand,
      opening_balance = EXCLUDED.opening_balance,
      date_ob = EXCLUDED.date_ob,
      last_movement_at = EXCLUDED.last_movement_at;

    v_count := v_count + 1;
  END LOOP;

  RETURN json_build_object(
    'success', true, 
    'message', 'Stock opname berhasil disetujui dan stok inventaris telah diperbarui',
    'items_updated', v_count
  );
END;
$$;

-- Function to reject stock opname batch
CREATE OR REPLACE FUNCTION public.reject_stock_opname(
  p_header_id uuid,
  p_user_id uuid,
  p_reason text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_header record;
BEGIN
  SELECT * INTO v_header
  FROM public.stock_opname_headers
  WHERE id = p_header_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Dokumen Stock Opname tidak ditemukan');
  END IF;

  IF v_header.status = 'COMPLETED' THEN
    RETURN json_build_object('success', false, 'error', 'Dokumen Stock Opname yang sudah disetujui tidak dapat ditolak');
  END IF;

  UPDATE public.stock_opname_headers
  SET 
    status = 'REJECTED',
    notes = COALESCE(notes, '') || ' [Ditolak oleh ' || p_user_id::text || ' alasan: ' || COALESCE(p_reason, '-') || ' pada ' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ']'
  WHERE id = p_header_id;

  RETURN json_build_object(
    'success', true, 
    'message', 'Pengajuan Stock Opname telah ditolak'
  );
END;
$$;

-- Grant permissions to authenticated users
GRANT EXECUTE ON FUNCTION public.approve_stock_opname(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_stock_opname(uuid, uuid, text) TO authenticated;
