-- Migration: Create public.master_services and public.crm_leads for Zen Family Spa Official Website
-- Enables RLS for public (anon) SELECT on master_services & master_outlet, and public (anon) INSERT on crm_leads.

-- 1. Ensure master_outlet has anon SELECT policy and sync 10 active outlets
ALTER TABLE public.master_outlet ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'master_outlet' AND policyname = 'Allow anon read master_outlet'
    ) THEN
        CREATE POLICY "Allow anon read master_outlet"
            ON public.master_outlet
            FOR SELECT
            TO anon
            USING (active = true);
    END IF;
END $$;

UPDATE public.master_outlet
SET active = true
WHERE kode_outlet IN ('101', '103', '105', '106', '107', '110', '112', '115', '116', '117');

-- Populate helpful default city/province/address metadata where missing so Outlet Locator is rich
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Bandung'), province = COALESCE(NULLIF(province, ''), 'Jawa Barat'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Sukajadi No. 168, Pasteur, Kec. Sukajadi') WHERE kode_outlet = '101';
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Bandung'), province = COALESCE(NULLIF(province, ''), 'Jawa Barat'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Surya Sumantri No. 18, Sukagalih, Kec. Sukajadi') WHERE kode_outlet = '103';
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Jakarta Selatan'), province = COALESCE(NULLIF(province, ''), 'DKI Jakarta'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Gunawarman No. 43, Kebayoran Baru') WHERE kode_outlet = '105';
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Jakarta Selatan'), province = COALESCE(NULLIF(province, ''), 'DKI Jakarta'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Pakubuwono VI No. 35, Kebayoran Baru') WHERE kode_outlet = '106';
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Palu'), province = COALESCE(NULLIF(province, ''), 'Sulawesi Tengah'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Moh. Hatta, Lolu Utara, Palu Timur') WHERE kode_outlet = '107';
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Badung'), province = COALESCE(NULLIF(province, ''), 'Bali'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Sunset Road No. 89, Seminyak, Kuta') WHERE kode_outlet = '110';
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Depok'), province = COALESCE(NULLIF(province, ''), 'Jawa Barat'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Margonda Raya No. 250, Kemiri Muka') WHERE kode_outlet = '112';
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Makassar'), province = COALESCE(NULLIF(province, ''), 'Sulawesi Selatan'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Pelita Raya, Panakkukang') WHERE kode_outlet = '115';
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Bandung'), province = COALESCE(NULLIF(province, ''), 'Jawa Barat'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Mekar Utama No. 112, Komplek Mekarwangi') WHERE kode_outlet = '116';
UPDATE public.master_outlet SET city = COALESCE(NULLIF(city, ''), 'Bandung Barat'), province = COALESCE(NULLIF(province, ''), 'Jawa Barat'), alamat = COALESCE(NULLIF(alamat, ''), 'Jl. Parahyangan Raya No. 2 Kav. 6B, Kota Baru Parahyangan') WHERE kode_outlet = '117';

