-- ==============================================================================
-- MIGRATION: 20261123140000_create_web_guest_rating_submissions_and_rpcs.sql
-- Description:
--   1. Create isolated table public.web_guest_rating_submissions (zero direct anon access)
--   2. Create reporting view public.view_web_guest_rating_summary (security_invoker = true)
--   3. Create SECURITY DEFINER RPCs:
--      - public.get_guest_rating_session(p_ratingcode TEXT)         [anon/authenticated/service_role]
--      - public.submit_guest_rating(...)                            [anon/authenticated/service_role]
--      - public.get_guest_rating_notification_payload(UUID)         [service_role ONLY]
-- ==============================================================================

SET ROLE postgres;

-- 1. Table: public.web_guest_rating_submissions
CREATE TABLE IF NOT EXISTS public.web_guest_rating_submissions (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ratingcode TEXT NOT NULL UNIQUE REFERENCES public.ot_pos_guest_rating(ratingcode) ON UPDATE CASCADE ON DELETE RESTRICT,
    kode_outlet TEXT NOT NULL,
    tanggal DATE,
    trans_id TEXT,
    id_payment TEXT,
    kodekaryawan TEXT,
    room_id TEXT,
    user_uid TEXT,
    outlet_rate SMALLINT NOT NULL CHECK (outlet_rate BETWEEN 1 AND 5),
    outlet_tags TEXT[] NOT NULL DEFAULT '{}',
    outlet_notes TEXT,
    tr_rate SMALLINT NOT NULL CHECK (tr_rate BETWEEN 1 AND 5),
    tr_tags TEXT[] NOT NULL DEFAULT '{}',
    tr_notes TEXT,
    room_rate SMALLINT NOT NULL CHECK (room_rate BETWEEN 1 AND 5),
    room_tags TEXT[] NOT NULL DEFAULT '{}',
    room_notes TEXT,
    avg_rate NUMERIC(3,2) GENERATED ALWAYS AS (ROUND(((outlet_rate + tr_rate + room_rate)::NUMERIC / 3.0), 2)) STORED,
    is_bad_rating BOOLEAN GENERATED ALWAYS AS (outlet_rate < 3 OR tr_rate < 3 OR room_rate < 3) STORED,
    as_anonim BOOLEAN NOT NULL DEFAULT true,
    guest_name TEXT,
    guest_email TEXT,
    language TEXT NOT NULL DEFAULT 'id' CHECK (language IN ('id', 'en')),
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    notified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for fast outlet reporting, therapist HR evaluation, and bad rating alerts
CREATE INDEX IF NOT EXISTS idx_web_guest_rating_sub_outlet_date
    ON public.web_guest_rating_submissions (kode_outlet, tanggal DESC);

CREATE INDEX IF NOT EXISTS idx_web_guest_rating_sub_karyawan_date
    ON public.web_guest_rating_submissions (kodekaryawan, tanggal DESC);

CREATE INDEX IF NOT EXISTS idx_web_guest_rating_sub_bad
    ON public.web_guest_rating_submissions (is_bad_rating, submitted_at DESC)
    WHERE is_bad_rating = true;

CREATE INDEX IF NOT EXISTS idx_web_guest_rating_sub_submitted_at
    ON public.web_guest_rating_submissions (submitted_at DESC);

-- Strict Row Level Security & Grants (Zero direct anon read/write access)
ALTER TABLE public.web_guest_rating_submissions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.web_guest_rating_submissions FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.web_guest_rating_submissions FROM authenticated;
GRANT ALL ON TABLE public.web_guest_rating_submissions TO postgres, service_role;
GRANT SELECT ON TABLE public.web_guest_rating_submissions TO authenticated;

DROP POLICY IF EXISTS "Service role full access on web_guest_rating_submissions" ON public.web_guest_rating_submissions;
CREATE POLICY "Service role full access on web_guest_rating_submissions"
    ON public.web_guest_rating_submissions
    AS PERMISSIVE FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS "Management and HRD can view web_guest_rating_submissions" ON public.web_guest_rating_submissions;
CREATE POLICY "Management and HRD can view web_guest_rating_submissions"
    ON public.web_guest_rating_submissions
    AS PERMISSIVE FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.users_profile up
            WHERE up.uid = auth.uid()
              AND COALESCE(up.is_active, true) = true
              AND (
                  (up.user_role IN (1, 5, 8, 13, 16, 18) OR up.role_user IN (1, 5, 8, 13, 16, 18))
                  OR (
                      (up.user_role IN (6, 14, 15) OR up.role_user IN (6, 14, 15))
                      AND up.kode_outlet = web_guest_rating_submissions.kode_outlet
                  )
              )
        )
    );

