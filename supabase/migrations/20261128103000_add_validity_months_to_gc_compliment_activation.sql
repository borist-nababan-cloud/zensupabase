-- ============================================================================
-- Migration: Add 1-4 Month Validity Options to GC Compliment Activation
--            & Sync ot_pos_gc_transaction.buy_at (-120 Days) for ZenSystem POS
-- Date: 2026-11-28
-- Author: Zen Family Spa Architect
-- Description:
--   1. Adds validity_months INTEGER column + CHECK (1, 2, 3, 4) constraint
--      on public.ot_pos_gc_compliment, backfilling existing active rows to 4.
--   2. Updates generate_pos_gc_compliments and get_pos_gc_compliment_list to
--      return validity_months in row payloads.
--   3. Drops legacy 4-arg activate_pos_gc_compliments(UUID[], TEXT, TIMESTAMPTZ, DATE)
--      and recreates activate_pos_gc_compliments(p_gc_uids, p_pack_number,
--      p_validity_months DEFAULT 1, p_timezone DEFAULT 'Asia/Jakarta') with:
--        - Validity options: 1..4 months => 30 / 60 / 90 / 120 days from
--          user-timezone today date.
--        - ZenSystem Desktop 120-day formula on ot_pos_gc_transaction.buy_at:
--          ((expired_date - 120)::text || ' 12:00:00+07:00')::timestamptz.
--        - Preserves true activation timestamp in ot_pos_gc_transaction.original_buy_at
--          when p_validity_months < 4, and in ot_pos_gc_compliment.activated_at.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Add validity_months column & constraint on public.ot_pos_gc_compliment
-- ----------------------------------------------------------------------------
ALTER TABLE public.ot_pos_gc_compliment
  ADD COLUMN IF NOT EXISTS validity_months INTEGER;

ALTER TABLE public.ot_pos_gc_compliment
  DROP CONSTRAINT IF EXISTS chk_ot_pos_gc_compliment_validity_months;

ALTER TABLE public.ot_pos_gc_compliment
  ADD CONSTRAINT chk_ot_pos_gc_compliment_validity_months
  CHECK (validity_months IS NULL OR validity_months IN (1, 2, 3, 4));

UPDATE public.ot_pos_gc_compliment
SET validity_months = 4
WHERE is_active = true
  AND validity_months IS NULL;

