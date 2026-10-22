-- Migration: Enhance User Management RPCs & Role Update
-- File: backend/supabase/supabase/migrations/20261022113500_enhance_user_management_and_roles.sql

-- 1. RPC Function: Get manageable users with ot_hrd_karyawan_info.namakaryawan and master_outlet.name_outlet
CREATE OR REPLACE FUNCTION public.get_manageable_users()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_caller RECORD;
    v_users JSONB;
BEGIN
    -- Check caller permissions
    SELECT uid, role_user, user_role, kode_outlet
    INTO v_caller
    FROM public.users_profile
    WHERE uid = auth.uid();

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Pengguna tidak ditemukan.');
    END IF;

    -- Only Role 8 (SUPERUSER) and Role 6 (outlet_admin) are permitted. Explicitly EXCLUDE Role 1.
    IF COALESCE(v_caller.user_role, v_caller.role_user) NOT IN (6, 8) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Akses ditolak. Anda tidak memiliki wewenang manajemen user.');
    END IF;

    -- Query users based on role scope
    IF COALESCE(v_caller.user_role, v_caller.role_user) = 8 THEN
        -- Role 8: SUPERUSER sees all outlets
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
                'created_at', u.created_at
            ) ORDER BY 
                CASE WHEN u.approval_status = 'PENDING' THEN 1 ELSE 2 END,
                u.created_at DESC
        )
        INTO v_users
        FROM public.users_profile u
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
                'created_at', u.created_at
            ) ORDER BY 
                CASE WHEN u.approval_status = 'PENDING' THEN 1 ELSE 2 END,
                u.created_at DESC
        )
        INTO v_users
        FROM public.users_profile u
        LEFT JOIN public.ot_hrd_karyawan_info k ON UPPER(TRIM(k.kodekaryawan)) = UPPER(TRIM(u.kodekaryawan))
        LEFT JOIN public.master_outlet o ON o.kode_outlet = COALESCE(u.kode_outlet, k.kode_outlet)
        LEFT JOIN public.role_user r ON r.id = COALESCE(u.user_role, u.role_user, 12)
        WHERE COALESCE(u.kode_outlet, k.kode_outlet) = v_caller.kode_outlet;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'caller_role', COALESCE(v_caller.user_role, v_caller.role_user),
        'caller_outlet', v_caller.kode_outlet,
        'users', COALESCE(v_users, '[]'::jsonb)
    );
END;
$$;

-- 2. RPC Function: Approve user access (Role 6 always defaults to Role 12, Role 8 can specify custom role)
CREATE OR REPLACE FUNCTION public.approve_user_access(p_target_uid UUID, p_role_user INT DEFAULT 12)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_caller RECORD;
    v_target RECORD;
    v_assigned_role INT;
BEGIN
    -- Verify caller
    SELECT uid, role_user, user_role, kode_outlet
    INTO v_caller
    FROM public.users_profile
    WHERE uid = auth.uid();

    IF NOT FOUND OR COALESCE(v_caller.user_role, v_caller.role_user) NOT IN (6, 8) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Akses ditolak. Hanya Admin Gerai atau Superuser yang dapat menyetujui user.');
    END IF;

    -- Verify target user
    SELECT uid, kode_outlet, full_name, email
    INTO v_target
    FROM public.users_profile
    WHERE uid = p_target_uid;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Pengguna target tidak ditemukan.');
    END IF;

    -- If caller is Role 6 (outlet_admin):
    -- 1. Enforce same outlet
    -- 2. Force default role 12 (operational_staff). Only Role 8 can change role during pending approval.
    IF COALESCE(v_caller.user_role, v_caller.role_user) = 6 THEN
        IF v_target.kode_outlet IS NULL OR v_target.kode_outlet != v_caller.kode_outlet THEN
            RETURN jsonb_build_object('success', false, 'message', 'Anda hanya dapat menyetujui staf dari gerai Anda sendiri (' || v_caller.kode_outlet || ').');
        END IF;
        v_assigned_role := 12;
    ELSE
        -- Role 8 (SUPERUSER)
        v_assigned_role := COALESCE(p_role_user, 12);
    END IF;

    -- Update users_profile
    UPDATE public.users_profile
    SET
        approval_status = 'APPROVED',
        is_active = true,
        role_user = v_assigned_role,
        user_role = v_assigned_role,
        approved_by = auth.uid(),
        approved_at = now(),
        rejected_reason = NULL,
        updated_at = now()
    WHERE uid = p_target_uid;

    -- Update profiles
    UPDATE public.profiles
    SET
        approval_status = 'APPROVED',
        is_active = true,
        role_user = v_assigned_role,
        approved_by = auth.uid(),
        approved_at = now(),
        rejected_reason = NULL,
        updated_at = now()
    WHERE id = p_target_uid::text;

    RETURN jsonb_build_object('success', true, 'message', 'Pengguna ' || COALESCE(v_target.full_name, v_target.email) || ' berhasil disetujui dengan Role ' || v_assigned_role || '.');
END;
$$;

-- 3. RPC Function: Update user role (Only Role 8 SUPERUSER permitted)
CREATE OR REPLACE FUNCTION public.update_user_role(p_target_uid UUID, p_new_role INT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_caller RECORD;
    v_target RECORD;
    v_role_exists RECORD;
BEGIN
    -- Verify caller: ONLY Role 8 (SUPERUSER) is permitted to edit roles
    SELECT uid, role_user, user_role
    INTO v_caller
    FROM public.users_profile
    WHERE uid = auth.uid();

    IF NOT FOUND OR COALESCE(v_caller.user_role, v_caller.role_user) != 8 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Akses ditolak. Hanya SUPERUSER (Role 8) yang dapat mengubah role pengguna.');
    END IF;

    -- Verify target user
    SELECT uid, full_name, email, approval_status
    INTO v_target
    FROM public.users_profile
    WHERE uid = p_target_uid;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Pengguna target tidak ditemukan.');
    END IF;

    -- Verify role exists in public.role_user
    SELECT id, role_name INTO v_role_exists
    FROM public.role_user
    WHERE id = p_new_role;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Role ID ' || p_new_role || ' tidak valid atau tidak terdaftar di database.');
    END IF;

    -- Update users_profile
    UPDATE public.users_profile
    SET
        user_role = p_new_role,
        role_user = p_new_role,
        updated_at = now()
    WHERE uid = p_target_uid;

    -- Update profiles
    UPDATE public.profiles
    SET
        role_user = p_new_role,
        role = v_role_exists.role_name,
        updated_at = now()
    WHERE id = p_target_uid::text;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Role ' || COALESCE(v_target.full_name, v_target.email) || ' berhasil diubah menjadi: ' || v_role_exists.role_name || ' (Role ' || p_new_role || ').',
        'role_user', p_new_role,
        'role_name', v_role_exists.role_name
    );
END;
$$;

-- 4. Grant execute permissions on newly updated functions
GRANT EXECUTE ON FUNCTION public.get_manageable_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_user_access(UUID, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_role(UUID, INT) TO authenticated;
