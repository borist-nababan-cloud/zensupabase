-- ==============================================================================
-- Migration: Create web_services, web_outlet_services, and Storage Bucket 'web-services'
-- Description: Establishes multi-branch service menu catalog without prices (to avoid 
--              customer misperception across cities) with 3 categories:
--              'Body Massage', 'Foot Reflexology', 'Addition'.
-- ==============================================================================

-- 1. Create table public.web_services (Global Master)
CREATE TABLE IF NOT EXISTS public.web_services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('Body Massage', 'Foot Reflexology', 'Addition')),
    duration_minutes INTEGER NOT NULL DEFAULT 60,
    description TEXT,
    benefits TEXT,
    image_url TEXT,
    active BOOLEAN NOT NULL DEFAULT true,
    sort_order INTEGER NOT NULL DEFAULT 10,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by TEXT,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by TEXT
);

-- Indexing for fast public queries
CREATE INDEX IF NOT EXISTS idx_web_services_active ON public.web_services(active);
CREATE INDEX IF NOT EXISTS idx_web_services_category ON public.web_services(category);
CREATE INDEX IF NOT EXISTS idx_web_services_sort ON public.web_services(sort_order);

-- Enable RLS
ALTER TABLE public.web_services ENABLE ROW LEVEL SECURITY;

-- RLS Policies on web_services
DROP POLICY IF EXISTS "Public can view active web_services" ON public.web_services;
CREATE POLICY "Public can view active web_services"
ON public.web_services FOR SELECT
TO public
USING (active = true);

DROP POLICY IF EXISTS "Authenticated can view all web_services" ON public.web_services;
CREATE POLICY "Authenticated can view all web_services"
ON public.web_services FOR SELECT
TO authenticated
USING (true);

DROP POLICY IF EXISTS "Authenticated can insert web_services" ON public.web_services;
CREATE POLICY "Authenticated can insert web_services"
ON public.web_services FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated can update web_services" ON public.web_services;
CREATE POLICY "Authenticated can update web_services"
ON public.web_services FOR UPDATE
TO authenticated
USING (true);

DROP POLICY IF EXISTS "Authenticated can delete web_services" ON public.web_services;
CREATE POLICY "Authenticated can delete web_services"
ON public.web_services FOR DELETE
TO authenticated
USING (true);

-- 2. Create table public.web_outlet_services (Branch Availability Mapping)
CREATE TABLE IF NOT EXISTS public.web_outlet_services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON DELETE CASCADE,
    service_id UUID NOT NULL REFERENCES public.web_services(id) ON DELETE CASCADE,
    is_available BOOLEAN NOT NULL DEFAULT true,
    custom_notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_web_outlet_services UNIQUE (kode_outlet, service_id)
);

CREATE INDEX IF NOT EXISTS idx_web_outlet_services_outlet ON public.web_outlet_services(kode_outlet);
CREATE INDEX IF NOT EXISTS idx_web_outlet_services_service ON public.web_outlet_services(service_id);
CREATE INDEX IF NOT EXISTS idx_web_outlet_services_avail ON public.web_outlet_services(is_available);

-- Enable RLS
ALTER TABLE public.web_outlet_services ENABLE ROW LEVEL SECURITY;

-- RLS Policies on web_outlet_services
DROP POLICY IF EXISTS "Public can view available web_outlet_services" ON public.web_outlet_services;
CREATE POLICY "Public can view available web_outlet_services"
ON public.web_outlet_services FOR SELECT
TO public
USING (is_available = true);

DROP POLICY IF EXISTS "Authenticated can view all web_outlet_services" ON public.web_outlet_services;
CREATE POLICY "Authenticated can view all web_outlet_services"
ON public.web_outlet_services FOR SELECT
TO authenticated
USING (true);

DROP POLICY IF EXISTS "Authenticated can insert web_outlet_services" ON public.web_outlet_services;
CREATE POLICY "Authenticated can insert web_outlet_services"
ON public.web_outlet_services FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Authenticated can update web_outlet_services" ON public.web_outlet_services;
CREATE POLICY "Authenticated can update web_outlet_services"
ON public.web_outlet_services FOR UPDATE
TO authenticated
USING (true);

DROP POLICY IF EXISTS "Authenticated can delete web_outlet_services" ON public.web_outlet_services;
CREATE POLICY "Authenticated can delete web_outlet_services"
ON public.web_outlet_services FOR DELETE
TO authenticated
USING (true);

-- 3. Create or Update Storage Bucket 'web-services'
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'web-services',
    'web-services',
    true,
    5242880, -- 5 MB limit
    ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 4. Storage RLS Policies for 'web-services' Bucket
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Public read access for web-services'
    ) THEN
        CREATE POLICY "Public read access for web-services"
        ON storage.objects FOR SELECT
        TO public
        USING (bucket_id = 'web-services');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can upload web-services'
    ) THEN
        CREATE POLICY "Authenticated users can upload web-services"
        ON storage.objects FOR INSERT
        TO authenticated
        WITH CHECK (bucket_id = 'web-services');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can update web-services'
    ) THEN
        CREATE POLICY "Authenticated users can update web-services"
        ON storage.objects FOR UPDATE
        TO authenticated
        USING (bucket_id = 'web-services');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can delete web-services'
    ) THEN
        CREATE POLICY "Authenticated users can delete web-services"
        ON storage.objects FOR DELETE
        TO authenticated
        USING (bucket_id = 'web-services');
    END IF;
END $$;

