-- Migration: User Verification & Approval Workflow
-- Description: Links auth.users to ot_hrd_karyawan_info via kodekaryawan,
--              establishes UNLINKED -> PENDING -> APPROVED lifecycle,
--              and provides secure RPC functions for outlet_admin (Role 6) and SUPERUSER (Role 8).

SET ROLE postgres;

-- 1. Ensure master role 12 ('operational_staff') exists in public.role_user
INSERT INTO public.role_user (id, role_name, created_at)
VALUES (12, 'operational_staff', now())
ON CONFLICT (id) DO UPDATE SET role_name = EXCLUDED.role_name;

-- 2. Modify public.profiles
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS role_user INT DEFAULT 12;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS kodekaryawan TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS approval_status TEXT DEFAULT 'UNLINKED';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS approved_by UUID;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS rejected_reason TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS departemen TEXT;

-- 3. Modify public.users_profile
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS full_name TEXT;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS role_user INT DEFAULT 12;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS kodekaryawan TEXT;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS approval_status TEXT DEFAULT 'UNLINKED';
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS approved_by UUID;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS rejected_reason TEXT;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS departemen TEXT;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT false;

-- Ensure default user_role on users_profile is 12
ALTER TABLE public.users_profile ALTER COLUMN user_role SET DEFAULT 12;

-- 4. Trigger function to automatically register Google OAuth users into profiles & users_profile
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_full_name TEXT;
    v_avatar_url TEXT;
    v_email TEXT;
BEGIN
    v_email := NEW.email;
    
    -- Extract full name from Google OAuth metadata
    v_full_name := COALESCE(
        NULLIF(NEW.raw_user_meta_data->>'full_name', ''),
        NULLIF(NEW.raw_user_meta_data->>'name', ''),
        split_part(v_email, '@', 1)
    );
    
    -- Extract avatar URL from Google OAuth metadata
    v_avatar_url := COALESCE(
        NULLIF(NEW.raw_user_meta_data->>'avatar_url', ''),
        NULLIF(NEW.raw_user_meta_data->>'picture', ''),
        ''
    );

    -- 4a. Sync to public.profiles
    INSERT INTO public.profiles (
        id,
        email,
        full_name,
        avatar_url,
        role,
        role_user,
        approval_status,
        is_active,
        created_at,
        updated_at
    ) VALUES (
        NEW.id::text,
        v_email,
        v_full_name,
        v_avatar_url,
        'operational_staff',
        12,
        'UNLINKED',
        false,
        now(),
        now()
    )
    ON CONFLICT (id) DO UPDATE SET
        full_name = COALESCE(NULLIF(EXCLUDED.full_name, ''), profiles.full_name),
        avatar_url = COALESCE(NULLIF(EXCLUDED.avatar_url, ''), profiles.avatar_url),
        email = EXCLUDED.email,
        updated_at = now();

    -- 4b. Sync to public.users_profile
    INSERT INTO public.users_profile (
        uid,
        email,
        full_name,
        avatar_url,
        user_role,
        role_user,
        approval_status,
        is_active,
        created_at,
        updated_at
    ) VALUES (
        NEW.id,
        v_email,
        v_full_name,
        v_avatar_url,
        12,
        12,
        'UNLINKED',
        false,
        now(),
        now()
    )
    ON CONFLICT (uid) DO UPDATE SET
        full_name = COALESCE(NULLIF(EXCLUDED.full_name, ''), users_profile.full_name),
        avatar_url = COALESCE(NULLIF(EXCLUDED.avatar_url, ''), users_profile.avatar_url),
        email = EXCLUDED.email,
        updated_at = now();

    RETURN NEW;
END;
$$;

-- 5. Attach triggers to auth.users
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

DROP TRIGGER IF EXISTS on_auth_user_updated ON auth.users;
CREATE TRIGGER on_auth_user_updated
    AFTER UPDATE OF raw_user_meta_data, email ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

