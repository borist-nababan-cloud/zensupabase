-- ============================================================================
-- Migration: Update GC Expiry Extension Rules (Option B: 1-30 Days Expired)
--            & 5 Duration Options (1d -> +2d, 1w -> +7d, 2w -> +14d, 3w -> +21d, 4w -> +28d)
-- Date: 2026-11-28
-- Author: Zen Family Spa Architect
-- Description:
--   1. Expands public.ot_pos_gc_expiry_logs CHECK constraint on extension_days
--      to allow (1, 7, 14, 21, 28) idempotently.
--   2. Drops previous 3-arg overload public.extend_pos_gc_expiry(UUID, INTEGER, TEXT)
--      to prevent PostgREST PGRST203 ambiguity.
--   3. Recreates public.extend_pos_gc_expiry(p_gc_uid, p_extension_days, p_notes, p_timezone)
--      enforcing:
--        - Strict RBAC: ONLY Roles 5, 8, 13.
--        - User-timezone date evaluation validated against pg_catalog.pg_timezone_names
--          (fallback 'Asia/Jakarta').
--        - Option B eligibility against ZenSystem 120-day rule:
--          pos_expired_date = (buy_at AT TIME ZONE user_tz)::date + 120,
--          1 <= (today_user - pos_expired_date) <= 30.
--        - Duration mapping added from today_user:
--          1 -> +2d (allowance 1), 7 -> +7d (0), 14 -> +14d (0), 21 -> +21d (0), 28 -> +28d (0).
--        - Atomic update on expired_date and buy_at (new_expired_date - 120 @ 12:00 WIB)
--          while preserving original_buy_at and 1x-only audit record.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Update CHECK constraint on public.ot_pos_gc_expiry_logs(extension_days)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_con RECORD;
BEGIN
  FOR v_con IN
    SELECT conname
    FROM pg_catalog.pg_constraint
    WHERE conrelid = 'public.ot_pos_gc_expiry_logs'::regclass
      AND contype = 'c'
      AND pg_catalog.pg_get_constraintdef(oid) ILIKE '%extension_days%'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.ot_pos_gc_expiry_logs DROP CONSTRAINT IF EXISTS %I',
      v_con.conname
    );
  END LOOP;
END
$$;

ALTER TABLE public.ot_pos_gc_expiry_logs
  DROP CONSTRAINT IF EXISTS chk_ot_pos_gc_expiry_logs_extension_days;

ALTER TABLE public.ot_pos_gc_expiry_logs
  ADD CONSTRAINT chk_ot_pos_gc_expiry_logs_extension_days
  CHECK (extension_days IN (1, 7, 14, 21, 28));

-- ----------------------------------------------------------------------------
-- 2. Drop legacy 3-argument overload & recreate 4-argument RPC
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.extend_pos_gc_expiry(UUID, INTEGER, TEXT);

CREATE OR REPLACE FUNCTION public.extend_pos_gc_expiry(
  p_gc_uid UUID,
  p_extension_days INTEGER,
  p_notes TEXT,
  p_timezone TEXT DEFAULT 'Asia/Jakarta'
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
  v_requested_tz TEXT := NULLIF(TRIM(COALESCE(p_timezone, '')), '');
  v_tz TEXT := 'Asia/Jakarta';
  v_today_user DATE;
  v_buy_date_user DATE;
  v_pos_expired_date DATE;
  v_days_since_expired INTEGER;
  v_allowance_days INTEGER;
  v_total_added_days INTEGER;
  v_old_expired_date DATE;
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

  -- 2. Validate user timezone safely against PostgreSQL IANA timezone catalog
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

  v_today_user := (now() AT TIME ZONE v_tz)::date;

  -- 3. Input Validation
  IF p_gc_uid IS NULL THEN
    RAISE EXCEPTION 'UID Gift Certificate wajib diisi.' USING ERRCODE = '22023';
  END IF;

  IF p_extension_days IS NULL OR p_extension_days NOT IN (1, 7, 14, 21, 28) THEN
    RAISE EXCEPTION 'Pilihan perpanjangan tidak valid. Pilih 1 Hari, 1 Minggu, 2 Minggu, 3 Minggu, atau 4 Minggu.'
      USING ERRCODE = '22023';
  END IF;

  IF length(v_clean_notes) < 10 THEN
    RAISE EXCEPTION 'Catatan / keterangan wajib diisi minimal 10 karakter.'
      USING ERRCODE = '22023';
  END IF;

  -- 4. Row-level Lock & Business Guards
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

  -- 5. Strictly One-Time Extension Check
  IF EXISTS (SELECT 1 FROM public.ot_pos_gc_expiry_logs WHERE gc_uid = p_gc_uid) THEN
    RAISE EXCEPTION 'Masa kadaluarsa GC ini sudah pernah diperpanjang sebelumnya (maksimal 1 kali perpanjangan).'
      USING ERRCODE = '22023';
  END IF;

  -- 6. Option B Eligibility Check against buy_at + 120 days vs user current_date
  IF v_gc.buy_at IS NULL THEN
    RAISE EXCEPTION 'Tanggal beli (buy_at) tidak tersedia pada data GC ini sehingga masa kadaluarsa tidak dapat dihitung.'
      USING ERRCODE = '22023';
  END IF;

  v_buy_date_user := (v_gc.buy_at AT TIME ZONE v_tz)::date;
  v_pos_expired_date := v_buy_date_user + 120;
  v_days_since_expired := v_today_user - v_pos_expired_date;

  IF v_days_since_expired <= 0 THEN
    RAISE EXCEPTION 'GC masih berlaku hingga % (berdasarkan tanggal beli + 120 hari). Perpanjangan hanya diizinkan untuk GC yang sudah kadaluarsa 1 hingga 30 hari.',
      to_char(v_pos_expired_date, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  IF v_days_since_expired > 30 THEN
    RAISE EXCEPTION 'Masa kadaluarsa GC sudah melewati batas maksimal 30 hari (% hari sejak %). Perpanjangan tidak diizinkan.',
      v_days_since_expired,
      to_char(v_pos_expired_date, 'DD/MM/YYYY')
      USING ERRCODE = '22023';
  END IF;

  -- 7. Duration Mapping (from today_user) + ZenSystem 120-Day Sync
  v_allowance_days := CASE WHEN p_extension_days = 1 THEN 1 ELSE 0 END;
  v_total_added_days := CASE WHEN p_extension_days = 1 THEN 2 ELSE p_extension_days END;
  v_old_expired_date := COALESCE(v_gc.expired_date, v_pos_expired_date);
  v_new_expired_date := v_today_user + v_total_added_days;

  -- Set to 12:00:00+07:00 (= 05:00:00 UTC) so both UTC YYYY-MM-DD (Delphi Copy(sBuyAt,1,10))
  -- and Indonesian local timezone dates remain 100% identical with zero drift.
  v_new_buy_at := (((v_new_expired_date - 120)::text || ' 12:00:00+07:00')::timestamptz);
  v_original_buy_at := COALESCE(v_gc.original_buy_at, v_gc.buy_at);

  -- 8. Atomic Update + Audit Log Insert
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

REVOKE ALL ON FUNCTION public.extend_pos_gc_expiry(UUID, INTEGER, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.extend_pos_gc_expiry(UUID, INTEGER, TEXT, TEXT) TO authenticated, service_role;

-- Reload PostgREST schema cache
NOTIFY pgrst, 'reload schema';