-- 2. Reporting View (security_invoker = true so caller RLS applies)
CREATE OR REPLACE VIEW public.view_web_guest_rating_summary
WITH (security_invoker = true) AS
SELECT
    s.uid,
    s.ratingcode,
    s.kode_outlet,
    o.name_outlet,
    o.city,
    s.tanggal,
    s.trans_id,
    s.id_payment,
    s.kodekaryawan,
    k.namakaryawan,
    k.departemen,
    k.foto_url AS therapist_photo_url,
    s.room_id,
    s.user_uid,
    s.outlet_rate,
    s.outlet_tags,
    s.outlet_notes,
    s.tr_rate,
    s.tr_tags,
    s.tr_notes,
    s.room_rate,
    s.room_tags,
    s.room_notes,
    s.avg_rate,
    s.is_bad_rating,
    s.as_anonim,
    CASE WHEN s.as_anonim THEN NULL ELSE s.guest_name END AS guest_name,
    CASE WHEN s.as_anonim THEN NULL ELSE s.guest_email END AS guest_email,
    s.language,
    s.submitted_at,
    s.notified_at,
    s.created_at
FROM public.web_guest_rating_submissions s
LEFT JOIN public.master_outlet o ON o.kode_outlet = s.kode_outlet
LEFT JOIN public.ot_hrd_karyawan_info k ON k.kodekaryawan = s.kodekaryawan;

REVOKE ALL ON TABLE public.view_web_guest_rating_summary FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.view_web_guest_rating_summary TO authenticated, service_role;