-- 6. Backfill existing users in auth.users into profiles and users_profile
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id, email, raw_user_meta_data FROM auth.users LOOP
        INSERT INTO public.profiles (
            id, email, full_name, avatar_url, role, role_user, approval_status, is_active, created_at, updated_at
        ) VALUES (
            r.id::text,
            r.email,
            COALESCE(NULLIF(r.raw_user_meta_data->>'full_name', ''), NULLIF(r.raw_user_meta_data->>'name', ''), split_part(r.email, '@', 1)),
            COALESCE(NULLIF(r.raw_user_meta_data->>'avatar_url', ''), NULLIF(r.raw_user_meta_data->>'picture', ''), ''),
            'operational_staff',
            12,
            'UNLINKED',
            false,
            now(),
            now()
        )
        ON CONFLICT (id) DO UPDATE SET
            full_name = COALESCE(NULLIF(EXCLUDED.full_name, ''), profiles.full_name),
            avatar_url = COALESCE(NULLIF(EXCLUDED.avatar_url, ''), profiles.avatar_url),
            email = EXCLUDED.email;

        INSERT INTO public.users_profile (
            uid, email, full_name, avatar_url, user_role, role_user, approval_status, is_active, created_at, updated_at
        ) VALUES (
            r.id,
            r.email,
            COALESCE(NULLIF(r.raw_user_meta_data->>'full_name', ''), NULLIF(r.raw_user_meta_data->>'name', ''), split_part(r.email, '@', 1)),
            COALESCE(NULLIF(r.raw_user_meta_data->>'avatar_url', ''), NULLIF(r.raw_user_meta_data->>'picture', ''), ''),
            12,
            12,
            'UNLINKED',
            false,
            now(),
            now()
        )
        ON CONFLICT (uid) DO UPDATE SET
            full_name = COALESCE(NULLIF(EXCLUDED.full_name, ''), users_profile.full_name),
            avatar_url = COALESCE(NULLIF(EXCLUDED.avatar_url, ''), users_profile.avatar_url),
            email = EXCLUDED.email;
    END LOOP;
END $$;

-- 7. RPC Function: Link employee code (ot_hrd_karyawan_info.kodekaryawan)
CREATE OR REPLACE FUNCTION public.link_employee_code(p_kodekaryawan TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid UUID;
    v_cleaned_code TEXT;
    v_emp RECORD;
    v_claimed RECORD;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Sesi tidak valid. Silakan login kembali.');
    END IF;

    v_cleaned_code := TRIM(p_kodekaryawan);
    IF v_cleaned_code IS NULL OR v_cleaned_code = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kode Karyawan tidak boleh kosong.');
    END IF;

    -- 1. Search employee in ot_hrd_karyawan_info
    SELECT kodekaryawan, namakaryawan, kode_outlet, departemen, active
    INTO v_emp
    FROM public.ot_hrd_karyawan_info
    WHERE UPPER(TRIM(kodekaryawan)) = UPPER(v_cleaned_code)
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kode Karyawan "' || v_cleaned_code || '" tidak terdaftar di database HRD.');
    END IF;

    -- 2. Verify active status in HRD ('Y' or 'true' or '1')
    IF v_emp.active IS NULL OR (v_emp.active != 'Y' AND v_emp.active != 'true' AND v_emp.active != '1') THEN
        RETURN jsonb_build_object('success', false, 'message', 'Karyawan (' || v_emp.namakaryawan || ') berstatus TIDAK AKTIF di HRD. Hubungi Admin Outlet / HRD.');
    END IF;

    -- 3. Check if kodekaryawan is already linked to another active or pending account
    SELECT uid, email INTO v_claimed
    FROM public.users_profile
    WHERE UPPER(TRIM(kodekaryawan)) = UPPER(v_emp.kodekaryawan)
      AND uid != v_uid
      AND approval_status IN ('APPROVED', 'PENDING')
    LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kode Karyawan "' || v_emp.kodekaryawan || '" sudah digunakan oleh akun lain (' || v_claimed.email || ').');
    END IF;

    -- 4. Update users_profile
    UPDATE public.users_profile
    SET
        kodekaryawan = v_emp.kodekaryawan,
        kode_outlet = v_emp.kode_outlet,
        departemen = v_emp.departemen,
        full_name = COALESCE(NULLIF(users_profile.full_name, ''), v_emp.namakaryawan),
        approval_status = 'PENDING',
        is_active = false,
        rejected_reason = NULL,
        updated_at = now()
    WHERE uid = v_uid;

    -- 5. Update profiles
    UPDATE public.profiles
    SET
        kodekaryawan = v_emp.kodekaryawan,
        departemen = v_emp.departemen,
        full_name = COALESCE(NULLIF(profiles.full_name, ''), v_emp.namakaryawan),
        approval_status = 'PENDING',
        is_active = false,
        rejected_reason = NULL,
        updated_at = now()
    WHERE id = v_uid::text;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Kode Karyawan berhasil diverifikasi! Permintaan akses Anda sedang menunggu persetujuan admin gerai.',
        'karyawan', jsonb_build_object(
            'kodekaryawan', v_emp.kodekaryawan,
            'namakaryawan', v_emp.namakaryawan,
            'kode_outlet', v_emp.kode_outlet,
            'departemen', v_emp.departemen
        )
    );
