-- ============================================================================
-- Migration: GC List Pure Global Search & One-Time Expiry Extension (+1d Buffer)
-- Date: 2026-11-27
-- Author: Zen Family Spa Architect
-- Description:
--   1. Adds original_buy_at column on public.ot_pos_gc_transaction to preserve
--      the true purchase timestamp whenever buy_at is shifted for ZenSystem
--      Desktop 120-day redemption compatibility.
--   2. Creates public.ot_pos_gc_expiry_logs with UNIQUE (gc_uid) so each GC
--      can be extended at most ONCE (1x only), with mandatory notes >= 10 chars.
--   3. Updates public.get_pos_gc_list(...) so when p_search is non-empty,
--      ALL other filters (date, outlet buy/used, outlet lock, has_used,
--      expired, is_active, cross_outlet) are bypassed to search the entire
--      ot_pos_gc_transaction table; also returns original_buy_at,
--      has_been_extended, and extension_log.
--   4. Creates SECURITY DEFINER RPC public.extend_pos_gc_expiry(...) restricted
--      strictly to Roles 5, 8, 13, supporting options 1, 7, 14 days + 1 day
--      cancellation allowance (effective +2, +8, +15 days), 1x only, updating
--      both expired_date and buy_at (new_expired_date - 120 days @ 12:00 WIB).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Preserve original_buy_at on public.ot_pos_gc_transaction
-- ----------------------------------------------------------------------------
ALTER TABLE public.ot_pos_gc_transaction
  ADD COLUMN IF NOT EXISTS original_buy_at TIMESTAMPTZ;

-- ----------------------------------------------------------------------------
-- 2. Audit Log Table: public.ot_pos_gc_expiry_logs (STRICTLY 1x PER GC)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ot_pos_gc_expiry_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gc_uid UUID NOT NULL REFERENCES public.ot_pos_gc_transaction(uid) ON DELETE CASCADE,
  gc_number TEXT,
  extension_days INTEGER NOT NULL CHECK (extension_days IN (1, 7, 14)),
  allowance_days INTEGER NOT NULL DEFAULT 1 CHECK (allowance_days >= 0),
  total_added_days INTEGER NOT NULL CHECK (total_added_days > 0),
  old_buy_at TIMESTAMPTZ,
  new_buy_at TIMESTAMPTZ NOT NULL,
  old_expired_date DATE,
  new_expired_date DATE NOT NULL,
  notes TEXT NOT NULL CHECK (length(trim(notes)) >= 10),
  extended_by UUID NOT NULL,
  extended_by_name TEXT,
  extended_by_role INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_ot_pos_gc_expiry_logs_gc_uid UNIQUE (gc_uid)
);

CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_expiry_logs_created_at
  ON public.ot_pos_gc_expiry_logs (created_at DESC);

ALTER TABLE public.ot_pos_gc_expiry_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow authorized roles to read gc expiry logs" ON public.ot_pos_gc_expiry_logs;
CREATE POLICY "Allow authorized roles to read gc expiry logs"
  ON public.ot_pos_gc_expiry_logs
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.users_profile up
      WHERE up.uid = auth.uid()
        AND up.user_role IN (5, 6, 8, 13, 14, 19, 20)
    )
  );

REVOKE ALL ON TABLE public.ot_pos_gc_expiry_logs FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.ot_pos_gc_expiry_logs TO authenticated;
GRANT ALL ON TABLE public.ot_pos_gc_expiry_logs TO service_role;

