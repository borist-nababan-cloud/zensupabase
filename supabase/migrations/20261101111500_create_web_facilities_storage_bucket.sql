-- ==============================================================================
-- Migration: Create Storage Bucket and Policies for web-facilities
-- Description: Sets up public bucket 'web-facilities' for Zen Official Website
--              and WHM App Master Fasilitas photos with 5MB limit.
-- ==============================================================================

-- 1. Create or Update 'web-facilities' Bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'web-facilities',
    'web-facilities',
    true,
    5242880, -- 5 MB limit
    ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 2. Storage RLS Policies for 'web-facilities' Bucket
DO $$
BEGIN
    -- Public read access for anyone (web static, mobile, anon, authenticated)
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Public read access for web-facilities'
    ) THEN
        CREATE POLICY "Public read access for web-facilities"
        ON storage.objects FOR SELECT
        TO public
        USING (bucket_id = 'web-facilities');
    END IF;

    -- Authenticated users can insert/upload facility photos
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can upload web-facilities'
    ) THEN
        CREATE POLICY "Authenticated users can upload web-facilities"
        ON storage.objects FOR INSERT
        TO authenticated
        WITH CHECK (bucket_id = 'web-facilities');
    END IF;

    -- Authenticated users can update facility photos
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can update web-facilities'
    ) THEN
        CREATE POLICY "Authenticated users can update web-facilities"
        ON storage.objects FOR UPDATE
        TO authenticated
        USING (bucket_id = 'web-facilities');
    END IF;

    -- Authenticated users can delete facility photos
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can delete web-facilities'
    ) THEN
        CREATE POLICY "Authenticated users can delete web-facilities"
        ON storage.objects FOR DELETE
        TO authenticated
        USING (bucket_id = 'web-facilities');
    END IF;
END $$;