-- 3. RPC 1: Public Session Lookup (Strict Data Minimization)
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
            k.namakaryawan,
            k.departemen,
            k.foto_url
        INTO v_therapist
        FROM public.ot_hrd_karyawan_info k
        WHERE k.kodekaryawan = v_row.kodekaryawan
        LIMIT 1;
    END IF;

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
            WHEN v_therapist.namakaryawan IS NOT NULL THEN jsonb_build_object(
                'name', v_therapist.namakaryawan,
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

-- 4. RPC 2: Submit Guest Rating (Server-Side Validation & Single-Submission Protection)
CREATE OR REPLACE FUNCTION public.submit_guest_rating(
    p_ratingcode TEXT,
    p_outlet_rate SMALLINT,
    p_tr_rate SMALLINT,
    p_room_rate SMALLINT,
    p_outlet_notes TEXT DEFAULT NULL,
    p_outlet_tags TEXT[] DEFAULT '{}',
    p_tr_notes TEXT DEFAULT NULL,
    p_tr_tags TEXT[] DEFAULT '{}',
    p_room_notes TEXT DEFAULT NULL,
    p_room_tags TEXT[] DEFAULT '{}',
    p_as_anonim BOOLEAN DEFAULT true,
    p_guest_name TEXT DEFAULT NULL,
    p_guest_email TEXT DEFAULT NULL,
    p_language TEXT DEFAULT 'id'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_code TEXT;
    v_row RECORD;
    v_as_anon BOOLEAN;
    v_lang TEXT;
    v_outlet_notes TEXT;
    v_tr_notes TEXT;
    v_room_notes TEXT;
    v_outlet_tags TEXT[];
    v_tr_tags TEXT[];
    v_room_tags TEXT[];
    v_name TEXT;
    v_email TEXT;
    v_sub_uid UUID;
    v_avg_rate NUMERIC(3,2);
    v_is_bad BOOLEAN;
    v_submitted_at TIMESTAMPTZ;
BEGIN
    v_code := NULLIF(btrim(COALESCE(p_ratingcode, '')), '');

    IF v_code IS NULL OR v_code !~ '^[A-Za-z0-9._-]{5,64}$' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_CODE');
    END IF;

    IF p_outlet_rate IS NULL OR p_outlet_rate NOT BETWEEN 1 AND 5
       OR p_tr_rate IS NULL OR p_tr_rate NOT BETWEEN 1 AND 5
       OR p_room_rate IS NULL OR p_room_rate NOT BETWEEN 1 AND 5 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_RATING');
    END IF;

    SELECT
        r.ratingcode,
        r.kode_outlet,
        r.tanggal,
        r.trans_id,
        r.id_payment,
        r.kodekaryawan,
        r.room_id,
        r.user_uid
    INTO v_row
    FROM public.ot_pos_guest_rating r
    WHERE r.ratingcode = v_code
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND');
    END IF;

    v_as_anon := COALESCE(p_as_anonim, true);
    v_lang := CASE WHEN lower(btrim(COALESCE(p_language, 'id'))) = 'en' THEN 'en' ELSE 'id' END;

    v_outlet_notes := NULLIF(left(btrim(regexp_replace(COALESCE(p_outlet_notes, ''), '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g')), 1000), '');
    v_tr_notes     := NULLIF(left(btrim(regexp_replace(COALESCE(p_tr_notes, ''), '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g')), 1000), '');
    v_room_notes   := NULLIF(left(btrim(regexp_replace(COALESCE(p_room_notes, ''), '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g')), 1000), '');

    SELECT COALESCE(array_agg(t_clean), '{}'::TEXT[])
    INTO v_outlet_tags
    FROM (
        SELECT DISTINCT left(btrim(regexp_replace(t, '[\x00-\x1F\x7F]', '', 'g')), 60) AS t_clean
        FROM unnest(COALESCE(p_outlet_tags, '{}'::TEXT[])) AS t
        WHERE NULLIF(btrim(regexp_replace(t, '[\x00-\x1F\x7F]', '', 'g')), '') IS NOT NULL
        LIMIT 10
    ) s_o;

    SELECT COALESCE(array_agg(t_clean), '{}'::TEXT[])
    INTO v_tr_tags
    FROM (
        SELECT DISTINCT left(btrim(regexp_replace(t, '[\x00-\x1F\x7F]', '', 'g')), 60) AS t_clean
        FROM unnest(COALESCE(p_tr_tags, '{}'::TEXT[])) AS t
        WHERE NULLIF(btrim(regexp_replace(t, '[\x00-\x1F\x7F]', '', 'g')), '') IS NOT NULL
        LIMIT 10
    ) s_t;

    SELECT COALESCE(array_agg(t_clean), '{}'::TEXT[])
    INTO v_room_tags
    FROM (
        SELECT DISTINCT left(btrim(regexp_replace(t, '[\x00-\x1F\x7F]', '', 'g')), 60) AS t_clean
        FROM unnest(COALESCE(p_room_tags, '{}'::TEXT[])) AS t
        WHERE NULLIF(btrim(regexp_replace(t, '[\x00-\x1F\x7F]', '', 'g')), '') IS NOT NULL
        LIMIT 10
    ) s_r;

    IF NOT v_as_anon THEN
        v_name := NULLIF(btrim(regexp_replace(COALESCE(p_guest_name, ''), '[\x00-\x1F\x7F]', '', 'g')), '');
        v_email := NULLIF(lower(btrim(COALESCE(p_guest_email, ''))), '');

        IF v_name IS NULL OR char_length(v_name) < 2 OR char_length(v_name) > 120 THEN
            RETURN jsonb_build_object('success', false, 'code', 'INVALID_NAME');
        END IF;

        IF v_email IS NULL OR char_length(v_email) > 150 OR v_email !~ '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$' THEN
            RETURN jsonb_build_object('success', false, 'code', 'INVALID_EMAIL');
        END IF;
    ELSE
        v_name := NULL;
        v_email := NULL;
    END IF;

    BEGIN
        INSERT INTO public.web_guest_rating_submissions (
            ratingcode,
            kode_outlet,
            tanggal,
            trans_id,
            id_payment,
            kodekaryawan,
            room_id,
            user_uid,
            outlet_rate,
            outlet_tags,
            outlet_notes,
            tr_rate,
            tr_tags,
            tr_notes,
            room_rate,
            room_tags,
            room_notes,
            as_anonim,
            guest_name,
            guest_email,
            language
        )
        VALUES (
            v_row.ratingcode,
            v_row.kode_outlet,
            v_row.tanggal,
            v_row.trans_id,
            v_row.id_payment,
            v_row.kodekaryawan,
            v_row.room_id,
            v_row.user_uid,
            p_outlet_rate,
            v_outlet_tags,
            v_outlet_notes,
            p_tr_rate,
            v_tr_tags,
            v_tr_notes,
            p_room_rate,
            v_room_tags,
            v_room_notes,
            v_as_anon,
            v_name,
            v_email,
            v_lang
        )
        RETURNING uid, avg_rate, is_bad_rating, submitted_at
        INTO v_sub_uid, v_avg_rate, v_is_bad, v_submitted_at;
    EXCEPTION
        WHEN unique_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'ALREADY_SUBMITTED');
    END;

    RETURN jsonb_build_object(
        'success', true,
        'submission_uid', v_sub_uid,
        'avg_rate', v_avg_rate,
        'is_bad_rating', v_is_bad,
        'submitted_at', v_submitted_at
    );
END;
$$;

REVOKE ALL ON FUNCTION public.submit_guest_rating(TEXT, SMALLINT, SMALLINT, SMALLINT, TEXT, TEXT[], TEXT, TEXT[], TEXT, TEXT[], BOOLEAN, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_guest_rating(TEXT, SMALLINT, SMALLINT, SMALLINT, TEXT, TEXT[], TEXT, TEXT[], TEXT, TEXT[], BOOLEAN, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;

-- 5. RPC 3: n8n Notification Payload Builder (STRICTLY service_role ONLY)
CREATE OR REPLACE FUNCTION public.get_guest_rating_notification_payload(p_submission_uid UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_sub RECORD;
    v_recipients TEXT[];
    v_recipient_details JSONB;
BEGIN
    SELECT
        s.uid,
        s.ratingcode,
        s.kode_outlet,
        s.tanggal,
        s.trans_id,
        s.id_payment,
        s.kodekaryawan,
        s.room_id,
        s.outlet_rate,
        s.outlet_tags,
        s.outlet_notes,
        s.tr_rate,
        s.tr_tags,
        s.tr_notes,
        s.room_rate,
        s.room_tags,
        s.room_notes,
        s.avg_rate,
        s.is_bad_rating,
        s.as_anonim,
        s.guest_name,
        s.guest_email,
        s.language,
        s.submitted_at,
        COALESCE(o.name_outlet, 'Zen Family Spa') AS outlet_name,
        COALESCE(o.city, 'Indonesia') AS outlet_city,
        COALESCE(k.namakaryawan, s.kodekaryawan, '-') AS therapist_name,
        k.departemen AS therapist_departemen,
        k.foto_url AS therapist_photo_url,
        rm.jenis_jasa AS room_jenis_jasa,
        rm.room_gender AS room_gender,
        rm.keterangan AS room_keterangan
    INTO v_sub
    FROM public.web_guest_rating_submissions s
    LEFT JOIN public.master_outlet o ON o.kode_outlet = s.kode_outlet
    LEFT JOIN public.ot_hrd_karyawan_info k ON k.kodekaryawan = s.kodekaryawan
    LEFT JOIN LATERAL (
        SELECT m.jenis_jasa, m.room_gender, m.keterangan
        FROM public.ot_master_room m
        WHERE m.kode_outlet = s.kode_outlet
          AND (m.room_id = s.room_id OR m.room_id = s.kode_outlet || '.' || s.room_id)
        ORDER BY CASE WHEN m.room_id = s.room_id THEN 0 ELSE 1 END
        LIMIT 1
    ) rm ON true
    WHERE s.uid = p_submission_uid
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('found', false);
    END IF;

    SELECT
        COALESCE(array_agg(DISTINCT me.email) FILTER (WHERE me.email IS NOT NULL), ARRAY[]::TEXT[]),
        COALESCE(
            jsonb_agg(
                DISTINCT jsonb_build_object(
                    'email', me.email,
                    'name', me.name,
                    'scope', CASE WHEN me.kode_outlet IS NULL THEN 'HOLDING' ELSE me.kode_outlet END
                )
            ),
            '[]'::jsonb
        )
    INTO v_recipients, v_recipient_details
    FROM public.master_email me
    WHERE me.active = true
      AND (me.kode_outlet IS NULL OR me.kode_outlet = v_sub.kode_outlet)
      AND (
          (v_sub.is_bad_rating = true AND me.testi_bad = true)
          OR
          (v_sub.is_bad_rating = false AND me.testi_notif = true)
      );

    RETURN jsonb_build_object(
        'found', true,
        'submission_uid', v_sub.uid,
        'ratingcode', v_sub.ratingcode,
        'kode_outlet', v_sub.kode_outlet,
        'outlet_name', v_sub.outlet_name,
        'outlet_city', v_sub.outlet_city,
        'tanggal', v_sub.tanggal,
        'trans_id', v_sub.trans_id,
        'id_payment', v_sub.id_payment,
        'kodekaryawan', v_sub.kodekaryawan,
        'therapist_name', v_sub.therapist_name,
        'therapist_departemen', v_sub.therapist_departemen,
        'therapist_photo_url', v_sub.therapist_photo_url,
        'room_id', v_sub.room_id,
        'room_jenis_jasa', v_sub.room_jenis_jasa,
        'room_gender', v_sub.room_gender,
        'room_keterangan', v_sub.room_keterangan,
        'outlet_rate', v_sub.outlet_rate,
        'outlet_tags', COALESCE(v_sub.outlet_tags, ARRAY[]::TEXT[]),
        'outlet_notes', v_sub.outlet_notes,
        'tr_rate', v_sub.tr_rate,
        'tr_tags', COALESCE(v_sub.tr_tags, ARRAY[]::TEXT[]),
        'tr_notes', v_sub.tr_notes,
        'room_rate', v_sub.room_rate,
        'room_tags', COALESCE(v_sub.room_tags, ARRAY[]::TEXT[]),
        'room_notes', v_sub.room_notes,
        'avg_rate', v_sub.avg_rate,
        'is_bad_rating', v_sub.is_bad_rating,
        'as_anonim', v_sub.as_anonim,
        'guest_name', CASE WHEN v_sub.as_anonim THEN 'Tamu Anonim' ELSE COALESCE(v_sub.guest_name, 'Tamu') END,
        'guest_email', CASE WHEN v_sub.as_anonim THEN NULL ELSE v_sub.guest_email END,
        'language', v_sub.language,
        'submitted_at', v_sub.submitted_at,
        'recipients', COALESCE(v_recipients, ARRAY[]::TEXT[]),
        'recipient_details', COALESCE(v_recipient_details, '[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_guest_rating_notification_payload(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_guest_rating_notification_payload(UUID) TO service_role;

NOTIFY pgrst, 'reload schema';
