-- ============================================================================
-- Migration: Menu POS > GC List RPC & Performance Indexes + Role 20 (IT-SUPPORT)
-- Date: 2026-11-25
-- Author: Zen Family Spa Architect
-- Description:
--   1. Ensures Role ID 20 ('IT-SUPPORT') is registered in public.role_user.
--   2. Creates B-Tree indexes on public.ot_pos_gc_transaction (buy_at, used_at,
--      expired_date, has_used, gc_barcode) for sub-second queries across >14.5k rows.
--   3. Creates SECURITY DEFINER RPC public.get_pos_gc_list(...) with strict
--      RBAC validation (Roles 5, 6, 8, 13, 14, 19, 20), outlet scoping
--      (Roles 6, 14, 19 locked to own kode_outlet on buy OR used), server-side
--      pagination, full filtered summary (count & value), and global search across
--      gc_number / gc_barcode / qrcode (bypassing date filter when searching).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Register Role ID 20 ('IT-SUPPORT') in public.role_user
-- ----------------------------------------------------------------------------
INSERT INTO public.role_user (id, role_name)
VALUES (20, 'IT-SUPPORT')
ON CONFLICT (id) DO UPDATE SET
  role_name = EXCLUDED.role_name;

DO $$
DECLARE
  v_seq TEXT;
