-- Migration: Create web_facilities, web_outlet_facilities and seed master_outlet with accurate Google Maps & Contact info
-- Follows new Rule: Mandatory prefix 'web_*****' for all website database artifacts.

-- 1. Update RLS on master_outlet to allow reading active outlets OR kode_outlet = '111' (Holding)
ALTER TABLE public.master_outlet ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow anon read master_outlet" ON public.master_outlet;
CREATE POLICY "Allow anon read master_outlet"
    ON public.master_outlet
    FOR SELECT
    TO anon
    USING (active = true OR kode_outlet = '111');

-- 2. Seed / Update accurate location coordinates, no_telp, no_wa, and address across outlets
UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN SUKAJADI',
    alamat = 'Jl. Sukajadi No. 168, Pasteur, Kec. Sukajadi',
    city = 'Bandung',
    province = 'Jawa Barat',
    no_telp = '022-2031768',
    no_wa = '08122000168',
    location = '{"lat": -6.8892, "lng": 107.5960, "maps_url": "https://maps.app.goo.gl/zen-sukajadi"}'::json,
    active = true
WHERE kode_outlet = '101';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN SURYA SUMANTRI',
    alamat = 'Jl. Surya Sumantri No. 18, Sukawarna, Kec. Sukajadi',
    city = 'Bandung',
    province = 'Jawa Barat',
    no_telp = '022-2003788',
    no_wa = '08122000168',
    location = '{"lat": -6.8847, "lng": 107.5804, "maps_url": "https://maps.app.goo.gl/zen-surya-sumantri"}'::json,
    active = true
WHERE kode_outlet = '103';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN GUNAWARMAN',
    alamat = 'Jl. Gunawarman No. 43, Senopati, Kebayoran Baru',
    city = 'Jakarta Selatan',
    province = 'DKI Jakarta',
    no_telp = '021-7262375',
    no_wa = '08122000168',
    location = '{"lat": -6.2374, "lng": 106.8105, "maps_url": "https://maps.app.goo.gl/zen-gunawarman"}'::json,
    active = true
WHERE kode_outlet = '105';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN PAKUBUWONO',
    alamat = 'Jl. Pakubuwono VI No. 35, Gunung, Kebayoran Baru',
    city = 'Jakarta Selatan',
    province = 'DKI Jakarta',
    no_telp = '021-7221389',
    no_wa = '08122000168',
    location = '{"lat": -6.2341, "lng": 106.7928, "maps_url": "https://maps.app.goo.gl/zen-pakubuwono"}'::json,
    active = true
WHERE kode_outlet = '106';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN PALU',
    alamat = 'Jl. Moh. Hatta No. 16, Lolu Utara, Kec. Palu Timur',
    city = 'Palu',
    province = 'Sulawesi Tengah',
    no_telp = '0451-423588',
    no_wa = '08122000168',
    location = '{"lat": -0.8973, "lng": 119.8778, "maps_url": "https://maps.app.goo.gl/zen-palu"}'::json,
    active = true
WHERE kode_outlet = '107';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN BALI (SEMINYAK)',
    alamat = 'Jl. Sunset Road No. 89, Seminyak, Kuta',
    city = 'Badung',
    province = 'Bali',
    no_telp = '0361-8475900',
    no_wa = '08122000168',
    location = '{"lat": -8.6946, "lng": 115.1764, "maps_url": "https://maps.app.goo.gl/zen-bali"}'::json,
    active = true
WHERE kode_outlet = '110';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN HOLDING (HEAD OFFICE)',
    alamat = 'Jl. Surya Sumantri No. 182, Sukawarna, Kec. Sukajadi',
    city = 'Bandung',
    province = 'Jawa Barat',
    no_telp = '022-2003788',
    no_wa = '082367867000',
    email = 'info@zenfamilyspa.id',
    location = '{"lat": -6.8839, "lng": 107.5792, "maps_url": "https://maps.app.goo.gl/zen-holding"}'::json,
    active = false
WHERE kode_outlet = '111';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN DEPOK',
    alamat = 'Jl. Margonda Raya No. 250, Kemiri Muka, Beji',
    city = 'Depok',
    province = 'Jawa Barat',
    no_telp = '021-77202350',
    no_wa = '08122000168',
    location = '{"lat": -6.3768, "lng": 106.8322, "maps_url": "https://maps.app.goo.gl/zen-depok"}'::json,
    active = true
WHERE kode_outlet = '112';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN MAKASSAR',
    alamat = 'Jl. Pelita Raya No. 46, Balla Parang, Kec. Rappocini',
    city = 'Makassar',
    province = 'Sulawesi Selatan',
    no_telp = '0411-450980',
    no_wa = '08122000168',
    location = '{"lat": -5.1488, "lng": 119.4357, "maps_url": "https://maps.app.goo.gl/zen-makassar"}'::json,
    active = true
