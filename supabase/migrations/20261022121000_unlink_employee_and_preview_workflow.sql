-- Migration: Add preview_employee_code and unlink_employee_user RPCs
-- File: backend/supabase/supabase/migrations/20261022121000_unlink_employee_and_preview_workflow.sql

-- 1. RPC Function: Preview employee code before confirming link
CREATE OR REPLACE FUNCTION public.preview_employee_code(p_kodekaryawan TEXT)
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

    -- 1. Search employee in ot_hrd_karyawan_info with master_outlet name
    SELECT 
        k.kodekaryawan,
        k.namakaryawan,
        k.kode_outlet,
        o.name_outlet,
        k.departemen,
        k.active
    INTO v_emp
    FROM public.ot_hrd_karyawan_info k
    LEFT JOIN public.master_outlet o ON o.kode_outlet = k.kode_outlet
    WHERE UPPER(TRIM(k.kodekaryawan)) = UPPER(v_cleaned_code)
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kode Karyawan "' || v_cleaned_code || '" tidak terdaftar di database HRD Zen.');
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

    RETURN jsonb_build_object(
        'success', true,
        'karyawan', jsonb_build_object(
            'kodekaryawan', v_emp.kodekaryawan,
            'namakaryawan', v_emp.namakaryawan,
            'kode_outlet', v_emp.kode_outlet,
            'name_outlet', v_emp.name_outlet,
            'departemen', v_emp.departemen
        )
    );
END;
$$;

-- 2. RPC Function: Unlink employee user (Role 8 SUPERUSER, and Role 6 outlet_admin for own outlet)
CREATE OR REPLACE FUNCTION public.unlink_employee_user(p_target_uid UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_caller RECORD;
    v_target RECORD;
BEGIN
    -- Verify caller
    SELECT uid, role_user, user_role, kode_outlet
    INTO v_caller
    FROM public.users_profile
    WHERE uid = auth.uid();

    IF NOT FOUND OR COALESCE(v_caller.user_role, v_caller.role_user) NOT IN (6, 8) THEN
        RETURN jsonb_build_object('success', false, 'message', 'Akses ditolak. Hanya Admin Gerai atau Superuser yang dapat melepas tautan karyawan.');
    END IF;

    -- Verify target user
    SELECT uid, kode_outlet, full_name, email, kodekaryawan
    INTO v_target
    FROM public.users_profile
    WHERE uid = p_target_uid;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Pengguna target tidak ditemukan.');
    END IF;

    -- If caller is Role 6, enforce same outlet
    IF COALESCE(v_caller.user_role, v_caller.role_user) = 6 THEN
        IF v_target.kode_outlet IS NULL OR v_target.kode_outlet != v_caller.kode_outlet THEN
            RETURN jsonb_build_object('success', false, 'message', 'Anda hanya dapat melepas tautan staf dari gerai Anda sendiri (' || v_caller.kode_outlet || ').');
        END IF;
    END IF;

    -- Update users_profile: Reset back to UNLINKED, clear kodekaryawan and outlet
    UPDATE public.users_profile
    SET
        kodekaryawan = NULL,
        kode_outlet = NULL,
        departemen = NULL,
        approval_status = 'UNLINKED',
        is_active = false,
        approved_by = NULL,
        approved_at = NULL,
        rejected_reason = NULL,
        updated_at = now()
    WHERE uid = p_target_uid;

    -- Update profiles: Reset back to UNLINKED
    UPDATE public.profiles
    SET
        kodekaryawan = NULL,
        departemen = NULL,
        approval_status = 'UNLINKED',
        is_active = false,
        approved_by = NULL,
        approved_at = NULL,
        rejected_reason = NULL,
        updated_at = now()
    WHERE id = p_target_uid::text;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Tautan Kode Karyawan untuk ' || COALESCE(v_target.full_name, v_target.email) || ' berhasil dilepas. Kode karyawan bebas dan pengguna dapat menautkan kode baru.'
    );
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.preview_employee_code(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unlink_employee_user(UUID) TO authenticated;
