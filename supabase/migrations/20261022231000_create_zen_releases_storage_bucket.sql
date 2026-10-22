-- Migration: Create zen-releases Storage Bucket and RLS Policies
-- Supports direct upload and high-speed global CDN downloads for .zip, .apk, and HAVE_DONE.md release assets.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'zen-releases',
    'zen-releases',
    true,
    524288000, -- 500MB max file size
    ARRAY[
        'application/zip',
        'application/x-zip-compressed',
        'application/octet-stream',
        'application/vnd.android.package-archive',
        'text/markdown',
        'text/plain'
    ]
)
ON CONFLICT (id) DO UPDATE SET
    public = true,
    file_size_limit = 524288000,
    allowed_mime_types = ARRAY[
        'application/zip',
        'application/x-zip-compressed',
        'application/octet-stream',
        'application/vnd.android.package-archive',
        'text/markdown',
        'text/plain'
    ];

-- Idempotent RLS Policies on storage.objects for 'zen-releases'
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'Public Read Access on zen-releases'
    ) THEN
        CREATE POLICY "Public Read Access on zen-releases" 
        ON storage.objects FOR SELECT 
        USING (bucket_id = 'zen-releases');
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'Allow Upload to zen-releases'
    ) THEN
        CREATE POLICY "Allow Upload to zen-releases" 
        ON storage.objects FOR INSERT 
        WITH CHECK (bucket_id = 'zen-releases');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'Allow Update to zen-releases'
    ) THEN
        CREATE POLICY "Allow Update to zen-releases" 
        ON storage.objects FOR UPDATE 
        USING (bucket_id = 'zen-releases');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'Allow Delete in zen-releases'
    ) THEN
        CREATE POLICY "Allow Delete in zen-releases" 
        ON storage.objects FOR DELETE 
        USING (bucket_id = 'zen-releases');
    END IF;
END $$;