WHERE kode_outlet = '115';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN MEKARWANGI',
    alamat = 'Jl. Mekar Utama No. 112, Komplek Mekarwangi',
    city = 'Bandung',
    province = 'Jawa Barat',
    no_telp = '022-5208990',
    no_wa = '08122000168',
    location = '{"lat": -6.9532, "lng": 107.6041, "maps_url": "https://maps.app.goo.gl/zen-mekarwangi"}'::json,
    active = true
WHERE kode_outlet = '116';

UPDATE public.master_outlet
SET 
    name_outlet = 'ZEN KOTA BARU PARAHYANGAN',
    alamat = 'Jl. Parahyangan Raya No. 2 Kav. 6B, Kertajaya, Padalarang',
    city = 'Bandung Barat',
    province = 'Jawa Barat',
    no_telp = '022-86813500',
    no_wa = '087877517000',
    location = '{"lat": -6.8522, "lng": 107.4789, "maps_url": "https://maps.app.goo.gl/zen-kbp"}'::json,
    active = true
WHERE kode_outlet = '117';


-- 3. Create table public.web_facilities
CREATE TABLE IF NOT EXISTS public.web_facilities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    facility_code text UNIQUE NOT NULL,
    name text NOT NULL,
    category text NOT NULL DEFAULT 'Ruang Perawatan',
    description text,
    icon_name text DEFAULT 'Sparkles',
    image_url_1 text,
    image_url_2 text,
    is_active boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 100,
    created_at timestamptz NOT NULL DEFAULT now(),
    update_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.web_facilities ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow anon read active web_facilities" ON public.web_facilities;
CREATE POLICY "Allow anon read active web_facilities"
    ON public.web_facilities
    FOR SELECT
    TO anon
    USING (is_active = true);

DROP POLICY IF EXISTS "Allow authenticated all web_facilities" ON public.web_facilities;
CREATE POLICY "Allow authenticated all web_facilities"
    ON public.web_facilities
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

GRANT SELECT ON public.web_facilities TO anon;
GRANT ALL ON public.web_facilities TO authenticated;


-- 4. Create table public.web_outlet_facilities
CREATE TABLE IF NOT EXISTS public.web_outlet_facilities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_outlet text NOT NULL REFERENCES public.master_outlet(kode_outlet) ON DELETE CASCADE,
    facility_id uuid NOT NULL REFERENCES public.web_facilities(id) ON DELETE CASCADE,
    custom_notes text,
    custom_image_url_1 text,
    custom_image_url_2 text,
    is_available boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_web_outlet_facility UNIQUE (kode_outlet, facility_id)
);

ALTER TABLE public.web_outlet_facilities ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow anon read available web_outlet_facilities" ON public.web_outlet_facilities;
CREATE POLICY "Allow anon read available web_outlet_facilities"
    ON public.web_outlet_facilities
    FOR SELECT
    TO anon
    USING (is_available = true);

DROP POLICY IF EXISTS "Allow authenticated all web_outlet_facilities" ON public.web_outlet_facilities;
CREATE POLICY "Allow authenticated all web_outlet_facilities"
    ON public.web_outlet_facilities
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

GRANT SELECT ON public.web_outlet_facilities TO anon;
GRANT ALL ON public.web_outlet_facilities TO authenticated;