BEGIN
  v_seq := pg_get_serial_sequence('public.role_user', 'id');
  IF v_seq IS NOT NULL THEN
    PERFORM setval(v_seq, GREATEST((SELECT COALESCE(MAX(id), 1) FROM public.role_user), 20), true);
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2. Performance Indexes on public.ot_pos_gc_transaction
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_buy_at
  ON public.ot_pos_gc_transaction (buy_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_used_at
  ON public.ot_pos_gc_transaction (used_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_expired_date
  ON public.ot_pos_gc_transaction (expired_date);

CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_has_used
  ON public.ot_pos_gc_transaction (has_used);

CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_gc_barcode
  ON public.ot_pos_gc_transaction (gc_barcode);

-- ----------------------------------------------------------------------------
-- 3. Centralized Server-Side RPC: public.get_pos_gc_list(...)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pos_gc_list(
  p_date_field TEXT DEFAULT 'BUY_AT',
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL,
  p_outlet_buy TEXT DEFAULT 'ALL',
  p_outlet_used TEXT DEFAULT 'ALL',
  p_outlet_scope TEXT DEFAULT 'ALL_OWN',
  p_has_used TEXT DEFAULT 'ALL',
  p_expired_filter TEXT DEFAULT 'ALL',
  p_is_active TEXT DEFAULT 'ALL',
  p_cross_outlet TEXT DEFAULT 'ALL',
  p_search TEXT DEFAULT NULL,
  p_page INTEGER DEFAULT 1,
  p_page_size INTEGER DEFAULT 50
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
  v_is_locked BOOLEAN := false;
  v_date_field TEXT := CASE
    WHEN UPPER(COALESCE(p_date_field, 'BUY_AT')) = 'USED_AT' THEN 'USED_AT'
    ELSE 'BUY_AT'
  END;
  v_outlet_buy TEXT := NULLIF(TRIM(COALESCE(p_outlet_buy, 'ALL')), '');
  v_outlet_used TEXT := NULLIF(TRIM(COALESCE(p_outlet_used, 'ALL')), '');
  v_outlet_scope TEXT := UPPER(COALESCE(NULLIF(TRIM(p_outlet_scope), ''), 'ALL_OWN'));
  v_has_used TEXT := UPPER(COALESCE(NULLIF(TRIM(p_has_used), ''), 'ALL'));
  v_expired_filter TEXT := UPPER(COALESCE(NULLIF(TRIM(p_expired_filter), ''), 'ALL'));
  v_is_active TEXT := UPPER(COALESCE(NULLIF(TRIM(p_is_active), ''), 'ALL'));
  v_cross_outlet TEXT := UPPER(COALESCE(NULLIF(TRIM(p_cross_outlet), ''), 'ALL'));
  v_search TEXT := NULLIF(TRIM(COALESCE(p_search, '')), '');
  v_today_wib DATE := (now() AT TIME ZONE 'Asia/Jakarta')::date;
  v_page INTEGER := GREATEST(COALESCE(p_page, 1), 1);
  v_page_size INTEGER := LEAST(GREATEST(COALESCE(p_page_size, 50), 1), 2000);
  v_offset INTEGER;

  v_summary JSONB;
  v_total_count INTEGER := 0;
  v_rows JSONB := '[]'::jsonb;
BEGIN
  -- 1. Auth & RBAC Validation (Roles 5, 6, 8, 13, 14, 19, 20 ONLY)
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Autentikasi diperlukan.' USING ERRCODE = '42501';
  END IF;

  SELECT user_role, NULLIF(TRIM(kode_outlet), '')
  INTO v_user_role, v_user_outlet
  FROM public.users_profile
  WHERE uid = v_uid;

  IF v_user_role IS NULL OR v_user_role NOT IN (5, 6, 8, 13, 14, 19, 20) THEN
    RAISE EXCEPTION 'Akses ditolak. Role Anda tidak berwenang membuka menu GC List.' USING ERRCODE = '42501';
  END IF;

  v_is_locked := v_user_role IN (6, 14, 19);
  IF v_is_locked AND v_user_outlet IS NULL THEN
    RAISE EXCEPTION 'Kode outlet wajib terdaftar pada profil pengguna Anda.' USING ERRCODE = '22023';
  END IF;

  IF v_search IS NULL AND p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_start_date > p_end_date THEN
    RAISE EXCEPTION 'Tanggal mulai tidak boleh lebih besar dari tanggal akhir.' USING ERRCODE = '22023';
  END IF;

  v_offset := (v_page - 1) * v_page_size;

  WITH filtered AS (
    SELECT
      t.uid,
      t.user_uid,
      t.gc_number,
      t.gc_barcode,
      t.pack_number,
      t.nama_gc,
      COALESCE(t.value, 0)::numeric(15, 2) AS value,
      t.buy_at,
      t.used_at,
      COALESCE(t.has_used, false) AS has_used,
      t.id_payment_buy,
      t.id_payment_used,
      t.kode_outlet_buy,
      t.kode_outlet_used,
      t.created_at,
      t.expired_date,
      COALESCE(t.is_active, true) AS is_active,
      t.qrcode,
      (
        COALESCE(t.has_used, false) = false
        AND t.expired_date IS NOT NULL
        AND t.expired_date < v_today_wib
      ) AS is_expired
    FROM public.ot_pos_gc_transaction t
    WHERE
      -- RBAC Outlet Scope
      (
        CASE
          WHEN v_is_locked THEN
            CASE
              WHEN v_outlet_scope = 'BUY_OWN' THEN t.kode_outlet_buy = v_user_outlet
              WHEN v_outlet_scope = 'USED_OWN' THEN t.kode_outlet_used = v_user_outlet
              ELSE (t.kode_outlet_buy = v_user_outlet OR t.kode_outlet_used = v_user_outlet)
            END
          ELSE
            (
              (v_outlet_buy IS NULL OR UPPER(v_outlet_buy) = 'ALL' OR t.kode_outlet_buy = v_outlet_buy)
              AND
              (v_outlet_used IS NULL OR UPPER(v_outlet_used) = 'ALL' OR t.kode_outlet_used = v_outlet_used)
            )
        END
      )
      -- Search (bypasses date filter when active) vs Date Filter (WIB)
      AND (
        CASE
          WHEN v_search IS NOT NULL THEN
            (
              COALESCE(t.gc_number, '') ILIKE '%' || v_search || '%'
              OR COALESCE(t.gc_barcode, '') ILIKE '%' || v_search || '%'
              OR COALESCE(t.qrcode, '') ILIKE '%' || v_search || '%'
            )
          ELSE
            CASE
              WHEN v_date_field = 'USED_AT' THEN
                t.used_at IS NOT NULL
                AND (p_start_date IS NULL OR (t.used_at AT TIME ZONE 'Asia/Jakarta')::date >= p_start_date)
                AND (p_end_date IS NULL OR (t.used_at AT TIME ZONE 'Asia/Jakarta')::date <= p_end_date)
              ELSE
                (
                  (p_start_date IS NULL AND p_end_date IS NULL)
                  OR (
                    t.buy_at IS NOT NULL
                    AND (p_start_date IS NULL OR (t.buy_at AT TIME ZONE 'Asia/Jakarta')::date >= p_start_date)
                    AND (p_end_date IS NULL OR (t.buy_at AT TIME ZONE 'Asia/Jakarta')::date <= p_end_date)
                  )
                )
            END
        END
      )
      -- Status has_used
      AND (
        v_has_used = 'ALL'
        OR (v_has_used = 'TRUE' AND COALESCE(t.has_used, false) = true)
        OR (v_has_used = 'FALSE' AND COALESCE(t.has_used, false) = false)
      )
      -- Status Expired
      AND (
        v_expired_filter = 'ALL'
        OR (
          v_expired_filter = 'EXPIRED'
          AND COALESCE(t.has_used, false) = false
          AND t.expired_date IS NOT NULL
          AND t.expired_date < v_today_wib
        )
        OR (
          v_expired_filter = 'VALID'
          AND COALESCE(t.has_used, false) = false
          AND (t.expired_date IS NULL OR t.expired_date >= v_today_wib)
        )
        OR (
          v_expired_filter = 'EXPIRING_SOON'
          AND COALESCE(t.has_used, false) = false
          AND t.expired_date IS NOT NULL
          AND t.expired_date >= v_today_wib
          AND t.expired_date <= (v_today_wib + 30)
        )
      )
      -- Status is_active
      AND (
        v_is_active = 'ALL'
        OR (v_is_active = 'TRUE' AND COALESCE(t.is_active, true) = true)
        OR (v_is_active = 'FALSE' AND COALESCE(t.is_active, true) = false)
      )
      -- Cross-Outlet Filter
      AND (
        v_cross_outlet <> 'CROSS_ONLY'
        OR (
          COALESCE(t.has_used, false) = true
          AND NULLIF(TRIM(t.kode_outlet_buy), '') IS NOT NULL
          AND NULLIF(TRIM(t.kode_outlet_used), '') IS NOT NULL
          AND t.kode_outlet_buy <> t.kode_outlet_used
        )
      )
  ),
  agg AS (
    SELECT
      COUNT(*)::integer AS total_count,
      COALESCE(SUM(f.value), 0)::numeric(15, 2) AS total_value,
      COUNT(*) FILTER (
        WHERE f.has_used = false AND (f.expired_date IS NULL OR f.expired_date >= v_today_wib)
      )::integer AS unused_valid_count,
      COALESCE(SUM(f.value) FILTER (
        WHERE f.has_used = false AND (f.expired_date IS NULL OR f.expired_date >= v_today_wib)
      ), 0)::numeric(15, 2) AS unused_valid_value,
      COUNT(*) FILTER (WHERE f.has_used = true)::integer AS used_count,
      COALESCE(SUM(f.value) FILTER (WHERE f.has_used = true), 0)::numeric(15, 2) AS used_value,
      COUNT(*) FILTER (WHERE f.is_expired = true)::integer AS expired_count,
      COALESCE(SUM(f.value) FILTER (WHERE f.is_expired = true), 0)::numeric(15, 2) AS expired_value,
      COUNT(*) FILTER (
        WHERE f.has_used = true
          AND NULLIF(TRIM(f.kode_outlet_buy), '') IS NOT NULL
          AND NULLIF(TRIM(f.kode_outlet_used), '') IS NOT NULL
          AND f.kode_outlet_buy <> f.kode_outlet_used
      )::integer AS cross_outlet_count,
      COALESCE(SUM(f.value) FILTER (
        WHERE f.has_used = true
          AND NULLIF(TRIM(f.kode_outlet_buy), '') IS NOT NULL
          AND NULLIF(TRIM(f.kode_outlet_used), '') IS NOT NULL
          AND f.kode_outlet_buy <> f.kode_outlet_used
      ), 0)::numeric(15, 2) AS cross_outlet_value
    FROM filtered f
  ),
  paged AS (
    SELECT
      f.*,
      mo_buy.name_outlet AS outlet_buy_name,
      mo_used.name_outlet AS outlet_used_name
    FROM filtered f
    LEFT JOIN public.master_outlet mo_buy ON mo_buy.kode_outlet = f.kode_outlet_buy
    LEFT JOIN public.master_outlet mo_used ON mo_used.kode_outlet = f.kode_outlet_used
    ORDER BY
      CASE WHEN v_date_field = 'USED_AT' THEN f.used_at ELSE f.buy_at END DESC NULLS LAST,
      f.created_at DESC NULLS LAST,
      f.gc_number ASC
    LIMIT v_page_size
    OFFSET v_offset
  )
  SELECT
    a.total_count,
    jsonb_build_object(
      'total_count', a.total_count,
      'total_value', a.total_value,
      'unused_valid_count', a.unused_valid_count,
      'unused_valid_value', a.unused_valid_value,
      'used_count', a.used_count,
      'used_value', a.used_value,
      'expired_count', a.expired_count,
      'expired_value', a.expired_value,
      'cross_outlet_count', a.cross_outlet_count,
      'cross_outlet_value', a.cross_outlet_value
    ),
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'uid', p.uid,
          'user_uid', p.user_uid,
          'gc_number', p.gc_number,
          'gc_barcode', p.gc_barcode,
          'pack_number', p.pack_number,
          'nama_gc', p.nama_gc,
          'value', p.value,
          'buy_at', p.buy_at,
          'used_at', p.used_at,
          'has_used', p.has_used,
          'id_payment_buy', p.id_payment_buy,
          'id_payment_used', p.id_payment_used,
          'kode_outlet_buy', p.kode_outlet_buy,
          'outlet_buy_name', p.outlet_buy_name,
          'kode_outlet_used', p.kode_outlet_used,
          'outlet_used_name', p.outlet_used_name,
          'expired_date', p.expired_date,
          'is_active', p.is_active,
          'qrcode', p.qrcode,
          'created_at', p.created_at,
          'is_expired', p.is_expired
        )
        ORDER BY
          CASE WHEN v_date_field = 'USED_AT' THEN p.used_at ELSE p.buy_at END DESC NULLS LAST,
          p.created_at DESC NULLS LAST,
          p.gc_number ASC
      )
      FROM paged p
    ), '[]'::jsonb)
  INTO v_total_count, v_summary, v_rows
  FROM agg a;

  RETURN jsonb_build_object(
    'summary', COALESCE(v_summary, jsonb_build_object(
      'total_count', 0,
      'total_value', 0,
      'unused_valid_count', 0,
      'unused_valid_value', 0,
      'used_count', 0,
      'used_value', 0,
      'expired_count', 0,
      'expired_value', 0,
      'cross_outlet_count', 0,
      'cross_outlet_value', 0
    )),
    'pagination', jsonb_build_object(
      'page', v_page,
      'page_size', v_page_size,
      'total_count', COALESCE(v_total_count, 0),
      'total_pages', GREATEST(CEIL(COALESCE(v_total_count, 0)::numeric / v_page_size)::integer, 1)
    ),
    'search_bypassed_date', (v_search IS NOT NULL),
    'is_outlet_locked', v_is_locked,
    'locked_outlet', CASE WHEN v_is_locked THEN v_user_outlet ELSE NULL END,
    'rows', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_gc_list(TEXT, DATE, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pos_gc_list(TEXT, DATE, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) TO authenticated, service_role;

-- Reload PostgREST schema cache
NOTIFY pgrst, 'reload schema';
