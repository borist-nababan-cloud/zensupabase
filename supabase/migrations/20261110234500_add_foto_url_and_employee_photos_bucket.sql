-- Migration: Add foto_url to ot_hrd_karyawan_info and setup employee-photos storage bucket
-- Description: Supports employee photo management and status toggling for HR modules

SET ROLE postgres;

-- 1. ADD foto_url COLUMN TO ot_hrd_karyawan_info
ALTER TABLE public.ot_hrd_karyawan_info 
ADD COLUMN IF NOT EXISTS foto_url TEXT;

-- 2. CREATE OR UPDATE STORAGE BUCKET: employee-photos
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'employee-photos',
    'employee-photos',
    true,
    5242880, -- 5 MB limit per image
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/jpg']
)
ON CONFLICT (id) DO UPDATE SET 
    public = true,
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/jpg'];

-- 3. STORAGE RLS POLICIES FOR storage.objects (employee-photos)
-- Allow anyone (public/anon/authenticated) to view employee photos
DROP POLICY IF EXISTS "Public Access for Employee Photos" ON storage.objects;
CREATE POLICY "Public Access for Employee Photos"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'employee-photos');

-- Allow authenticated users to upload employee photos
DROP POLICY IF EXISTS "Authenticated can upload employee photos" ON storage.objects;
CREATE POLICY "Authenticated can upload employee photos"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'employee-photos');

-- Allow authenticated users to update employee photos
DROP POLICY IF EXISTS "Authenticated can update employee photos" ON storage.objects;
CREATE POLICY "Authenticated can update employee photos"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'employee-photos');

-- Allow authenticated users to delete employee photos
DROP POLICY IF EXISTS "Authenticated can delete employee photos" ON storage.objects;
CREATE POLICY "Authenticated can delete employee photos"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'employee-photos');

-- 4. TABLE GRANTS & RLS UPDATE POLICIES FOR ot_hrd_karyawan_info
GRANT SELECT, UPDATE ON TABLE public.ot_hrd_karyawan_info TO authenticated;

DROP POLICY IF EXISTS "Allow authenticated update ot_hrd_karyawan_info" ON public.ot_hrd_karyawan_info;
CREATE POLICY "Allow authenticated update ot_hrd_karyawan_info"
ON public.ot_hrd_karyawan_info FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