-- 2. Create public.master_services table for Dynamic Treatment Menu
CREATE TABLE IF NOT EXISTS public.master_services (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    service_code text UNIQUE NOT NULL,
    name text NOT NULL,
    category text NOT NULL,
    duration_minutes integer NOT NULL DEFAULT 60,
    price numeric(12, 2) NOT NULL DEFAULT 0,
    description text NOT NULL,
    benefits text,
    image_url text,
    is_featured boolean NOT NULL DEFAULT false,
    active boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 100,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.master_services ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow public read active master_services" ON public.master_services;
CREATE POLICY "Allow public read active master_services"
    ON public.master_services
    FOR SELECT
    TO anon, authenticated
    USING (active = true);

GRANT SELECT ON public.master_services TO anon, authenticated;

-- Seed authentic Zen Family Spa & Reflexology treatments
INSERT INTO public.master_services (
    service_code, name, category, duration_minutes, price, description, benefits, image_url, is_featured, active, sort_order
) VALUES
    (
        'ZEN-SIG-01',
        'The Royal Touch Ritual',
        'Signature Body Massage',
        100,
        345000,
        'Perawatan holistik khas Zen yang memadukan pijatan jaringan dalam (deep tissue), akupresur meridian tradisional, dan kompres hangat aromaterapi serai organik.',
        'Meredakan ketegangan otot kronis, melancarkan sirkulasi darah, dan memulihkan kualitas tidur.',
        'https://images.unsplash.com/photo-1544161515-4ab6ce6db874?auto=format&fit=crop&w=900&q=80',
        true,
        true,
        1
    ),
    (
        'ZEN-SIG-02',
        'Zen Relaxing Massage 90''',
        'Signature Body Massage',
        90,
        290000,
        'Terapi pijat seluruh tubuh dengan usapan panjang berirama lembut menggunakan minyak esensial pilihan (Lavender, Lemongrass, atau Sandalwood).',
        'Menurunkan hormon stres kortisol dan memberikan ketenangan pikiran mendalam.',
        'https://images.unsplash.com/photo-1600334089648-b0d9d3028eb2?auto=format&fit=crop&w=900&q=80',
        true,
        true,
        2
    ),
    (
        'ZEN-SIG-03',
        'Volcanic Hot Stone Therapy',
        'Signature Body Massage',
        120,
        300000,
        'Kombinasi pijatan aromaterapi dengan batu basal vulkanik hangat yang ditempatkan pada titik energi tubuh untuk melepas kekakuan otot terdalam.',
        'Detoksifikasi alami, hangat menenangkan sendi, dan relaksasi sistem saraf.',
        'https://images.unsplash.com/photo-1519823551278-64ac92734fb1?auto=format&fit=crop&w=900&q=80',
        true,
        true,
        3
    ),
    (
        'ZEN-SIG-04',
        'Relaxing Sport & Recovery Massage',
        'Signature Body Massage',
        90,
        240000,
        'Pijatan bertenaga terfokus pada pemulihan otot pasca-aktivitas fisik dengan teknik peregangan pasif dan pelemasan fascia.',
        'Mempercepat pemulihan asam laktat dan meningkatkan fleksibilitas gerak tubuh.',
        'https://images.unsplash.com/photo-1515377905703-c4788e51af15?auto=format&fit=crop&w=900&q=80',
        false,
        true,
        4
    ),
    (
        'ZEN-REF-01',
        'Foot & Shoulder Sanctuary 100''',
        'Reflexology & Foot Therapy',
        100,
        190000,
        'Perpaduan refleksi titik saraf telapak kaki lengkap dengan pijatan intensif pada area leher, bahu, dan punggung atas.',
        'Solusi ideal bagi pekerja aktif untuk menghilangkan pegal kaki dan ketegangan bahu.',
        'https://images.unsplash.com/photo-1519824145371-296894a0daa9?auto=format&fit=crop&w=900&q=80',
        true,
        true,
        5
    ),
    (
        'ZEN-REF-02',
        'Zen Signature Foot Relaxing 90''',
        'Reflexology & Foot Therapy',
        90,
        160000,
        'Terapi refleksi kaki autentik diawali dengan perendaman kaki garam laut hangat (warm sea-salt foot bath) dan stimulasi 36 titik zona organ.',
        'Menyeimbangkan fungsi organ dalam dan mengembalikan kebugaran langkah Anda.',
        'https://images.unsplash.com/photo-1552693673-1bf958298935?auto=format&fit=crop&w=900&q=80',
        false,
        true,
        6
    ),
    (
        'ZEN-REF-03',
        'Hot Stone Reflexy 90''',
        'Reflexology & Foot Therapy',
        90,
        210000,
        'Terapi refleksi telapak kaki dan betis yang dipadukan dengan batu hangat alami untuk melancarkan peredaran darah perifer.',
        'Mengurangi pembengkakan kaki dan memberikan sensasi hangat yang menenangkan.',
        'https://images.unsplash.com/photo-1540555700478-4be289fbecef?auto=format&fit=crop&w=900&q=80',
        false,
        true,
        7
    ),
    (
        'ZEN-SCR-01',
        'Royal Lulur Whitening Milk',
        'Traditional Body Scrub & Boreh',
        45,
        80000,
        'Eksfoliasi kulit tubuh menggunakan lulur rempah tradisional Nusantara yang diperkaya ekstrak susu murni untuk mencerahkan dan melembutkan kulit.',
        'Mengangkat sel kulit mati, melembapkan kulit kering, dan memberikan kilau alami.',
        'https://images.unsplash.com/photo-1570172619644-dfd03ed5d881?auto=format&fit=crop&w=900&q=80',
        false,
        true,
        8
    ),
    (
        'ZEN-SCR-02',
        'Authentic Boreh Bali Warming Mask',
        'Traditional Body Scrub & Boreh',
        45,
        80000,
        'Baluran rempah hangat warisan keraton Bali (jahe, cengkeh, kayu manis, dan beras tumbuk) untuk menghangatkan tubuh dan meredakan masuk angin.',
        'Menghangatkan otot, memperlancar metabolisme, dan menyegarkan kulit.',
        'https://images.unsplash.com/photo-1507652313519-d4e9174996dd?auto=format&fit=crop&w=900&q=80',
        false,
        true,
        9
    ),
    (
        'ZEN-FAC-01',
        'Botanical Face Acupressure & Glow',
        'Facial & Add-On Rituals',
        30,
        75000,
        'Pijatan totok wajah lembut pada titik meridian wajah untuk mengurangi ketegangan mata, rahang, serta meningkatkan sirkulasi kolagen alami.',
        'Wajah tampak lebih segar, rileks, dan bercahaya.',
        'https://images.unsplash.com/photo-1512290923902-8a9f81dc236c?auto=format&fit=crop&w=900&q=80',
        false,
        true,
        10
    )
ON CONFLICT (service_code) DO UPDATE SET
    name = EXCLUDED.name,
    category = EXCLUDED.category,
    duration_minutes = EXCLUDED.duration_minutes,
    price = EXCLUDED.price,
    description = EXCLUDED.description,
    benefits = EXCLUDED.benefits,
    image_url = EXCLUDED.image_url,
    is_featured = EXCLUDED.is_featured,
    active = EXCLUDED.active,
    sort_order = EXCLUDED.sort_order;

-- 3. Create public.crm_leads table for Reservation & Booking Inquiries
CREATE TABLE IF NOT EXISTS public.crm_leads (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_name text NOT NULL,
    phone text NOT NULL,
    kode_outlet text NOT NULL,
    service_name text,
    reservation_date date NOT NULL,
    reservation_time text NOT NULL,
    guest_count integer NOT NULL DEFAULT 1,
    notes text,
    status text NOT NULL DEFAULT 'NEW',
    source text NOT NULL DEFAULT 'WEBSITE',
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.crm_leads ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow public insert crm_leads" ON public.crm_leads;
CREATE POLICY "Allow public insert crm_leads"
    ON public.crm_leads
    FOR INSERT
    TO anon, authenticated
    WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated read crm_leads" ON public.crm_leads;
CREATE POLICY "Allow authenticated read crm_leads"
    ON public.crm_leads
    FOR SELECT
    TO authenticated
    USING (true);

DROP POLICY IF EXISTS "Allow authenticated update crm_leads" ON public.crm_leads;
CREATE POLICY "Allow authenticated update crm_leads"
    ON public.crm_leads
    FOR UPDATE
    TO authenticated
    USING (true);

GRANT INSERT ON public.crm_leads TO anon, authenticated;
GRANT SELECT, UPDATE ON public.crm_leads TO authenticated;

