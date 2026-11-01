-- ==============================================================================
-- Migration: Create web_members, web_testimonials, and Storage Bucket 'web-testimonials'
-- Description: Supports Google OAuth customer membership separate from internal staff (users_profile),
--              and user testimonials with 5 smile rating and moderation in WHM.
-- ==============================================================================

-- 1. Create table public.web_members
CREATE TABLE IF NOT EXISTS public.web_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT UNIQUE NOT NULL,
    full_name TEXT NOT NULL,
    avatar_url TEXT,
    phone_wa TEXT,
    fixline TEXT,
    shipping_address TEXT,
    city TEXT,
    province TEXT,
    zip_code TEXT,
    birth_date DATE,
    active BOOLEAN NOT NULL DEFAULT true,
    pin_setup BOOLEAN NOT NULL DEFAULT false,
    phone_otentication BOOLEAN NOT NULL DEFAULT false,
    register_date TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_web_members_auth_user ON public.web_members(auth_user_id);
CREATE INDEX IF NOT EXISTS idx_web_members_email ON public.web_members(email);
CREATE INDEX IF NOT EXISTS idx_web_members_active ON public.web_members(active);

-- Enable RLS on web_members
ALTER TABLE public.web_members ENABLE ROW LEVEL SECURITY;

-- RLS Policies on web_members
DROP POLICY IF EXISTS "Public can view active web_members summary" ON public.web_members;
CREATE POLICY "Public can view active web_members summary"
ON public.web_members FOR SELECT
TO public
USING (active = true);

DROP POLICY IF EXISTS "Users can view own member profile" ON public.web_members;
CREATE POLICY "Users can view own member profile"
ON public.web_members FOR SELECT
TO authenticated
USING (auth.uid() = auth_user_id);

DROP POLICY IF EXISTS "Users can insert own member profile" ON public.web_members;
CREATE POLICY "Users can insert own member profile"
ON public.web_members FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = auth_user_id);

DROP POLICY IF EXISTS "Users can update own member profile" ON public.web_members;
CREATE POLICY "Users can update own member profile"
ON public.web_members FOR UPDATE
TO authenticated
USING (auth.uid() = auth_user_id);

DROP POLICY IF EXISTS "Authenticated staff can manage all web_members" ON public.web_members;
CREATE POLICY "Authenticated staff can manage all web_members"
ON public.web_members FOR ALL
TO authenticated
USING (true)
WITH CHECK (true);


-- 2. Trigger function to auto-sync Google OAuth sign-ins into web_members
CREATE OR REPLACE FUNCTION public.handle_new_web_member()
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

    -- Insert into web_members if not exists (never overwriting existing phone/address)
    INSERT INTO public.web_members (
        auth_user_id,
        email,
        full_name,
        avatar_url,
        active,
        register_date,
        created_at,
        update_at
    ) VALUES (
        NEW.id,
        v_email,
        v_full_name,
        v_avatar_url,
        true,
        now(),
        now(),
        now()
    )
    ON CONFLICT (auth_user_id) DO UPDATE SET
        full_name = COALESCE(NULLIF(web_members.full_name, ''), EXCLUDED.full_name),
        avatar_url = COALESCE(NULLIF(EXCLUDED.avatar_url, ''), web_members.avatar_url),
        update_at = now();

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created_web_member ON auth.users;
CREATE TRIGGER on_auth_user_created_web_member
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_web_member();


-- 3. Create table public.web_testimonials
CREATE TABLE IF NOT EXISTS public.web_testimonials (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    member_id UUID REFERENCES public.web_members(id) ON DELETE SET NULL,
    customer_name TEXT NOT NULL,
    customer_avatar TEXT,
    kode_outlet TEXT REFERENCES public.master_outlet(kode_outlet) ON DELETE SET NULL,
    rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
    comment TEXT NOT NULL,
    photo_url TEXT,
    published BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_web_testimonials_published ON public.web_testimonials(published);
CREATE INDEX IF NOT EXISTS idx_web_testimonials_created_at ON public.web_testimonials(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_web_testimonials_outlet ON public.web_testimonials(kode_outlet);

-- Enable RLS on web_testimonials
ALTER TABLE public.web_testimonials ENABLE ROW LEVEL SECURITY;

-- RLS Policies on web_testimonials
DROP POLICY IF EXISTS "Public can view published testimonials" ON public.web_testimonials;
CREATE POLICY "Public can view published testimonials"
ON public.web_testimonials FOR SELECT
TO public
USING (published = true);

DROP POLICY IF EXISTS "Authenticated users can submit own testimonial" ON public.web_testimonials;
CREATE POLICY "Authenticated users can submit own testimonial"
ON public.web_testimonials FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = auth_user_id);

DROP POLICY IF EXISTS "Users can view own testimonials" ON public.web_testimonials;
CREATE POLICY "Users can view own testimonials"
ON public.web_testimonials FOR SELECT
TO authenticated
USING (auth.uid() = auth_user_id);

DROP POLICY IF EXISTS "Authenticated staff can manage all testimonials" ON public.web_testimonials;
CREATE POLICY "Authenticated staff can manage all testimonials"
ON public.web_testimonials FOR ALL
TO authenticated
USING (true)
WITH CHECK (true);


-- 4. Create or Update Storage Bucket 'web-testimonials'
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'web-testimonials',
    'web-testimonials',
    true,
    5242880, -- 5 MB limit
    ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 5. Storage RLS Policies for 'web-testimonials' Bucket
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Public read access for web-testimonials'
    ) THEN
        CREATE POLICY "Public read access for web-testimonials"
        ON storage.objects FOR SELECT
        TO public
        USING (bucket_id = 'web-testimonials');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can upload web-testimonials'
    ) THEN
        CREATE POLICY "Authenticated users can upload web-testimonials"
        ON storage.objects FOR INSERT
        TO authenticated
        WITH CHECK (bucket_id = 'web-testimonials');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can update web-testimonials'
    ) THEN
        CREATE POLICY "Authenticated users can update web-testimonials"
        ON storage.objects FOR UPDATE
        TO authenticated
        USING (bucket_id = 'web-testimonials');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can delete web-testimonials'
    ) THEN
        CREATE POLICY "Authenticated users can delete web-testimonials"
        ON storage.objects FOR DELETE
        TO authenticated
        USING (bucket_id = 'web-testimonials');
    END IF;
END $$;

