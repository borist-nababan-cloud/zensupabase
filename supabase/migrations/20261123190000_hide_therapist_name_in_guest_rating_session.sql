-- ==============================================================================
-- MIGRATION: 20261123190000_hide_therapist_name_in_guest_rating_session.sql
-- Description:
--   Update public.get_guest_rating_session() so therapist full name
--   (namakaryawan) is NEVER exposed to public guests; return only
--   kodekaryawan, idkaryawan, departemen, and photo_url.
-- ==============================================================================

SET ROLE postgres;

CREATE OR REPLACE FUNCTION public.get_guest_rating_session(p_ratingcode TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_code TEXT;
    v_row RECORD;
    v_outlet RECORD;
    v_therapist RECORD;
    v_room RECORD;
    v_submitted_at TIMESTAMPTZ;
    v_already_submitted BOOLEAN := false;
    v_clean_room_id TEXT;
    v_kode_karyawan TEXT;
    v_id_karyawan TEXT;
BEGIN
    v_code := NULLIF(btrim(COALESCE(p_ratingcode, '')), '');

    IF v_code IS NULL OR v_code !~ '^[A-Za-z0-9._-]{5,64}$' THEN
        RETURN jsonb_build_object(
            'found', false,
            'code', 'INVALID_CODE'
        );
    END IF;

    SELECT
        r.ratingcode,
        r.kode_outlet,
        r.tanggal,
        r.kodekaryawan,
        r.room_id
    INTO v_row
    FROM public.ot_pos_guest_rating r
    WHERE r.ratingcode = v_code
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'found', false,
            'code', 'NOT_FOUND'
        );
    END IF;

    SELECT
        o.kode_outlet,
        o.name_outlet,
        o.alamat,
        o.city,
        o.no_wa,
        o.location
    INTO v_outlet
    FROM public.master_outlet o
    WHERE o.kode_outlet = v_row.kode_outlet
    LIMIT 1;

    IF NULLIF(btrim(COALESCE(v_row.kodekaryawan, '')), '') IS NOT NULL THEN
        SELECT
            k.kodekaryawan,
            k.idkaryawan,
            k.departemen,
            k.foto_url
        INTO v_therapist
        FROM public.ot_hrd_karyawan_info k
        WHERE k.kodekaryawan = v_row.kodekaryawan
        LIMIT 1;
    END IF;

    v_kode_karyawan := NULLIF(btrim(COALESCE(v_therapist.kodekaryawan, v_row.kodekaryawan, '')), '');
    v_id_karyawan   := NULLIF(btrim(COALESCE(v_therapist.idkaryawan, '')), '');

    IF NULLIF(btrim(COALESCE(v_row.room_id, '')), '') IS NOT NULL THEN
        SELECT
            rm.room_id,
            rm.jenis_jasa,
            rm.room_gender,
            rm.keterangan
        INTO v_room
        FROM public.ot_master_room rm
        WHERE rm.kode_outlet = v_row.kode_outlet
          AND (
              rm.room_id = v_row.room_id
              OR rm.room_id = v_row.kode_outlet || '.' || v_row.room_id
          )
        ORDER BY CASE WHEN rm.room_id = v_row.room_id THEN 0 ELSE 1 END
        LIMIT 1;

        v_clean_room_id := COALESCE(v_room.room_id, v_row.room_id);
        IF v_clean_room_id LIKE v_row.kode_outlet || '.%' THEN
            v_clean_room_id := substr(v_clean_room_id, length(v_row.kode_outlet) + 2);
        END IF;
    END IF;

    SELECT s.submitted_at
    INTO v_submitted_at
    FROM public.web_guest_rating_submissions s
    WHERE s.ratingcode = v_code
    LIMIT 1;

    v_already_submitted := FOUND;

    RETURN jsonb_build_object(
        'found', true,
        'ratingcode', v_row.ratingcode,
        'tanggal', v_row.tanggal,
        'already_submitted', v_already_submitted,
        'submitted_at', v_submitted_at,
        'outlet', jsonb_build_object(
            'kode_outlet', v_row.kode_outlet,
            'name_outlet', COALESCE(v_outlet.name_outlet, 'Zen Family Spa'),
            'alamat', v_outlet.alamat,
            'city', v_outlet.city,
            'no_wa', v_outlet.no_wa,
            'location', v_outlet.location
        ),
        'therapist', CASE
            WHEN v_kode_karyawan IS NOT NULL OR v_id_karyawan IS NOT NULL THEN jsonb_build_object(
                'kodekaryawan', v_kode_karyawan,
                'idkaryawan', v_id_karyawan,
                'departemen', v_therapist.departemen,
                'photo_url', v_therapist.foto_url
            )
            ELSE NULL
        END,
        'room', CASE
            WHEN NULLIF(btrim(COALESCE(v_clean_room_id, '')), '') IS NOT NULL THEN jsonb_build_object(
                'room_id', v_clean_room_id,
                'jenis_jasa', v_room.jenis_jasa,
                'room_gender', v_room.room_gender,
                'keterangan', v_room.keterangan
            )
            ELSE NULL
        END
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_guest_rating_session(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_guest_rating_session(TEXT) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
