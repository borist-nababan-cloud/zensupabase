-- ==============================================================================
-- MIGRATION: 20261123183000_update_submit_guest_rating_auth_uid_and_web_members.sql
-- Description:
--   Upgrade public.submit_guest_rating() so that when a guest signs in via
--   Google OAuth (non-anonymous):
--     1. Fills web_guest_rating_submissions.user_uid with auth.uid()::TEXT
--        (verified from Supabase JWT, never spoofable by client payload).
--     2. Ensures the authenticated guest is automatically registered/synced
--        in public.web_members (idempotent upsert, safe against email conflicts).
-- ==============================================================================

SET ROLE postgres;

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
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    v_code TEXT;
    v_row RECORD;
    v_auth_uid UUID;
    v_auth_user RECORD;
    v_effective_user_uid TEXT;
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
    v_member_name TEXT;
    v_member_avatar TEXT;
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

    v_auth_uid := auth.uid();
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

        -- If authenticated via Google OAuth, read authoritative identity & ensure web_members record exists
        IF v_auth_uid IS NOT NULL THEN
            SELECT
                u.id,
                u.email,
                u.raw_user_meta_data
            INTO v_auth_user
            FROM auth.users u
            WHERE u.id = v_auth_uid
            LIMIT 1;

            IF FOUND THEN
                v_member_name := COALESCE(
                    NULLIF(btrim(COALESCE(v_auth_user.raw_user_meta_data->>'full_name', '')), ''),
                    NULLIF(btrim(COALESCE(v_auth_user.raw_user_meta_data->>'name', '')), ''),
                    v_name,
                    split_part(COALESCE(v_auth_user.email, ''), '@', 1)
                );
                v_member_avatar := COALESCE(
                    NULLIF(btrim(COALESCE(v_auth_user.raw_user_meta_data->>'avatar_url', '')), ''),
                    NULLIF(btrim(COALESCE(v_auth_user.raw_user_meta_data->>'picture', '')), ''),
                    ''
                );

                v_name := COALESCE(v_name, left(v_member_name, 120));
                v_email := COALESCE(NULLIF(lower(btrim(COALESCE(v_auth_user.email, ''))), ''), v_email);

                IF v_email IS NOT NULL THEN
                    BEGIN
                        INSERT INTO public.web_members (
                            auth_user_id,
                            email,
                            full_name,
                            avatar_url,
                            active,
                            register_date,
                            created_at,
                            update_at
                        )
                        VALUES (
                            v_auth_uid,
                            v_email,
                            left(COALESCE(NULLIF(v_member_name, ''), v_name, 'Zen Member'), 120),
                            v_member_avatar,
                            true,
                            now(),
                            now(),
                            now()
                        )
                        ON CONFLICT (auth_user_id) DO UPDATE SET
                            full_name = COALESCE(NULLIF(public.web_members.full_name, ''), EXCLUDED.full_name),
                            avatar_url = COALESCE(NULLIF(EXCLUDED.avatar_url, ''), public.web_members.avatar_url),
                            update_at = now();
                    EXCEPTION
                        WHEN unique_violation THEN
                            -- Email already exists under a legacy row; bind auth_user_id if empty without failing rating
                            UPDATE public.web_members
                            SET
                                auth_user_id = COALESCE(auth_user_id, v_auth_uid),
                                avatar_url = COALESCE(NULLIF(avatar_url, ''), v_member_avatar),
                                update_at = now()
                            WHERE lower(email) = lower(v_email);
                    END;
                END IF;
            END IF;
        END IF;

        IF v_name IS NULL OR char_length(v_name) < 2 OR char_length(v_name) > 120 THEN
            RETURN jsonb_build_object('success', false, 'code', 'INVALID_NAME');
        END IF;

        IF v_email IS NULL OR char_length(v_email) > 150 OR v_email !~ '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$' THEN
            RETURN jsonb_build_object('success', false, 'code', 'INVALID_EMAIL');
        END IF;

        v_effective_user_uid := COALESCE(v_auth_uid::TEXT, v_row.user_uid);
    ELSE
        v_name := NULL;
        v_email := NULL;
        v_effective_user_uid := v_row.user_uid;
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
            v_effective_user_uid,
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

NOTIFY pgrst, 'reload schema';
