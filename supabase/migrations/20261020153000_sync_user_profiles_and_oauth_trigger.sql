-- Migration: Sync User Profiles & Google OAuth Trigger
-- Description: Unifies public.profiles and public.users_profile with avatar_url & role_user (default 12),
--              and registers an automated trigger on auth.users for Google OAuth sign-in sync.

SET ROLE postgres;

-- 1. Ensure master role 12 ('operational_staff') exists in public.role_user
INSERT INTO public.role_user (id, role_name, created_at)
VALUES (12, 'operational_staff', now())
ON CONFLICT (id) DO UPDATE SET
    role_name = EXCLUDED.role_name;

-- 2. Modify public.profiles
-- Drop restrictive role check constraint if present so operational_staff is valid
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;

-- Add avatar_url and role_user columns to public.profiles
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS role_user INT DEFAULT 12;

-- 3. Modify public.users_profile
-- Align columns with public.profiles
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS full_name TEXT;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS role_user INT DEFAULT 12;
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();
ALTER TABLE public.users_profile ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true;

-- Ensure default user_role on users_profile is 12 (operational_staff)
ALTER TABLE public.users_profile ALTER COLUMN user_role SET DEFAULT 12;

-- 4. Create trigger function to automatically synchronize auth.users -> public.profiles & public.users_profile
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
    
    -- Extract full name from Google OAuth metadata with graceful fallback
    v_full_name := COALESCE(
        NULLIF(NEW.raw_user_meta_data->>'full_name', ''),
        NULLIF(NEW.raw_user_meta_data->>'name', ''),
        split_part(v_email, '@', 1)
    );
    
    -- Extract avatar URL from Google OAuth metadata (picture / avatar_url)
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
        true,
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
        kode_outlet,
        created_at,
        updated_at,
        is_active
    ) VALUES (
        NEW.id,
        v_email,
        v_full_name,
        v_avatar_url,
        12,
        12,
        '111',
        now(),
        now(),
        true
    )
    ON CONFLICT (uid) DO UPDATE SET
        full_name = COALESCE(NULLIF(EXCLUDED.full_name, ''), users_profile.full_name),
        avatar_url = COALESCE(NULLIF(EXCLUDED.avatar_url, ''), users_profile.avatar_url),
        email = EXCLUDED.email,
        updated_at = now();

    RETURN NEW;
END;
$$;

-- 5. Attach trigger to auth.users for INSERT and UPDATE of metadata
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

-- 6. Backfill existing records in profiles and users_profile from auth.users if already present
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id, email, raw_user_meta_data FROM auth.users LOOP
        UPDATE public.profiles
        SET 
            full_name = COALESCE(NULLIF(profiles.full_name, ''), NULLIF(r.raw_user_meta_data->>'full_name', ''), NULLIF(r.raw_user_meta_data->>'name', ''), split_part(r.email, '@', 1)),
            avatar_url = COALESCE(NULLIF(profiles.avatar_url, ''), NULLIF(r.raw_user_meta_data->>'avatar_url', ''), NULLIF(r.raw_user_meta_data->>'picture', ''), ''),
            role_user = COALESCE(profiles.role_user, 12)
        WHERE id = r.id::text;

        UPDATE public.users_profile
        SET
            full_name = COALESCE(NULLIF(users_profile.full_name, ''), NULLIF(r.raw_user_meta_data->>'full_name', ''), NULLIF(r.raw_user_meta_data->>'name', ''), split_part(r.email, '@', 1)),
            avatar_url = COALESCE(NULLIF(users_profile.avatar_url, ''), NULLIF(r.raw_user_meta_data->>'avatar_url', ''), NULLIF(r.raw_user_meta_data->>'picture', ''), ''),
            role_user = COALESCE(users_profile.role_user, 12)
        WHERE uid = r.id;
    END LOOP;
END $$;

-- 7. Ensure RLS read permissions for authenticated users
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users_profile ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'profiles' AND policyname = 'Allow authenticated read all profiles'
    ) THEN
        CREATE POLICY "Allow authenticated read all profiles" ON public.profiles FOR SELECT TO authenticated USING (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'users_profile' AND policyname = 'Allow authenticated read all users_profile'
    ) THEN
        CREATE POLICY "Allow authenticated read all users_profile" ON public.users_profile FOR SELECT TO authenticated USING (true);
    END IF;
END $$;
