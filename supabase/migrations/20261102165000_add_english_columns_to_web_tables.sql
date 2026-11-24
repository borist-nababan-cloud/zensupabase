-- Migration: Add English translation columns to web_services, web_facilities, and web_chat_knowledge
-- Date: 2026-11-02 16:50:00

-- 1. Add English columns to web_services
ALTER TABLE public.web_services 
    ADD COLUMN IF NOT EXISTS name_en TEXT,
    ADD COLUMN IF NOT EXISTS description_en TEXT,
    ADD COLUMN IF NOT EXISTS benefits_en TEXT[],
    ADD COLUMN IF NOT EXISTS category_en TEXT;

-- 2. Add English columns to web_facilities
ALTER TABLE public.web_facilities 
    ADD COLUMN IF NOT EXISTS name_en TEXT,
    ADD COLUMN IF NOT EXISTS description_en TEXT,
    ADD COLUMN IF NOT EXISTS category_en TEXT;

-- 3. Add English columns to web_chat_knowledge
ALTER TABLE public.web_chat_knowledge 
    ADD COLUMN IF NOT EXISTS question_en TEXT,
    ADD COLUMN IF NOT EXISTS answer_en TEXT,
    ADD COLUMN IF NOT EXISTS keyword_en TEXT;

-- 4. Seed English translations for default facilities
UPDATE public.web_facilities
SET 
    name_en = 'Herbal Jacuzzi & Bathtub',
    category_en = 'Treatment Suite',
    description_en = 'Private soaking tub infused with aromatherapy mineral salts and natural herbal botanicals to soothe muscle tension after massage.'
WHERE facility_code = 'FAC-BATHTUB';

UPDATE public.web_facilities
SET 
    name_en = 'Couple VIP Suite Room',
    category_en = 'Treatment Suite',
    description_en = 'Exclusive relaxation sanctuary for two, featuring serene ambiance, soothing warm lighting, and private en-suite shower.'
WHERE facility_code = 'FAC-COUPLE-ROOM';

UPDATE public.web_facilities
SET 
    name_en = 'SPKLU / EV Charging Station',
    category_en = 'General Amenities',
    description_en = 'Dedicated electric vehicle (EV) fast-charging station in our parking area, ensuring seamless recharging while you enjoy your treatment.'
WHERE facility_code = 'FAC-SPKLU-EV';

UPDATE public.web_facilities
SET 
    name_en = 'Hot Water Rain Shower & Bath',
    category_en = 'Comfort & Hygiene',
    description_en = 'Individual shower room equipped with premium natural botanical amenities, warm water, and clean linen towels after herbal massage.'
WHERE facility_code = 'FAC-HOT-SHOWER';

UPDATE public.web_facilities
SET 
    name_en = 'Zen Wellness Tea Lounge',
    category_en = 'Comfort & Hospitality',
    description_en = 'Tranquil pre-and-post treatment lounge serving authentic hot herbal ginger tea with soothing natural background acoustics.'
WHERE facility_code = 'FAC-LOUNGE-TEA';

UPDATE public.web_facilities
SET 
    name_en = 'Spacious Valet Parking Area',
    category_en = 'General Amenities',
    description_en = 'Safe, sheltered parking area with 24-hour security guards and complimentary valet service for guest convenience.'
WHERE facility_code = 'FAC-PARKING-VALET';

-- 5. Seed English translations for default Chatbot Knowledge Base (web_chat_knowledge)
UPDATE public.web_chat_knowledge
SET 
    question_en = 'What are the operating hours of Zen Family Spa?',
    answer_en = 'Zen Family Spa is open daily from 10:00 AM to 10:00 PM local time (WIB/WITA) across all our branches throughout Indonesia.',
    keyword_en = 'operating hours, opening hours, schedule, open time, close time, what time'
WHERE category = 'JAM_BUKA';

UPDATE public.web_chat_knowledge
SET 
    question_en = 'What is the etiquette and service concept at Zen Family Spa?',
    answer_en = 'Zen Family Spa is a pure family-oriented wellness retreat upholding the highest standards of professionalism and family comfort. We strictly maintain modesty and pure family spa ethics.',
    keyword_en = 'etiquette, rules, family spa, professional, code of conduct, massage type'
WHERE category = 'ETIKET';

UPDATE public.web_chat_knowledge
SET 
    question_en = 'How do I book or make a treatment reservation?',
    answer_en = 'You can select "Branch Reservation" from this chat menu to connect directly with the reception staff at your chosen branch, or contact our branch WhatsApp concierge directly.',
    keyword_en = 'reservation, booking, make appointment, schedule, book'
WHERE category = 'RESERVASI';

UPDATE public.web_chat_knowledge
SET 
    question_en = 'What oils and ingredients are used in treatments?',
    answer_en = 'Zen Family Spa uses 100% pure botanical essential oils specially formulated to melt away muscle fatigue, improve blood circulation, and calm your senses.',
    keyword_en = 'oil, aroma, essential oil, massage oil, botanical, ingredients'
WHERE category = 'PRODUK';

