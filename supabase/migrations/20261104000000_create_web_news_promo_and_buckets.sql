-- ==============================================================================
-- MIGRATION: 20261104000000_create_web_news_promo_and_buckets.sql
-- Description:
-- 1. Create table public.web_news_promo for marketing, announcements & promotional carousel.
-- 2. Configure RLS policies (public read-only for active items, authenticated full CRUD for WHM).
-- 3. Create public storage bucket 'web-news-promo' with 5MB limit and RLS policies.
-- 4. Create/ensure public storage bucket 'product-images' with 5MB limit and RLS policies.
-- ==============================================================================

-- 1. CREATE TABLE web_news_promo
CREATE TABLE IF NOT EXISTS public.web_news_promo (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    title_en TEXT,
    subtitle TEXT,
    subtitle_en TEXT,
    description TEXT,
    description_en TEXT,
    image_url TEXT NOT NULL,
    badge_text TEXT DEFAULT 'PROMO',
    cta_url TEXT,
    start_date DATE,
    end_date DATE,
    sort_order INT DEFAULT 0 NOT NULL,
    active BOOLEAN DEFAULT true NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    created_by UUID,
    updated_by UUID
);

-- Trigger for auto-updating updated_at
CREATE OR REPLACE FUNCTION public.fn_update_web_news_promo_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_web_news_promo_updated_at ON public.web_news_promo;
CREATE TRIGGER trg_web_news_promo_updated_at
BEFORE UPDATE ON public.web_news_promo
FOR EACH ROW
EXECUTE FUNCTION public.fn_update_web_news_promo_timestamp();

-- Index for high-performance carousel retrieval
CREATE INDEX IF NOT EXISTS idx_web_news_promo_active_sort 
ON public.web_news_promo(active, sort_order, created_at DESC);

-- 2. ROW LEVEL SECURITY (RLS) POLICIES
ALTER TABLE public.web_news_promo ENABLE ROW LEVEL SECURITY;

-- Allow public read for active news and promo
DROP POLICY IF EXISTS "Public can view active news promo" ON public.web_news_promo;
CREATE POLICY "Public can view active news promo"
ON public.web_news_promo FOR SELECT
TO public
USING (active = true);

-- Allow authenticated users full CRUD (WHM Admin)
DROP POLICY IF EXISTS "Authenticated users have full access to news promo" ON public.web_news_promo;
CREATE POLICY "Authenticated users have full access to news promo"
ON public.web_news_promo FOR ALL
TO authenticated
USING (true)
WITH CHECK (true);

-- Allow service_role full access
DROP POLICY IF EXISTS "Service role has full access to news promo" ON public.web_news_promo;
CREATE POLICY "Service role has full access to news promo"
ON public.web_news_promo FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

-- Grants
GRANT SELECT ON public.web_news_promo TO anon;
GRANT ALL ON public.web_news_promo TO authenticated;
GRANT ALL ON public.web_news_promo TO service_role;

-- 3. STORAGE BUCKET: web-news-promo
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'web-news-promo',
    'web-news-promo',
    true,
    5242880, -- 5 MB
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO UPDATE SET 
    public = true,
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

-- Storage RLS Policies for web-news-promo
DROP POLICY IF EXISTS "Public Access for Web News Promo Images" ON storage.objects;
CREATE POLICY "Public Access for Web News Promo Images"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'web-news-promo');

DROP POLICY IF EXISTS "Authenticated can upload web news promo images" ON storage.objects;
CREATE POLICY "Authenticated can upload web news promo images"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'web-news-promo');

DROP POLICY IF EXISTS "Authenticated can update web news promo images" ON storage.objects;
CREATE POLICY "Authenticated can update web news promo images"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'web-news-promo');

DROP POLICY IF EXISTS "Authenticated can delete web news promo images" ON storage.objects;
CREATE POLICY "Authenticated can delete web news promo images"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'web-news-promo');

-- 4. STORAGE BUCKET: product-images (Ensured on Staging & Production)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'product-images',
    'product-images',
    true,
    5242880, -- 5 MB
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO UPDATE SET 
    public = true,
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

-- Storage RLS Policies for product-images
DROP POLICY IF EXISTS "Public Access for Product Images" ON storage.objects;
CREATE POLICY "Public Access for Product Images"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'product-images');

DROP POLICY IF EXISTS "Authenticated can upload product images" ON storage.objects;
CREATE POLICY "Authenticated can upload product images"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'product-images');

DROP POLICY IF EXISTS "Authenticated can update product images" ON storage.objects;
CREATE POLICY "Authenticated can update product images"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'product-images');

DROP POLICY IF EXISTS "Authenticated can delete product images" ON storage.objects;
CREATE POLICY "Authenticated can delete product images"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'product-images');
