-- ==============================================================================
-- MIGRATION: 20261027094500_add_is_laundry_and_product_images_bucket.sql
-- Description:
-- 1. Add is_laundry boolean flag to public.master_barang.
-- 2. Add image2_url text to public.master_barang and copy from legacy iamge2_url.
-- 3. Create public storage bucket 'product-images' for product catalog photos.
-- 4. Configure storage RLS policies for product-images (public read, authenticated write).
-- ==============================================================================

-- 1. ADD is_laundry COLUMN
ALTER TABLE public.master_barang 
ADD COLUMN IF NOT EXISTS is_laundry BOOLEAN DEFAULT false NOT NULL;

-- 2. ADD image2_url COLUMN AND SYNC LEGACY iamge2_url
ALTER TABLE public.master_barang 
ADD COLUMN IF NOT EXISTS image2_url TEXT;

UPDATE public.master_barang 
SET image2_url = iamge2_url 
WHERE image2_url IS NULL AND iamge2_url IS NOT NULL;

-- 3. CREATE STORAGE BUCKET FOR PRODUCT IMAGES
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'product-images',
    'product-images',
    true,
    5242880, -- 5 MB limit per image
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO UPDATE SET 
    public = true,
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

-- 4. STORAGE RLS POLICIES FOR storage.objects
-- storage.objects already has RLS enabled by Supabase by default
-- ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- Allow anyone (public/anon/authenticated) to view product images
DROP POLICY IF EXISTS "Public Access for Product Images" ON storage.objects;
CREATE POLICY "Public Access for Product Images"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'product-images');

-- Allow authenticated users to upload product images
DROP POLICY IF EXISTS "Authenticated can upload product images" ON storage.objects;
CREATE POLICY "Authenticated can upload product images"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'product-images');

-- Allow authenticated users to update product images
DROP POLICY IF EXISTS "Authenticated can update product images" ON storage.objects;
CREATE POLICY "Authenticated can update product images"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'product-images');

-- Allow authenticated users to delete product images
DROP POLICY IF EXISTS "Authenticated can delete product images" ON storage.objects;
CREATE POLICY "Authenticated can delete product images"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'product-images');
