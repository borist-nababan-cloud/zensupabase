-- ============================================================================
-- Migration: Menu POS > Therapist Flow RPC & Performance Indexes
-- Date: 2026-11-26
-- Author: Zen Family Spa Architect
-- Description:
--   1. Adds composite B-Tree indexes on ot_pos_trans_master(kode_outlet, tanggal, start_time)
--      and ot_hrd_absen_harian(kode_outlet, tanggal) for fast single-outlet daily queries.
--   2. Creates SECURITY DEFINER RPC public.get_pos_therapist_flow(p_kode_outlet, p_tanggal)
--      with strict RBAC validation (Roles 5, 6, 8, 11, 13, 14, 15, 16, 19, 20),
--      server-side outlet locking (Roles 6, 11, 14, 15, 19), single-outlet enforcement
--      (blocks 'ALL'), natural numeric sorting for ngroup (ASC) and noslot (ASC/DESC by
--      ot_pos_tr_flow_master.status_slot), attendance enrichment from ot_hrd_absen_harian,
--      and guest transaction mapping from ot_pos_trans_master ordered by start_time ASC
--      (excluding financial subtotal for role privacy).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Performance Indexes
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_ot_pos_trans_master_outlet_tanggal_start
  ON public.ot_pos_trans_master (kode_outlet, tanggal, start_time ASC);

CREATE INDEX IF NOT EXISTS idx_ot_hrd_absen_outlet_tanggal
  ON public.ot_hrd_absen_harian (kode_outlet, tanggal);

