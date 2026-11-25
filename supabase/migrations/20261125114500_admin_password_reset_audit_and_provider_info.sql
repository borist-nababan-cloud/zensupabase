-- ============================================================================
-- Migration: Admin Password Reset Audit Log, Session Revocation & Provider Info
-- Date: 2026-11-25
-- Author: Zen Family Spa Architect
-- Description:
--   1. public.whm_password_reset_logs (immutable audit log without plaintext passwords)
--   2. public.admin_revoke_user_sessions(UUID) (service_role-only session revocation)
--   3. Backward-compatible update to public.get_manageable_users() adding
--      optional auth_provider & has_email_auth fields
-- ============================================================================

-- 1. Audit Log Table: whm_password_reset_logs
CREATE TABLE IF NOT EXISTS public.whm_password_reset_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_uid UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    target_email TEXT NOT NULL,
    reset_by_uid UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    reset_by_name TEXT,
    sessions_revoked BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_whm_password_reset_logs_target_created
    ON public.whm_password_reset_logs (target_uid, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_whm_password_reset_logs_created_at
    ON public.whm_password_reset_logs (created_at DESC);

ALTER TABLE public.whm_password_reset_logs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.whm_password_reset_logs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.whm_password_reset_logs TO authenticated;
GRANT ALL ON public.whm_password_reset_logs TO service_role;

DROP POLICY IF EXISTS "Superuser can read password reset logs" ON public.whm_password_reset_logs;
CREATE POLICY "Superuser can read password reset logs"
    ON public.whm_password_reset_logs
    FOR SELECT
    TO authenticated
    USING (public.is_whm_superuser());

DROP POLICY IF EXISTS "Service role full access password reset logs" ON public.whm_password_reset_logs;
CREATE POLICY "Service role full access password reset logs"
    ON public.whm_password_reset_logs
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- 2. Service-role-only RPC: Revoke active user sessions and refresh tokens
CREATE OR REPLACE FUNCTION public.admin_revoke_user_sessions(p_target_uid UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_sessions_deleted INTEGER := 0;
BEGIN
    IF p_target_uid IS NULL THEN
        RETURN 0;
    END IF;

    DELETE FROM auth.sessions
    WHERE user_id = p_target_uid;

    GET DIAGNOSTICS v_sessions_deleted = ROW_COUNT;

    DELETE FROM auth.refresh_tokens
    WHERE user_id = p_target_uid::text;

    RETURN COALESCE(v_sessions_deleted, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_revoke_user_sessions(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_revoke_user_sessions(UUID) TO service_role;

-- 3. Backward-compatible update to get_manageable_users() with auth provider metadata
CREATE OR REPLACE FUNCTION public.get_manageable_users()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_caller RECORD;
    v_users JSONB;
    v_caller_role INT;
BEGIN
    SELECT uid, role_user, user_role, kode_outlet
    INTO v_caller
    FROM public.users_profile
    WHERE uid = auth.uid();

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Pengguna tidak ditemukan.');
    END IF;

    v_caller_role := COALESCE(v_caller.user_role, v_caller.role_user);

    -- Only Role 8 (SUPERUSER), Role 2 (MASTER_HRD), and Role 6 (outlet_admin) are permitted
    IF v_caller_role NOT IN (2, 6, 8) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Akses ditolak. Anda tidak memiliki wewenang manajemen user.');
    END IF;

    IF v_caller_role IN (2, 8) THEN
        -- Role 8 (SUPERUSER) & Role 2 (MASTER_HRD) see all outlets
        SELECT jsonb_agg(
            jsonb_build_object(
                'uid', u.uid,
                'email', u.email,
                'full_name', COALESCE(NULLIF(TRIM(k.namakaryawan), ''), NULLIF(TRIM(u.full_name), ''), u.email),
                'google_name', u.full_name,
                'namakaryawan', k.namakaryawan,
                'avatar_url', u.avatar_url,
                'kodekaryawan', u.kodekaryawan,
                'kode_outlet', COALESCE(u.kode_outlet, k.kode_outlet),
                'name_outlet', o.name_outlet,
                'departemen', COALESCE(u.departemen, k.departemen),
                'role_user', COALESCE(u.user_role, u.role_user, 12),
                'user_role', COALESCE(u.user_role, u.role_user, 12),
                'role_name', r.role_name,
                'approval_status', COALESCE(u.approval_status, 'UNLINKED'),
                'is_active', COALESCE(u.is_active, false),
                'rejected_reason', u.rejected_reason,
                'approved_at', u.approved_at,
                'created_at', u.created_at,
                'auth_provider', COALESCE(NULLIF(au.raw_app_meta_data->>'provider', ''), 'email'),
                'has_email_auth', (
                    EXISTS (
                        SELECT 1
                        FROM auth.identities ai
                        WHERE ai.user_id = u.uid
                          AND ai.provider = 'email'
                    )
                    OR COALESCE(au.raw_app_meta_data->>'provider', '') = 'email'
                    OR (COALESCE(au.raw_app_meta_data->'providers', '[]'::jsonb) ? 'email')
                )
            ) ORDER BY
                CASE WHEN u.approval_status = 'PENDING' THEN 1 ELSE 2 END,
                u.created_at DESC
        )
        INTO v_users
        FROM public.users_profile u
        LEFT JOIN auth.users au ON au.id = u.uid
        LEFT JOIN public.ot_hrd_karyawan_info k ON UPPER(TRIM(k.kodekaryawan)) = UPPER(TRIM(u.kodekaryawan))
        LEFT JOIN public.master_outlet o ON o.kode_outlet = COALESCE(u.kode_outlet, k.kode_outlet)
        LEFT JOIN public.role_user r ON r.id = COALESCE(u.user_role, u.role_user, 12);
    ELSE
        -- Role 6: outlet_admin sees ONLY their own outlet
        SELECT jsonb_agg(
            jsonb_build_object(
                'uid', u.uid,
                'email', u.email,
                'full_name', COALESCE(NULLIF(TRIM(k.namakaryawan), ''), NULLIF(TRIM(u.full_name), ''), u.email),
                'google_name', u.full_name,
                'namakaryawan', k.namakaryawan,
                'avatar_url', u.avatar_url,
                'kodekaryawan', u.kodekaryawan,
                'kode_outlet', COALESCE(u.kode_outlet, k.kode_outlet),
                'name_outlet', o.name_outlet,
                'departemen', COALESCE(u.departemen, k.departemen),
                'role_user', COALESCE(u.user_role, u.role_user, 12),
                'user_role', COALESCE(u.user_role, u.role_user, 12),
                'role_name', r.role_name,
                'approval_status', COALESCE(u.approval_status, 'UNLINKED'),
                'is_active', COALESCE(u.is_active, false),
                'rejected_reason', u.rejected_reason,
                'approved_at', u.approved_at,
                'created_at', u.created_at,
                'auth_provider', COALESCE(NULLIF(au.raw_app_meta_data->>'provider', ''), 'email'),
                'has_email_auth', (
                    EXISTS (
                        SELECT 1
                        FROM auth.identities ai
                        WHERE ai.user_id = u.uid
                          AND ai.provider = 'email'
                    )
                    OR COALESCE(au.raw_app_meta_data->>'provider', '') = 'email'
                    OR (COALESCE(au.raw_app_meta_data->'providers', '[]'::jsonb) ? 'email')
                )
            ) ORDER BY
                CASE WHEN u.approval_status = 'PENDING' THEN 1 ELSE 2 END,
                u.created_at DESC
        )
        INTO v_users
        FROM public.users_profile u
        LEFT JOIN auth.users au ON au.id = u.uid
        LEFT JOIN public.ot_hrd_karyawan_info k ON UPPER(TRIM(k.kodekaryawan)) = UPPER(TRIM(u.kodekaryawan))
        LEFT JOIN public.master_outlet o ON o.kode_outlet = COALESCE(u.kode_outlet, k.kode_outlet)
        LEFT JOIN public.role_user r ON r.id = COALESCE(u.user_role, u.role_user, 12)
        WHERE COALESCE(u.kode_outlet, k.kode_outlet) = v_caller.kode_outlet;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'caller_role', v_caller_role,
        'caller_outlet', v_caller.kode_outlet,
        'users', COALESCE(v_users, '[]'::jsonb)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_manageable_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_manageable_users() TO authenticated;

NOTIFY pgrst, 'reload schema';