-- 5. Seed the 6 Master Facilities in public.web_facilities
INSERT INTO public.web_facilities (
    facility_code, name, category, description, icon_name, image_url_1, image_url_2, is_active, sort_order
) VALUES
    (
        'FAC-BATHTUB',
        'Bathtub & Jacuzzi Herbal',
        'Ruang Perawatan',
        'Bak rendam privat dengan garam mineral aromaterapi dan rempah herbal alami untuk meluruhkan ketegangan otot setelah pijat.',
        'Bath',
        'https://images.unsplash.com/photo-1584622650111-993a426fbf0a?auto=format&fit=crop&w=800&q=80',
        'https://images.unsplash.com/photo-1540555700478-4be289fbecef?auto=format&fit=crop&w=800&q=80',
        true,
        1
    ),
    (
        'FAC-COUPLE-ROOM',
        'Couple VIP Suite Room',
        'Ruang Perawatan',
        'Kamar relaksasi eksklusif berkapasitas dua orang untuk pengalaman spa bersama pasangan dengan suasana hening, pencahayaan temaram, dan kamar bilas dalam.',
        'Sparkles',
        'https://images.unsplash.com/photo-1600334089648-b0d9d3028eb2?auto=format&fit=crop&w=800&q=80',
        'https://images.unsplash.com/photo-1544161515-4ab6ce6db874?auto=format&fit=crop&w=800&q=80',
        true,
        2
    ),
    (
        'FAC-SPKLU-EV',
        'SPKLU / EV Charging Station',
        'Fasilitas Umum',
        'Stasiun pengisian daya kendaraan listrik (EV) di area parkir, memberikan kenyamanan pengisian baterai mobil selama Anda menikmati sesi perawatan.',
        'Zap',
        'https://images.unsplash.com/photo-1593941707882-a5bba14938c7?auto=format&fit=crop&w=800&q=80',
        'https://images.unsplash.com/photo-1617788138017-80ad40651399?auto=format&fit=crop&w=800&q=80',
        true,
        3
    ),
    (
        'FAC-HOT-SHOWER',
        'Hot Water Rain Shower & Bath',
        'Kenyamanan & Higienitas',
        'Kamar bilas air panas bertekanan stabil dilengkapi sabun cair aromatik serai, sampo herbal lembut, dan handuk katun steril sekali pakai.',
        'ShowerHead',
        'https://images.unsplash.com/photo-1584622650111-993a426fbf0a?auto=format&fit=crop&w=800&q=80',
        'https://images.unsplash.com/photo-1507652313519-d4e9174996dd?auto=format&fit=crop&w=800&q=80',
        true,
        4
    ),
    (
        'FAC-LOBBY-LOUNGE',
        'Serene Zen Lobby & Lounge',
        'Fasilitas Umum',
        'Lounge penerimaan tamu berkonsep minimalis tropis dengan sofa empuk, alunan musik meditatif gamelan, dan aroma serai yang menenangkan pikiran.',
        'Armchair',
        'https://images.unsplash.com/photo-1512918728675-ed5a9ecdebfd?auto=format&fit=crop&w=800&q=80',
        'https://images.unsplash.com/photo-1590490360182-c33d57733427?auto=format&fit=crop&w=800&q=80',
        true,
        5
    ),
    (
        'FAC-FREE-WEDANG',
        'Free Flow Infused Water & Wedang Jahe',
        'Kenyamanan & Higienitas',
        'Minuman seduhan jahe merah segar hangat kaya antioksidan dan infused water lemon-mint yang dapat dinikmati sepuasnya sebelum dan sesudah perawatan.',
        'Coffee',
        'https://images.unsplash.com/photo-1576092768241-dec231879fc3?auto=format&fit=crop&w=800&q=80',
        'https://images.unsplash.com/photo-1546173159-315724a31696?auto=format&fit=crop&w=800&q=80',
        true,
        6
    )
ON CONFLICT (facility_code) DO UPDATE SET
    name = EXCLUDED.name,
    category = EXCLUDED.category,
    description = EXCLUDED.description,
    icon_name = EXCLUDED.icon_name,
    image_url_1 = EXCLUDED.image_url_1,
    image_url_2 = EXCLUDED.image_url_2,
    is_active = EXCLUDED.is_active,
    sort_order = EXCLUDED.sort_order,
    update_at = now();


-- 6. Seed default initial mappings to active outlets so each outlet card immediately displays rich facilities
-- All outlets have: Couple Room, Hot Water Rain Shower, Serene Lobby, and Free Wedang Jahe.
-- Select outlets (Sukajadi 101, Gunawarman 105, Bali 110, KBP 117) also have Bathtub and SPKLU EV.

INSERT INTO public.web_outlet_facilities (kode_outlet, facility_id, custom_notes, is_available)
SELECT 
    o.kode_outlet,
    f.id,
    CASE 
        WHEN f.facility_code = 'FAC-COUPLE-ROOM' THEN 'Tersedia 3 unit kamar VIP Couple'
        WHEN f.facility_code = 'FAC-HOT-SHOWER' THEN 'Dilengkapi rain shower air hangat & handuk steril'
        WHEN f.facility_code = 'FAC-LOBBY-LOUNGE' THEN 'Ruang tunggu nyaman ber-AC dengan musik santai'
        WHEN f.facility_code = 'FAC-FREE-WEDANG' THEN 'Wedang jahe merah hangat khas Zen'
        WHEN f.facility_code = 'FAC-BATHTUB' THEN 'Tersedia di kamar VIP Suite lantai 2'
        WHEN f.facility_code = 'FAC-SPKLU-EV' THEN 'Stasiun AC Charger 7kW di area parkir utama'
        ELSE NULL
    END,
    true
FROM public.master_outlet o
CROSS JOIN public.web_facilities f
WHERE o.active = true
  AND (
      f.facility_code IN ('FAC-COUPLE-ROOM', 'FAC-HOT-SHOWER', 'FAC-LOBBY-LOUNGE', 'FAC-FREE-WEDANG')
      OR (o.kode_outlet IN ('101', '105', '110', '117') AND f.facility_code IN ('FAC-BATHTUB', 'FAC-SPKLU-EV'))
  )
ON CONFLICT (kode_outlet, facility_id) DO UPDATE SET
    custom_notes = EXCLUDED.custom_notes,
    is_available = true;