-- ----------------------------------------------------------------------------
-- 2. Centralized Server-Side RPC: public.get_pos_therapist_flow(...)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pos_therapist_flow(
  p_kode_outlet TEXT DEFAULT NULL,
  p_tanggal DATE DEFAULT NULL
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
  v_target_outlet TEXT;
  v_name_outlet TEXT;
  v_today_wib DATE := (now() AT TIME ZONE 'Asia/Jakarta')::date;
  v_target_date DATE;

  v_status_slot SMALLINT := 0;
  v_source TEXT := 'DEFAULT';
  v_updated_by TEXT := NULL;
  v_updated_at TIMESTAMPTZ := NULL;
  v_master_found BOOLEAN := false;
  v_prev_slot SMALLINT := NULL;

  v_bm_rows JSONB := '[]'::jsonb;
  v_rf_rows JSONB := '[]'::jsonb;
  v_bm_therapists INTEGER := 0;
  v_bm_present INTEGER := 0;
  v_bm_guests INTEGER := 0;
  v_rf_therapists INTEGER := 0;
  v_rf_present INTEGER := 0;
  v_rf_guests INTEGER := 0;
  v_total_active_started INTEGER := 0;
BEGIN
  -- 1. Auth & RBAC Validation (Roles 5, 6, 8, 11, 13, 14, 15, 16, 19, 20 ONLY)
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Autentikasi diperlukan.' USING ERRCODE = '42501';
  END IF;

  SELECT user_role, NULLIF(TRIM(kode_outlet), '')
  INTO v_user_role, v_user_outlet
  FROM public.users_profile
  WHERE uid = v_uid;

  IF v_user_role IS NULL OR v_user_role NOT IN (5, 6, 8, 11, 13, 14, 15, 16, 19, 20) THEN
    RAISE EXCEPTION 'Akses ditolak. Role Anda tidak berwenang membuka menu Therapist Flow.' USING ERRCODE = '42501';
  END IF;

  -- 2. Outlet Scoping (Locked vs Single-Outlet Multi-Outlet Selector)
  v_is_locked := v_user_role IN (6, 11, 14, 15, 19);

  IF v_is_locked THEN
    IF v_user_outlet IS NULL THEN
      RAISE EXCEPTION 'Kode outlet wajib terdaftar pada profil pengguna Anda.' USING ERRCODE = '22023';
    END IF;
    v_target_outlet := v_user_outlet;
  ELSE
    IF UPPER(TRIM(COALESCE(p_kode_outlet, ''))) = 'ALL' THEN
      RAISE EXCEPTION 'Pilih 1 outlet spesifik (opsi Semua Outlet tidak diizinkan).' USING ERRCODE = '22023';
    END IF;
    v_target_outlet := COALESCE(NULLIF(TRIM(p_kode_outlet), ''), '101');
  END IF;

  v_target_date := COALESCE(p_tanggal, v_today_wib);

  SELECT mo.name_outlet
  INTO v_name_outlet
  FROM public.master_outlet mo
  WHERE mo.kode_outlet = v_target_outlet;

  -- 3. Resolve status_slot from ot_pos_tr_flow_master (0=ATAS/ASC, 1=BAWAH/DESC)
  SELECT m.status_slot, m.source, m.updated_by, m.updated_at
  INTO v_status_slot, v_source, v_updated_by, v_updated_at
  FROM public.ot_pos_tr_flow_master m
  WHERE m.kode_outlet = v_target_outlet
    AND m.tanggal = v_target_date
  LIMIT 1;

  IF FOUND THEN
    v_master_found := true;
  ELSE
    v_master_found := false;
    IF v_target_date = v_today_wib THEN
      SELECT m.status_slot
      INTO v_prev_slot
      FROM public.ot_pos_tr_flow_master m
      WHERE m.kode_outlet = v_target_outlet
        AND m.tanggal = (v_target_date - INTERVAL '1 day')::date
      LIMIT 1;

      IF FOUND THEN
        v_status_slot := CASE WHEN v_prev_slot = 0 THEN 1 ELSE 0 END;
        v_source := 'ESTIMATED_FLIP';
      ELSE
        v_status_slot := 0;
        v_source := 'DEFAULT';
      END IF;
    ELSE
      v_status_slot := 0;
      v_source := 'DEFAULT';
    END IF;
  END IF;

  -- 4. Compute Therapist Flow rows (TB = Flow BM, TR = Flow RF)
  WITH absen_day AS (
    SELECT
      NULLIF(TRIM(a.kodekaryawan), '') AS kodekaryawan,
      NULLIF(TRIM(a.id_karyawan), '') AS id_karyawan,
      a.fp_in,
      a.fp_out
    FROM public.ot_hrd_absen_harian a
    WHERE a.kode_outlet = v_target_outlet
      AND a.tanggal = v_target_date
  ),
  trans_day AS (
    SELECT
      NULLIF(TRIM(m.kodekaryawan), '') AS kodekaryawan,
      m.trans_id,
      m.start_time,
      m.end_time,
      m.nama_customer,
      m.room_id,
      m.status_trans,
      m.byrequest,
      m.typejasa,
      m.rcpt
    FROM public.ot_pos_trans_master m
    WHERE m.kode_outlet = v_target_outlet
      AND m.tanggal = v_target_date
      AND NULLIF(TRIM(m.kodekaryawan), '') IS NOT NULL
  ),
  flow_enriched AS (
    SELECT
      d.kodekaryawan,
      COALESCE(d.idkaryawan, '') AS idkaryawan,
      COALESCE(d.namakaryawan, d.kodekaryawan) AS namakaryawan,
      d.departemen,
      COALESCE(TRIM(d.ngroup), '') AS ngroup,
      COALESCE(TRIM(d.noslot), '') AS noslot,
      CASE
        WHEN TRIM(COALESCE(d.ngroup, '')) ~ '^[0-9]+$' THEN TRIM(d.ngroup)::integer
        ELSE NULL
      END AS group_num,
      CASE
        WHEN TRIM(COALESCE(d.noslot, '')) ~ '^[0-9]+$' THEN TRIM(d.noslot)::integer
        ELSE NULL
      END AS slot_num,
      att.fp_in,
      att.fp_out,
      CASE
        WHEN att.fp_in IS NOT NULL THEN to_char(att.fp_in AT TIME ZONE 'Asia/Jakarta', 'HH24:MI')
        ELSE NULL
      END AS fp_in_wib,
      CASE
        WHEN att.fp_out IS NOT NULL THEN to_char(att.fp_out AT TIME ZONE 'Asia/Jakarta', 'HH24:MI')
        ELSE NULL
      END AS fp_out_wib,
      CASE
        WHEN att.fp_in IS NULL AND att.fp_out IS NULL THEN 'ABSENT'
        WHEN att.fp_in IS NOT NULL AND att.fp_out IS NOT NULL
          AND EXTRACT(EPOCH FROM (att.fp_out - att.fp_in)) >= 7200 THEN 'CLOCKED_OUT'
        ELSE 'PRESENT'
      END AS attendance_status,
      tr.guests,
      tr.total_guests,
      tr.active_started_count
    FROM public.ot_pos_tr_flow_detail d
    LEFT JOIN LATERAL (
      SELECT
        MIN(ad.fp_in) AS fp_in,
        MAX(ad.fp_out) AS fp_out
      FROM absen_day ad
      WHERE ad.kodekaryawan = NULLIF(TRIM(d.kodekaryawan), '')
         OR (
           ad.kodekaryawan IS NULL
           AND NULLIF(TRIM(d.idkaryawan), '') IS NOT NULL
           AND ad.id_karyawan = NULLIF(TRIM(d.idkaryawan), '')
         )
    ) att ON true
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(
          jsonb_agg(
            jsonb_build_object(
              'trans_id', td.trans_id,
              'start_time', CASE WHEN td.start_time IS NOT NULL THEN to_char(td.start_time, 'HH24:MI:SS') ELSE NULL END,
              'end_time', CASE WHEN td.end_time IS NOT NULL THEN to_char(td.end_time, 'HH24:MI:SS') ELSE NULL END,
              'nama_customer', td.nama_customer,
              'room_id', td.room_id,
              'status_trans', td.status_trans,
              'byrequest', td.byrequest,
              'typejasa', td.typejasa,
              'rcpt', td.rcpt
            )
            ORDER BY td.start_time ASC NULLS LAST, td.trans_id ASC
          ),
          '[]'::jsonb
        ) AS guests,
        COUNT(*)::integer AS total_guests,
        COUNT(*) FILTER (WHERE UPPER(COALESCE(td.status_trans, '')) = 'STARTED')::integer AS active_started_count
      FROM trans_day td
      WHERE td.kodekaryawan = NULLIF(TRIM(d.kodekaryawan), '')
    ) tr ON true
    WHERE d.kode_outlet = v_target_outlet
      AND d.departemen IN ('TB', 'TR')
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'kodekaryawan', f.kodekaryawan,
          'idkaryawan', f.idkaryawan,
          'namakaryawan', f.namakaryawan,
          'departemen', f.departemen,
          'ngroup', f.ngroup,
          'noslot', f.noslot,
          'attendance_status', f.attendance_status,
          'fp_in', f.fp_in,
          'fp_out', f.fp_out,
          'fp_in_wib', f.fp_in_wib,
          'fp_out_wib', f.fp_out_wib,
          'total_guests', f.total_guests,
          'active_started_count', f.active_started_count,
          'guests', f.guests
        )
        ORDER BY
          f.group_num ASC NULLS LAST,
          COALESCE(NULLIF(f.ngroup, ''), 'zzzzzz') ASC,
          CASE WHEN v_status_slot = 0 THEN f.slot_num ELSE NULL END ASC NULLS LAST,
          CASE WHEN v_status_slot = 0 THEN COALESCE(NULLIF(f.noslot, ''), 'zzzzzz') ELSE '' END ASC,
          CASE WHEN v_status_slot = 1 THEN f.slot_num ELSE NULL END DESC NULLS LAST,
          CASE WHEN v_status_slot = 1 THEN f.noslot ELSE '' END DESC,
          f.namakaryawan ASC,
          f.kodekaryawan ASC
      )
      FROM flow_enriched f
      WHERE f.departemen = 'TB'
    ), '[]'::jsonb),
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'kodekaryawan', f.kodekaryawan,
          'idkaryawan', f.idkaryawan,
          'namakaryawan', f.namakaryawan,
          'departemen', f.departemen,
          'ngroup', f.ngroup,
          'noslot', f.noslot,
          'attendance_status', f.attendance_status,
          'fp_in', f.fp_in,
          'fp_out', f.fp_out,
          'fp_in_wib', f.fp_in_wib,
          'fp_out_wib', f.fp_out_wib,
          'total_guests', f.total_guests,
          'active_started_count', f.active_started_count,
          'guests', f.guests
        )
        ORDER BY
          f.group_num ASC NULLS LAST,
          COALESCE(NULLIF(f.ngroup, ''), 'zzzzzz') ASC,
          CASE WHEN v_status_slot = 0 THEN f.slot_num ELSE NULL END ASC NULLS LAST,
          CASE WHEN v_status_slot = 0 THEN COALESCE(NULLIF(f.noslot, ''), 'zzzzzz') ELSE '' END ASC,
          CASE WHEN v_status_slot = 1 THEN f.slot_num ELSE NULL END DESC NULLS LAST,
          CASE WHEN v_status_slot = 1 THEN f.noslot ELSE '' END DESC,
          f.namakaryawan ASC,
          f.kodekaryawan ASC
      )
      FROM flow_enriched f
      WHERE f.departemen = 'TR'
    ), '[]'::jsonb),
    COUNT(*) FILTER (WHERE f.departemen = 'TB')::integer,
    COUNT(*) FILTER (WHERE f.departemen = 'TB' AND f.attendance_status = 'PRESENT')::integer,
    COALESCE(SUM(f.total_guests) FILTER (WHERE f.departemen = 'TB'), 0)::integer,
    COUNT(*) FILTER (WHERE f.departemen = 'TR')::integer,
    COUNT(*) FILTER (WHERE f.departemen = 'TR' AND f.attendance_status = 'PRESENT')::integer,
    COALESCE(SUM(f.total_guests) FILTER (WHERE f.departemen = 'TR'), 0)::integer,
    COALESCE(SUM(f.active_started_count), 0)::integer
  INTO
    v_bm_rows,
    v_rf_rows,
    v_bm_therapists,
    v_bm_present,
    v_bm_guests,
    v_rf_therapists,
    v_rf_present,
    v_rf_guests,
    v_total_active_started
  FROM flow_enriched f;

  RETURN jsonb_build_object(
    'kode_outlet', v_target_outlet,
    'name_outlet', COALESCE(v_name_outlet, v_target_outlet),
    'tanggal', v_target_date,
    'today_wib', v_today_wib,
    'is_outlet_locked', v_is_locked,
    'master', jsonb_build_object(
      'status_slot', v_status_slot,
      'direction', CASE WHEN v_status_slot = 0 THEN 'ASC' ELSE 'DESC' END,
      'label', CASE WHEN v_status_slot = 0 THEN 'ATAS' ELSE 'BAWAH' END,
      'source', v_source,
      'master_found', v_master_found,
      'updated_by', v_updated_by,
      'updated_at', v_updated_at
    ),
    'summary', jsonb_build_object(
      'bm_therapists', COALESCE(v_bm_therapists, 0),
      'bm_present', COALESCE(v_bm_present, 0),
      'bm_guests', COALESCE(v_bm_guests, 0),
      'rf_therapists', COALESCE(v_rf_therapists, 0),
      'rf_present', COALESCE(v_rf_present, 0),
      'rf_guests', COALESCE(v_rf_guests, 0),
      'total_active_started', COALESCE(v_total_active_started, 0)
    ),
    'bm_rows', COALESCE(v_bm_rows, '[]'::jsonb),
    'rf_rows', COALESCE(v_rf_rows, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_therapist_flow(TEXT, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pos_therapist_flow(TEXT, DATE) TO authenticated, service_role;

-- Reload PostgREST schema cache
NOTIFY pgrst, 'reload schema';