-- ----------------------------------------------------------------------------
-- 2. Update RPC: public.generate_pos_gc_compliments(...) — include validity_months
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_pos_gc_compliments(
  p_prefix TEXT,
  p_start_number INTEGER,
  p_count INTEGER,
  p_web_service_id UUID,
  p_nama_gc TEXT,
  p_harga_jasa NUMERIC,
  p_harga_jual NUMERIC,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_uid UUID;
  v_actor_role INTEGER;
  v_actor_outlet TEXT;
  v_actor_name TEXT;

  v_clean_prefix TEXT;
  v_nama_gc TEXT := TRIM(COALESCE(p_nama_gc, ''));
  v_notes TEXT := NULLIF(TRIM(COALESCE(p_notes, '')), '');

  v_svc_name TEXT;
  v_svc_category TEXT;
  v_svc_duration INTEGER;
  v_svc_bg_url TEXT;

  v_idx INTEGER;
  v_seq INTEGER;
  v_gc_number TEXT;
  v_gc_barcode TEXT;
  v_qrcode TEXT;
  v_qr_attempt INTEGER;

  v_inserted_row public.ot_pos_gc_compliment%ROWTYPE;
  v_rows JSONB := '[]'::jsonb;
BEGIN
  SELECT user_uid, user_role, user_outlet, user_name
  INTO v_actor_uid, v_actor_role, v_actor_outlet, v_actor_name
  FROM public._assert_gc_compliment_access();

  -- Sanitize & validate prefix after '111.'
  v_clean_prefix := UPPER(TRIM(BOTH '.' FROM TRIM(COALESCE(p_prefix, ''))));
  IF v_clean_prefix = '' THEN
    RAISE EXCEPTION 'Prefix GC setelah "111." wajib diisi.' USING ERRCODE = '22023';
  END IF;
  IF v_clean_prefix !~ '^[A-Z0-9._-]+$' THEN
    RAISE EXCEPTION 'Prefix GC hanya boleh menggunakan huruf, angka, titik (.), garis bawah (_), atau tanda hubung (-).'
      USING ERRCODE = '22023';
  END IF;

  IF p_start_number IS NULL OR p_start_number < 1 THEN
    RAISE EXCEPTION 'Nomor urut awal minimal 1.' USING ERRCODE = '22023';
  END IF;

  IF p_count IS NULL OR p_count < 1 OR p_count > 100 THEN
    RAISE EXCEPTION 'Jumlah GC yang dibuat harus antara 1 sampai 100 per batch.' USING ERRCODE = '22023';
  END IF;

  IF v_nama_gc = '' THEN
    RAISE EXCEPTION 'Nama GC wajib diisi.' USING ERRCODE = '22023';
  END IF;

  IF COALESCE(p_harga_jasa, -1) < 0 OR COALESCE(p_harga_jual, -1) < 0 THEN
    RAISE EXCEPTION 'Harga jasa dan harga jual tidak boleh bernilai negatif.' USING ERRCODE = '22023';
  END IF;

  IF p_web_service_id IS NOT NULL THEN
    SELECT name, category, duration_minutes, image_url
    INTO v_svc_name, v_svc_category, v_svc_duration, v_svc_bg_url
    FROM public.web_services
    WHERE id = p_web_service_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Layanan (web_services) tidak ditemukan.' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  FOR v_idx IN 0 .. (p_count - 1) LOOP
    v_seq := p_start_number + v_idx;
    v_gc_number := '111.' || v_clean_prefix || '.' || LPAD(v_seq::text, GREATEST(4, length(v_seq::text)), '0');

    -- Check collision across BOTH compliment draft/issued table AND live POS GC transactions
    IF EXISTS (SELECT 1 FROM public.ot_pos_gc_compliment WHERE gc_number = v_gc_number)
       OR EXISTS (SELECT 1 FROM public.ot_pos_gc_transaction WHERE gc_number = v_gc_number) THEN
      RAISE EXCEPTION 'Nomor GC % sudah ada di sistem. Gunakan prefix atau nomor urut awal yang berbeda.', v_gc_number
        USING ERRCODE = '23505';
    END IF;

    v_gc_barcode := regexp_replace(v_gc_number, '[^0-9]', '', 'g');

    -- Generate high-entropy unique 24-char QR code across both tables
    v_qrcode := NULL;
    FOR v_qr_attempt IN 1 .. 10 LOOP
      v_qrcode := public._generate_gc_qrcode(24);
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.ot_pos_gc_compliment WHERE qrcode = v_qrcode)
            AND NOT EXISTS (SELECT 1 FROM public.ot_pos_gc_transaction WHERE qrcode = v_qrcode);
      v_qrcode := NULL;
    END LOOP;

    IF v_qrcode IS NULL THEN
      RAISE EXCEPTION 'Gagal menghasilkan QR Code unik setelah 10 percobaan.' USING ERRCODE = '23505';
    END IF;

    INSERT INTO public.ot_pos_gc_compliment (
      gc_number,
      gc_barcode,
      qrcode,
      pack_number,
      web_service_id,
      service_name,
      service_category,
      duration_minutes,
      background_image_url,
      nama_gc,
      harga_jasa,
      harga_jual,
      kode_outlet,
      is_active,
      is_sold,
      has_used,
      notes,
      created_at,
      created_by,
      created_by_name
    )
    VALUES (
      v_gc_number,
      v_gc_barcode,
      v_qrcode,
      NULL,
      p_web_service_id,
      v_svc_name,
      v_svc_category,
      v_svc_duration,
      v_svc_bg_url,
      v_nama_gc,
      ROUND(COALESCE(p_harga_jasa, 0)::numeric, 2),
      ROUND(COALESCE(p_harga_jual, 0)::numeric, 2),
      '111',
      false,
      false,
      false,
      v_notes,
      now(),
      v_actor_uid,
      v_actor_name
    )
    RETURNING * INTO v_inserted_row;

    v_rows := v_rows || jsonb_build_array(
      jsonb_build_object(
        'uid', v_inserted_row.uid,
        'gc_number', v_inserted_row.gc_number,
        'gc_barcode', v_inserted_row.gc_barcode,
        'qrcode', v_inserted_row.qrcode,
        'pack_number', v_inserted_row.pack_number,
        'web_service_id', v_inserted_row.web_service_id,
        'service_name', v_inserted_row.service_name,
        'service_category', v_inserted_row.service_category,
        'duration_minutes', v_inserted_row.duration_minutes,
        'background_image_url', v_inserted_row.background_image_url,
        'nama_gc', v_inserted_row.nama_gc,
        'harga_jasa', v_inserted_row.harga_jasa,
        'harga_jual', v_inserted_row.harga_jual,
        'kode_outlet', v_inserted_row.kode_outlet,
        'image_url', v_inserted_row.image_url,
        'is_active', v_inserted_row.is_active,
        'is_sold', v_inserted_row.is_sold,
        'has_used', v_inserted_row.has_used,
        'expired_date', v_inserted_row.expired_date,
        'validity_months', v_inserted_row.validity_months,
        'id_payment_buy', v_inserted_row.id_payment_buy,
        'activated_at', v_inserted_row.activated_at,
        'activated_by', v_inserted_row.activated_by,
        'activated_by_name', v_inserted_row.activated_by_name,
        'notes', v_inserted_row.notes,
        'email_sent_to', v_inserted_row.email_sent_to,
        'email_sent_at', v_inserted_row.email_sent_at,
        'created_at', v_inserted_row.created_at,
        'created_by', v_inserted_row.created_by,
        'created_by_name', v_inserted_row.created_by_name
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'count', p_count,
    'rows', v_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION public.generate_pos_gc_compliments(TEXT, INTEGER, INTEGER, UUID, TEXT, NUMERIC, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.generate_pos_gc_compliments(TEXT, INTEGER, INTEGER, UUID, TEXT, NUMERIC, NUMERIC, TEXT) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Drop legacy overload & recreate public.activate_pos_gc_compliments(...)
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.activate_pos_gc_compliments(UUID[], TEXT, TIMESTAMPTZ, DATE);

CREATE OR REPLACE FUNCTION public.activate_pos_gc_compliments(
  p_gc_uids UUID[],
  p_pack_number TEXT,
  p_validity_months INTEGER DEFAULT 1,
  p_timezone TEXT DEFAULT 'Asia/Jakarta'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_uid UUID;
  v_actor_role INTEGER;
  v_actor_outlet TEXT;
  v_actor_name TEXT;

  v_unique_uids UUID[];
  v_pack TEXT := TRIM(COALESCE(p_pack_number, ''));
  v_requested_tz TEXT := NULLIF(TRIM(COALESCE(p_timezone, '')), '');
  v_tz TEXT := 'Asia/Jakarta';
  v_activated_at TIMESTAMPTZ := now();
  v_today_user DATE;
  v_validity_days INTEGER;
  v_expired_date DATE;
  v_pos_buy_at TIMESTAMPTZ;
  v_original_buy_at TIMESTAMPTZ;
  v_id_payment TEXT;

  v_locked_count INTEGER := 0;
  v_rec RECORD;
  v_rows JSONB := '[]'::jsonb;
BEGIN
  SELECT user_uid, user_role, user_outlet, user_name
  INTO v_actor_uid, v_actor_role, v_actor_outlet, v_actor_name
  FROM public._assert_gc_compliment_access();

  SELECT array_agg(DISTINCT u)
  INTO v_unique_uids
  FROM unnest(COALESCE(p_gc_uids, ARRAY[]::UUID[])) u
  WHERE u IS NOT NULL;

  IF v_unique_uids IS NULL OR COALESCE(array_length(v_unique_uids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'Pilih minimal 1 GC Compliment yang akan diaktifkan.' USING ERRCODE = '22023';
  END IF;

  IF v_pack = '' THEN
    RAISE EXCEPTION 'Pack Number wajib diisi saat mengaktifkan GC.' USING ERRCODE = '22023';
  END IF;

  IF p_validity_months IS NULL OR p_validity_months NOT IN (1, 2, 3, 4) THEN
    RAISE EXCEPTION 'Pilihan Masa Berlaku tidak valid. Pilih 1 Bulan, 2 Bulan, 3 Bulan, atau 4 Bulan.'
      USING ERRCODE = '22023';
  END IF;

  -- Validate user timezone safely against PostgreSQL IANA timezone catalog
  IF v_requested_tz IS NOT NULL THEN
    SELECT name
    INTO v_tz
    FROM pg_catalog.pg_timezone_names
    WHERE name = v_requested_tz
    LIMIT 1;

    IF v_tz IS NULL THEN
      v_tz := 'Asia/Jakarta';
    END IF;
  END IF;

  v_today_user := (v_activated_at AT TIME ZONE v_tz)::date;
  v_validity_days := p_validity_months * 30;
  v_expired_date := v_today_user + v_validity_days;

  -- Sync buy_at to (expired_date - 120 days) at 12:00:00+07:00 (= 05:00 UTC)
  -- so ZenSystem Desktop's 120-day redemption check matches the chosen validity.
  v_pos_buy_at := (((v_expired_date - 120)::text || ' 12:00:00+07:00')::timestamptz);
  v_original_buy_at := CASE WHEN p_validity_months < 4 THEN v_activated_at ELSE NULL END;

  v_id_payment := 'WHMAPP.111.'
    || to_char(v_activated_at AT TIME ZONE 'Asia/Jakarta', 'YYYYMMDDHH24MISS')
    || '.'
    || UPPER(substr(replace(gen_random_uuid()::text, '-', ''), 1, 4));

  -- Lock all target rows atomically in deterministic order
  FOR v_rec IN
    SELECT *
    FROM public.ot_pos_gc_compliment
    WHERE uid = ANY(v_unique_uids)
    ORDER BY gc_number ASC
    FOR UPDATE
  LOOP
    v_locked_count := v_locked_count + 1;

    IF v_rec.is_active = true THEN
      RAISE EXCEPTION 'GC % sudah aktif sebelumnya dan tidak dapat diaktifkan ulang.', v_rec.gc_number
        USING ERRCODE = '22023';
    END IF;

    IF EXISTS (SELECT 1 FROM public.ot_pos_gc_transaction WHERE gc_number = v_rec.gc_number) THEN
      RAISE EXCEPTION 'Nomor GC % sudah terdaftar pada transaksi POS (ot_pos_gc_transaction).', v_rec.gc_number
        USING ERRCODE = '23505';
    END IF;

    IF EXISTS (SELECT 1 FROM public.ot_pos_gc_transaction WHERE qrcode = v_rec.qrcode) THEN
      RAISE EXCEPTION 'QR Code untuk GC % sudah terdaftar pada transaksi POS (ot_pos_gc_transaction).', v_rec.gc_number
        USING ERRCODE = '23505';
    END IF;
  END LOOP;

  IF v_locked_count <> array_length(v_unique_uids, 1) THEN
    RAISE EXCEPTION 'Sebagian data GC Compliment tidak ditemukan.' USING ERRCODE = 'P0002';
  END IF;

  -- Insert all selected GCs into public.ot_pos_gc_transaction
  INSERT INTO public.ot_pos_gc_transaction (
    gc_number,
    gc_barcode,
    qrcode,
    pack_number,
    nama_gc,
    value,
    buy_at,
    original_buy_at,
    expired_date,
    has_used,
    is_active,
    id_payment_buy,
    kode_outlet_buy,
    created_at,
    created_by
  )
  SELECT
    c.gc_number,
    c.gc_barcode,
    c.qrcode,
    v_pack,
    c.nama_gc,
    COALESCE(c.harga_jasa, 0)::double precision,
    v_pos_buy_at,
    v_original_buy_at,
    v_expired_date,
    false,
    true,
    v_id_payment,
    '111',
    now(),
    v_actor_uid
  FROM public.ot_pos_gc_compliment c
  WHERE c.uid = ANY(v_unique_uids);

  -- Update compliment registry status & true activation audit metadata
  UPDATE public.ot_pos_gc_compliment
  SET
    is_active = true,
    is_sold = true,
    pack_number = v_pack,
    id_payment_buy = v_id_payment,
    expired_date = v_expired_date,
    validity_months = p_validity_months,
    activated_at = v_activated_at,
    activated_by = v_actor_uid,
    activated_by_name = v_actor_name
  WHERE uid = ANY(v_unique_uids);

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'uid', c.uid,
        'gc_number', c.gc_number,
        'gc_barcode', c.gc_barcode,
        'qrcode', c.qrcode,
        'pack_number', c.pack_number,
        'nama_gc', c.nama_gc,
        'duration_minutes', c.duration_minutes,
        'background_image_url', c.background_image_url,
        'expired_date', c.expired_date,
        'validity_months', c.validity_months,
        'id_payment_buy', c.id_payment_buy,
        'activated_at', c.activated_at
      )
      ORDER BY c.gc_number ASC
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.ot_pos_gc_compliment c
  WHERE c.uid = ANY(v_unique_uids);

  RETURN jsonb_build_object(
    'id_payment_buy', v_id_payment,
    'pack_number', v_pack,
    'buy_at', v_pos_buy_at,
    'original_buy_at', v_original_buy_at,
    'activated_at', v_activated_at,
    'validity_months', p_validity_months,
    'validity_days', v_validity_days,
    'expired_date', v_expired_date,
    'activated_count', v_locked_count,
    'rows', v_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION public.activate_pos_gc_compliments(UUID[], TEXT, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activate_pos_gc_compliments(UUID[], TEXT, INTEGER, TEXT) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Update RPC: public.get_pos_gc_compliment_list(...) — include validity_months
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pos_gc_compliment_list(
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL,
  p_is_active TEXT DEFAULT 'ALL',
  p_has_used TEXT DEFAULT 'ALL',
  p_web_service_id UUID DEFAULT NULL,
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
  v_actor_uid UUID;
  v_actor_role INTEGER;
  v_actor_outlet TEXT;
  v_actor_name TEXT;

  v_is_active TEXT := UPPER(COALESCE(NULLIF(TRIM(p_is_active), ''), 'ALL'));
  v_has_used TEXT := UPPER(COALESCE(NULLIF(TRIM(p_has_used), ''), 'ALL'));
  v_search TEXT := NULLIF(TRIM(COALESCE(p_search, '')), '');
  v_page INTEGER := GREATEST(COALESCE(p_page, 1), 1);
  v_page_size INTEGER := LEAST(GREATEST(COALESCE(p_page_size, 50), 1), 2000);
  v_offset INTEGER;

  v_total_count INTEGER := 0;
  v_summary JSONB;
  v_rows JSONB := '[]'::jsonb;
BEGIN
  SELECT user_uid, user_role, user_outlet, user_name
  INTO v_actor_uid, v_actor_role, v_actor_outlet, v_actor_name
  FROM public._assert_gc_compliment_access();

  IF v_search IS NULL AND p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_start_date > p_end_date THEN
    RAISE EXCEPTION 'Tanggal mulai tidak boleh lebih besar dari tanggal akhir.' USING ERRCODE = '22023';
  END IF;

  v_offset := (v_page - 1) * v_page_size;

  WITH base AS (
    SELECT
      c.uid,
      c.gc_number,
      c.gc_barcode,
      c.qrcode,
      COALESCE(tx.pack_number, c.pack_number) AS pack_number,
      c.web_service_id,
      c.service_name,
      c.service_category,
      c.duration_minutes,
      c.background_image_url,
      c.nama_gc,
      COALESCE(c.harga_jasa, 0)::numeric(15, 2) AS harga_jasa,
      COALESCE(c.harga_jual, 0)::numeric(15, 2) AS harga_jual,
      c.kode_outlet,
      c.image_url,
      c.is_active,
      c.is_sold,
      COALESCE(tx.has_used, c.has_used, false) AS has_used,
      tx.used_at,
      tx.kode_outlet_used,
      mo_used.name_outlet AS outlet_used_name,
      COALESCE(tx.expired_date, c.expired_date) AS expired_date,
      c.validity_months,
      COALESCE(tx.id_payment_buy, c.id_payment_buy) AS id_payment_buy,
      c.activated_at,
      c.activated_by,
      c.activated_by_name,
      c.notes,
      c.email_sent_to,
      c.email_sent_at,
      c.created_at,
      c.created_by,
      c.created_by_name
    FROM public.ot_pos_gc_compliment c
    LEFT JOIN public.ot_pos_gc_transaction tx ON tx.gc_number = c.gc_number
    LEFT JOIN public.master_outlet mo_used ON mo_used.kode_outlet = tx.kode_outlet_used
  ),
  filtered AS (
    SELECT b.*
    FROM base b
    WHERE
      (
        CASE
          WHEN v_search IS NOT NULL THEN
            (
              COALESCE(b.gc_number, '') ILIKE '%' || v_search || '%'
              OR COALESCE(b.gc_barcode, '') ILIKE '%' || v_search || '%'
              OR COALESCE(b.qrcode, '') ILIKE '%' || v_search || '%'
              OR COALESCE(b.pack_number, '') ILIKE '%' || v_search || '%'
              OR COALESCE(b.nama_gc, '') ILIKE '%' || v_search || '%'
              OR COALESCE(b.notes, '') ILIKE '%' || v_search || '%'
              OR COALESCE(b.id_payment_buy, '') ILIKE '%' || v_search || '%'
            )
          ELSE
            (
              (p_start_date IS NULL OR (b.created_at AT TIME ZONE 'Asia/Jakarta')::date >= p_start_date)
              AND (p_end_date IS NULL OR (b.created_at AT TIME ZONE 'Asia/Jakarta')::date <= p_end_date)
            )
        END
      )
      AND (
        v_is_active = 'ALL'
        OR (v_is_active = 'TRUE' AND b.is_active = true)
        OR (v_is_active = 'FALSE' AND b.is_active = false)
      )
      AND (
        v_has_used = 'ALL'
        OR (v_has_used = 'TRUE' AND b.has_used = true)
        OR (v_has_used = 'FALSE' AND b.has_used = false)
      )
      AND (
        p_web_service_id IS NULL OR b.web_service_id = p_web_service_id
      )
  ),
  agg AS (
    SELECT
      COUNT(*)::integer AS total_count,
      COALESCE(SUM(f.harga_jasa), 0)::numeric(15, 2) AS total_harga_jasa,
      COUNT(*) FILTER (WHERE f.is_active = false)::integer AS draft_count,
      COUNT(*) FILTER (WHERE f.is_active = true AND f.has_used = false)::integer AS active_unused_count,
      COUNT(*) FILTER (WHERE f.has_used = true)::integer AS used_count
    FROM filtered f
  ),
  paged AS (
    SELECT f.*
    FROM filtered f
    ORDER BY f.created_at DESC, f.gc_number ASC
    LIMIT v_page_size
    OFFSET v_offset
  )
  SELECT
    a.total_count,
    jsonb_build_object(
      'total_count', a.total_count,
      'total_harga_jasa', a.total_harga_jasa,
      'draft_count', a.draft_count,
      'active_unused_count', a.active_unused_count,
      'used_count', a.used_count
    ),
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'uid', p.uid,
          'gc_number', p.gc_number,
          'gc_barcode', p.gc_barcode,
          'qrcode', p.qrcode,
          'pack_number', p.pack_number,
          'web_service_id', p.web_service_id,
          'service_name', p.service_name,
          'service_category', p.service_category,
          'duration_minutes', p.duration_minutes,
          'background_image_url', p.background_image_url,
          'nama_gc', p.nama_gc,
          'harga_jasa', p.harga_jasa,
          'harga_jual', p.harga_jual,
          'kode_outlet', p.kode_outlet,
          'image_url', p.image_url,
          'is_active', p.is_active,
          'is_sold', p.is_sold,
          'has_used', p.has_used,
          'used_at', p.used_at,
          'kode_outlet_used', p.kode_outlet_used,
          'outlet_used_name', p.outlet_used_name,
          'expired_date', p.expired_date,
          'validity_months', p.validity_months,
          'id_payment_buy', p.id_payment_buy,
          'activated_at', p.activated_at,
          'activated_by', p.activated_by,
          'activated_by_name', p.activated_by_name,
          'notes', p.notes,
          'email_sent_to', p.email_sent_to,
          'email_sent_at', p.email_sent_at,
          'created_at', p.created_at,
          'created_by', p.created_by,
          'created_by_name', p.created_by_name
        )
        ORDER BY p.created_at DESC, p.gc_number ASC
      )
      FROM paged p
    ), '[]'::jsonb)
  INTO v_total_count, v_summary, v_rows
  FROM agg a;

  RETURN jsonb_build_object(
    'summary', COALESCE(v_summary, jsonb_build_object(
      'total_count', 0,
      'total_harga_jasa', 0,
      'draft_count', 0,
      'active_unused_count', 0,
      'used_count', 0
    )),
    'pagination', jsonb_build_object(
      'page', v_page,
      'page_size', v_page_size,
      'total_count', COALESCE(v_total_count, 0),
      'total_pages', GREATEST(CEIL(COALESCE(v_total_count, 0)::numeric / v_page_size)::integer, 1)
    ),
    'rows', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_gc_compliment_list(DATE, DATE, TEXT, TEXT, UUID, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pos_gc_compliment_list(DATE, DATE, TEXT, TEXT, UUID, TEXT, INTEGER, INTEGER) TO authenticated, service_role;

-- Reload PostgREST schema cache
NOTIFY pgrst, 'reload schema';