-- ----------------------------------------------------------------------------
-- 3. Update RPC: public.get_pos_gc_list(...) — Pure Global Search + Audit Info
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
      t.original_buy_at,
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
      CASE
        -- PURE GLOBAL SEARCH: bypass ALL filters when search query is present
        WHEN v_search IS NOT NULL THEN
          (
            COALESCE(t.gc_number, '') ILIKE '%' || v_search || '%'
            OR COALESCE(t.gc_barcode, '') ILIKE '%' || v_search || '%'
            OR COALESCE(t.qrcode, '') ILIKE '%' || v_search || '%'
          )
        ELSE
          (
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
            -- Date Filter (WIB)
            AND (
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
          )
      END
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
      mo_used.name_outlet AS outlet_used_name,
      (ext.id IS NOT NULL) AS has_been_extended,
      CASE
        WHEN ext.id IS NOT NULL THEN
          jsonb_build_object(
            'id', ext.id,
            'extension_days', ext.extension_days,
            'allowance_days', ext.allowance_days,
            'total_added_days', ext.total_added_days,
            'old_buy_at', ext.old_buy_at,
            'new_buy_at', ext.new_buy_at,
            'old_expired_date', ext.old_expired_date,
            'new_expired_date', ext.new_expired_date,
            'notes', ext.notes,
            'extended_by', ext.extended_by,
            'extended_by_name', ext.extended_by_name,
            'extended_by_role', ext.extended_by_role,
            'created_at', ext.created_at
          )
        ELSE NULL
      END AS extension_log
    FROM filtered f
    LEFT JOIN public.master_outlet mo_buy ON mo_buy.kode_outlet = f.kode_outlet_buy
    LEFT JOIN public.master_outlet mo_used ON mo_used.kode_outlet = f.kode_outlet_used
    LEFT JOIN public.ot_pos_gc_expiry_logs ext ON ext.gc_uid = f.uid
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
          'original_buy_at', p.original_buy_at,
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
          'is_expired', p.is_expired,
          'has_been_extended', p.has_been_extended,
          'extension_log', p.extension_log
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
    'search_bypassed_all_filters', (v_search IS NOT NULL),
    'is_outlet_locked', v_is_locked,
    'locked_outlet', CASE WHEN v_is_locked THEN v_user_outlet ELSE NULL END,
    'rows', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_gc_list(TEXT, DATE, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pos_gc_list(TEXT, DATE, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. RPC: public.extend_pos_gc_expiry(...) — Strictly Roles 5, 8, 13 & 1x Only
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.extend_pos_gc_expiry(
  p_gc_uid UUID,
  p_extension_days INTEGER,
  p_notes TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_user_role INTEGER;
  v_user_name TEXT;
  v_clean_notes TEXT := TRIM(COALESCE(p_notes, ''));
  v_today_wib DATE := (now() AT TIME ZONE 'Asia/Jakarta')::date;
  v_allowance_days CONSTANT INTEGER := 1;
  v_total_added_days INTEGER;
  v_old_expired_date DATE;
  v_base_date DATE;
  v_new_expired_date DATE;
  v_new_buy_at TIMESTAMPTZ;
  v_original_buy_at TIMESTAMPTZ;

  v_gc RECORD;
  v_log RECORD;
BEGIN
  -- 1. Auth & Strict RBAC Check (ONLY Roles 5, 8, 13)
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Autentikasi diperlukan.' USING ERRCODE = '42501';
  END IF;

  SELECT
    user_role,
    COALESCE(NULLIF(TRIM(full_name), ''), NULLIF(TRIM(email), ''), v_uid::text)
  INTO v_user_role, v_user_name
  FROM public.users_profile
  WHERE uid = v_uid;

  IF v_user_role IS NULL OR v_user_role NOT IN (5, 8, 13) THEN
    RAISE EXCEPTION 'Akses ditolak. Hanya Role 5, 8, dan 13 yang berwenang menambah masa kadaluarsa GC.'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Input Validation
  IF p_gc_uid IS NULL THEN
    RAISE EXCEPTION 'UID Gift Certificate wajib diisi.' USING ERRCODE = '22023';
  END IF;

  IF p_extension_days IS NULL OR p_extension_days NOT IN (1, 7, 14) THEN
    RAISE EXCEPTION 'Pilihan perpanjangan tidak valid. Pilih 1 hari, 1 minggu (7 hari), atau 2 minggu (14 hari).'
      USING ERRCODE = '22023';
  END IF;

  IF length(v_clean_notes) < 10 THEN
    RAISE EXCEPTION 'Catatan / keterangan wajib diisi minimal 10 karakter.'
      USING ERRCODE = '22023';
  END IF;

  -- 3. Row-level Lock & Business Guards
  SELECT
    uid,
    gc_number,
    buy_at,
    original_buy_at,
    expired_date,
    COALESCE(has_used, false) AS has_used,
    COALESCE(is_active, true) AS is_active
  INTO v_gc
  FROM public.ot_pos_gc_transaction
  WHERE uid = p_gc_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Data Gift Certificate tidak ditemukan.' USING ERRCODE = 'P0002';
  END IF;

  IF v_gc.is_active = false THEN
    RAISE EXCEPTION 'GC berstatus Non-Aktif tidak dapat diperpanjang masa kadaluarsanya.'
      USING ERRCODE = '22023';
  END IF;

  IF v_gc.has_used = true THEN
    RAISE EXCEPTION 'GC yang sudah dipakai tidak dapat diperpanjang masa kadaluarsanya.'
      USING ERRCODE = '22023';
  END IF;

  -- 4. Strictly One-Time Extension Check
  IF EXISTS (SELECT 1 FROM public.ot_pos_gc_expiry_logs WHERE gc_uid = p_gc_uid) THEN
    RAISE EXCEPTION 'Masa kadaluarsa GC ini sudah pernah diperpanjang sebelumnya (maksimal 1 kali perpanjangan).'
      USING ERRCODE = '22023';
  END IF;

  -- 5. Smart Base Date Calculation + 1-Day Allowance + ZenSystem 120-Day Sync
  v_old_expired_date := COALESCE(
    v_gc.expired_date,
    CASE
      WHEN v_gc.buy_at IS NOT NULL THEN ((v_gc.buy_at AT TIME ZONE 'Asia/Jakarta')::date + 120)
      ELSE v_today_wib
    END
  );

  v_base_date := GREATEST(v_old_expired_date, v_today_wib);
  v_total_added_days := p_extension_days + v_allowance_days;
  v_new_expired_date := v_base_date + v_total_added_days;

  -- Set to 12:00:00+07:00 (= 05:00:00 UTC) so both UTC YYYY-MM-DD (Delphi Copy(sBuyAt,1,10))
  -- and Asia/Jakarta WIB date are 100% identical with zero timezone drift.
  v_new_buy_at := (((v_new_expired_date - 120)::text || ' 12:00:00+07:00')::timestamptz);
  v_original_buy_at := COALESCE(v_gc.original_buy_at, v_gc.buy_at);

  -- 6. Atomic Update + Audit Log Insert
  UPDATE public.ot_pos_gc_transaction
  SET
    original_buy_at = v_original_buy_at,
    buy_at = v_new_buy_at,
    expired_date = v_new_expired_date
  WHERE uid = p_gc_uid;

  INSERT INTO public.ot_pos_gc_expiry_logs (
    gc_uid,
    gc_number,
    extension_days,
    allowance_days,
    total_added_days,
    old_buy_at,
    new_buy_at,
    old_expired_date,
    new_expired_date,
    notes,
    extended_by,
    extended_by_name,
    extended_by_role
  )
  VALUES (
    p_gc_uid,
    v_gc.gc_number,
    p_extension_days,
    v_allowance_days,
    v_total_added_days,
    v_gc.buy_at,
    v_new_buy_at,
    v_old_expired_date,
    v_new_expired_date,
    v_clean_notes,
    v_uid,
    v_user_name,
    v_user_role
  )
  RETURNING * INTO v_log;

  RETURN jsonb_build_object(
    'uid', p_gc_uid,
    'gc_number', v_gc.gc_number,
    'buy_at', v_new_buy_at,
    'original_buy_at', v_original_buy_at,
    'expired_date', v_new_expired_date,
    'is_expired', false,
    'has_been_extended', true,
    'extension_log', jsonb_build_object(
      'id', v_log.id,
      'extension_days', v_log.extension_days,
      'allowance_days', v_log.allowance_days,
      'total_added_days', v_log.total_added_days,
      'old_buy_at', v_log.old_buy_at,
      'new_buy_at', v_log.new_buy_at,
      'old_expired_date', v_log.old_expired_date,
      'new_expired_date', v_log.new_expired_date,
      'notes', v_log.notes,
      'extended_by', v_log.extended_by,
      'extended_by_name', v_log.extended_by_name,
      'extended_by_role', v_log.extended_by_role,
      'created_at', v_log.created_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.extend_pos_gc_expiry(UUID, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.extend_pos_gc_expiry(UUID, INTEGER, TEXT) TO authenticated, service_role;

-- Reload PostgREST schema cache
NOTIFY pgrst, 'reload schema';