END;
$$;

-- 8. RPC Function: Get manageable users (Role 6 outlet_admin sees own outlet, Role 8 SUPERUSER sees all)
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

    -- Only Role 8 (SUPERUSER) and Role 6 (outlet_admin) are permitted
    IF COALESCE(v_caller.role_user, v_caller.user_role) NOT IN (6, 8) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Akses ditolak. Anda tidak memiliki wewenang manajemen user.');
    END IF;

    -- Query users based on role scope
    IF COALESCE(v_caller.role_user, v_caller.user_role) = 8 THEN
        -- Role 8: SUPERUSER sees all outlets
        SELECT jsonb_agg(
            jsonb_build_object(
                'uid', u.uid,
                'email', u.email,
                'full_name', u.full_name,
                'avatar_url', u.avatar_url,
                'kodekaryawan', u.kodekaryawan,
                'kode_outlet', u.kode_outlet,
                'departemen', u.departemen,
                'role_user', COALESCE(u.role_user, u.user_role, 12),
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
        LEFT JOIN public.role_user r ON r.id = COALESCE(u.role_user, u.user_role);
    ELSE
        -- Role 6: outlet_admin sees ONLY their own outlet
        SELECT jsonb_agg(
            jsonb_build_object(
                'uid', u.uid,
                'email', u.email,
                'full_name', u.full_name,
                'avatar_url', u.avatar_url,
                'kodekaryawan', u.kodekaryawan,
                'kode_outlet', u.kode_outlet,
                'departemen', u.departemen,
                'role_user', COALESCE(u.role_user, u.user_role, 12),
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
        LEFT JOIN public.role_user r ON r.id = COALESCE(u.role_user, u.user_role)
        WHERE u.kode_outlet = v_caller.kode_outlet;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'caller_role', COALESCE(v_caller.role_user, v_caller.user_role),
        'caller_outlet', v_caller.kode_outlet,
        'users', COALESCE(v_users, '[]'::jsonb)
    );
END;
$$;

-- 9. RPC Function: Approve user access
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

    IF NOT FOUND OR COALESCE(v_caller.role_user, v_caller.user_role) NOT IN (6, 8) THEN
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

    -- If caller is Role 6 (outlet_admin), enforce same outlet
    IF COALESCE(v_caller.role_user, v_caller.user_role) = 6 THEN
        IF v_target.kode_outlet IS NULL OR v_target.kode_outlet != v_caller.kode_outlet THEN
            RETURN jsonb_build_object('success', false, 'message', 'Anda hanya dapat menyetujui staf dari gerai Anda sendiri (' || v_caller.kode_outlet || ').');
        END IF;
    END IF;

    v_assigned_role := COALESCE(p_role_user, 12);

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

    RETURN jsonb_build_object('success', true, 'message', 'Pengguna ' || COALESCE(v_target.full_name, v_target.email) || ' berhasil disetujui dan diaktifkan.');
END;
$$;

-- 10. RPC Function: Reject user access
CREATE OR REPLACE FUNCTION public.reject_user_access(p_target_uid UUID, p_reason TEXT DEFAULT 'Permintaan akses ditolak oleh admin.')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_caller RECORD;
    v_target RECORD;
BEGIN
    SELECT uid, role_user, user_role, kode_outlet
    INTO v_caller
    FROM public.users_profile
    WHERE uid = auth.uid();

    IF NOT FOUND OR COALESCE(v_caller.role_user, v_caller.user_role) NOT IN (6, 8) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Akses ditolak.');
    END IF;

    SELECT uid, kode_outlet, full_name, email
    INTO v_target
    FROM public.users_profile
    WHERE uid = p_target_uid;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Pengguna target tidak ditemukan.');
    END IF;

    -- If caller is Role 6, enforce same outlet
    IF COALESCE(v_caller.role_user, v_caller.user_role) = 6 THEN
        IF v_target.kode_outlet IS NULL OR v_target.kode_outlet != v_caller.kode_outlet THEN
            RETURN jsonb_build_object('success', false, 'message', 'Anda hanya dapat menolak staf dari gerai Anda sendiri.');
        END IF;
    END IF;

    -- Update users_profile
    UPDATE public.users_profile
    SET
        approval_status = 'REJECTED',
        is_active = false,
        rejected_reason = COALESCE(p_reason, 'Ditolak oleh admin gerai.'),
        updated_at = now()
    WHERE uid = p_target_uid;

    -- Update profiles
    UPDATE public.profiles
    SET
        approval_status = 'REJECTED',
        is_active = false,
        rejected_reason = COALESCE(p_reason, 'Ditolak oleh admin gerai.'),
        updated_at = now()
    WHERE id = p_target_uid::text;

    RETURN jsonb_build_object('success', true, 'message', 'Permintaan pengguna ' || COALESCE(v_target.full_name, v_target.email) || ' telah ditolak.');
END;
$$;

-- 11. RPC Function: Toggle user active status
CREATE OR REPLACE FUNCTION public.toggle_user_status(p_target_uid UUID, p_is_active BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_caller RECORD;
    v_target RECORD;
BEGIN
    SELECT uid, role_user, user_role, kode_outlet
    INTO v_caller
    FROM public.users_profile
    WHERE uid = auth.uid();

    IF NOT FOUND OR COALESCE(v_caller.role_user, v_caller.user_role) NOT IN (6, 8) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Akses ditolak.');
    END IF;

    SELECT uid, kode_outlet, full_name, email
    INTO v_target
    FROM public.users_profile
    WHERE uid = p_target_uid;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Pengguna target tidak ditemukan.');
    END IF;

    IF COALESCE(v_caller.role_user, v_caller.user_role) = 6 THEN
        IF v_target.kode_outlet IS NULL OR v_target.kode_outlet != v_caller.kode_outlet THEN
            RETURN jsonb_build_object('success', false, 'message', 'Anda hanya dapat mengubah status staf dari gerai Anda sendiri.');
        END IF;
    END IF;

    UPDATE public.users_profile
    SET
        is_active = p_is_active,
        updated_at = now()
    WHERE uid = p_target_uid;

    UPDATE public.profiles
    SET
        is_active = p_is_active,
        updated_at = now()
    WHERE id = p_target_uid::text;

    RETURN jsonb_build_object('success', true, 'message', 'Status pengguna berhasil diperbarui.');
END;
$$;

-- 12. Security Grants & RLS Policies
GRANT EXECUTE ON FUNCTION public.link_employee_code(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_manageable_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_user_access(UUID, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_user_access(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_user_status(UUID, BOOLEAN) TO authenticated;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users_profile ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'profiles' AND policyname = 'Allow authenticated read profiles'
    ) THEN
        CREATE POLICY "Allow authenticated read profiles" ON public.profiles FOR SELECT TO authenticated USING (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'users_profile' AND policyname = 'Allow authenticated read users_profile'
    ) THEN
        CREATE POLICY "Allow authenticated read users_profile" ON public.users_profile FOR SELECT TO authenticated USING (true);
    END IF;
END $$;
