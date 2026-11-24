-- ==============================================================================
-- Migration: Create web_galleries Table and Storage Bucket 'web-gallery'
-- Description: Creates official table for Zen Website Gallery items with 
--              active flag, category, and public storage bucket.
-- ==============================================================================

-- 1. Create table public.web_galleries
CREATE TABLE IF NOT EXISTS public.web_galleries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    description TEXT,
    category TEXT DEFAULT 'Suasana & Interior',
    image_url TEXT NOT NULL,
    kode_outlet TEXT,
    active BOOLEAN NOT NULL DEFAULT true,
    sort_order INTEGER NOT NULL DEFAULT 10,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by TEXT,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by TEXT
);

-- Indexing for fast queries and sorting
CREATE INDEX IF NOT EXISTS idx_web_galleries_active ON public.web_galleries(active);
CREATE INDEX IF NOT EXISTS idx_web_galleries_sort ON public.web_galleries(sort_order);
CREATE INDEX IF NOT EXISTS idx_web_galleries_category ON public.web_galleries(category);

-- Enable RLS
ALTER TABLE public.web_galleries ENABLE ROW LEVEL SECURITY;

-- 2. RLS Policies on web_galleries
DROP POLICY IF EXISTS "Public can view active web_galleries" ON public.web_galleries;
CREATE POLICY "Public can view active web_galleries"
ON public.web_galleries FOR SELECT
TO public
USING (active = true);

DROP POLICY IF EXISTS "Authenticated can view all web_galleries" ON public.web_galleries;
CREATE POLICY "Authenticated can view all web_galleries"
ON public.web_galleries FOR SELECT
TO authenticated
USING (true);

DROP POLICY IF EXISTS "Authenticated can insert web_galleries" ON public.web_galleries;
CREATE POLICY "Authenticated can insert web_galleries"
ON public.web_galleries FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated can update web_galleries" ON public.web_galleries;
CREATE POLICY "Authenticated can update web_galleries"
ON public.web_galleries FOR UPDATE
TO authenticated
USING (true);

DROP POLICY IF EXISTS "Authenticated can delete web_galleries" ON public.web_galleries;
CREATE POLICY "Authenticated can delete web_galleries"
ON public.web_galleries FOR DELETE
TO authenticated
USING (true);

-- 3. Create or Update Storage Bucket 'web-gallery'
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'web-gallery',
    'web-gallery',
    true,
    5242880, -- 5 MB limit
    ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 4. Storage RLS Policies for 'web-gallery'
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Public read access for web-gallery'
    ) THEN
        CREATE POLICY "Public read access for web-gallery"
        ON storage.objects FOR SELECT
        TO public
        USING (bucket_id = 'web-gallery');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can upload web-gallery'
    ) THEN
        CREATE POLICY "Authenticated users can upload web-gallery"
        ON storage.objects FOR INSERT
        TO authenticated
        WITH CHECK (bucket_id = 'web-gallery');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can update web-gallery'
    ) THEN
        CREATE POLICY "Authenticated users can update web-gallery"
        ON storage.objects FOR UPDATE
        TO authenticated
        USING (bucket_id = 'web-gallery');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can delete web-gallery'
    ) THEN
        CREATE POLICY "Authenticated users can delete web-gallery"
        ON storage.objects FOR DELETE
        TO authenticated
        USING (bucket_id = 'web-gallery');
    END IF;
END $$;

