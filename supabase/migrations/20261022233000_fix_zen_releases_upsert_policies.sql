-- Migration: Fix RLS policies on storage.objects for 'zen-releases' to support upsert (insert & update)
-- Required by Supabase Storage when upsert: true is used by client uploads.

-- 1. SELECT policy: required by PostgreSQL and Supabase Storage to check existing objects during upsert
DROP POLICY IF EXISTS "Allow Select in zen-releases" ON storage.objects;
DROP POLICY IF EXISTS "Public Read Access on zen-releases" ON storage.objects;
CREATE POLICY "Allow Select in zen-releases"
ON storage.objects FOR SELECT
USING (bucket_id = 'zen-releases');

-- 2. INSERT policy: ensure WITH CHECK is present
DROP POLICY IF EXISTS "Allow Upload to zen-releases" ON storage.objects;
CREATE POLICY "Allow Upload to zen-releases"
ON storage.objects FOR INSERT
WITH CHECK (bucket_id = 'zen-releases');

-- 3. UPDATE policy: must have BOTH USING and WITH CHECK for upsert overwrite
DROP POLICY IF EXISTS "Allow Update to zen-releases" ON storage.objects;
CREATE POLICY "Allow Update to zen-releases"
ON storage.objects FOR UPDATE
USING (bucket_id = 'zen-releases')
WITH CHECK (bucket_id = 'zen-releases');

-- 4. DELETE policy
DROP POLICY IF EXISTS "Allow Delete in zen-releases" ON storage.objects;
CREATE POLICY "Allow Delete in zen-releases"
ON storage.objects FOR DELETE
USING (bucket_id = 'zen-releases');
