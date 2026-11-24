-- Migration: Create CRM Web Chat, Knowledge Base, and Role Reception
-- Date: 2026-11-02 12:40:00

-- 1. Ensure Role 19 (Reception) exists in role_user
INSERT INTO public.role_user (id, role_name, created_at)
VALUES (19, 'reception', now())
ON CONFLICT (id) DO UPDATE SET role_name = EXCLUDED.role_name;

-- 2. Create web_chat_rooms table
CREATE TABLE IF NOT EXISTS public.web_chat_rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    member_id UUID REFERENCES public.web_members(id) ON DELETE SET NULL,
    member_name TEXT NOT NULL,
    member_phone TEXT,
    kode_outlet TEXT REFERENCES public.master_outlet(kode_outlet) ON DELETE SET NULL,
    category TEXT NOT NULL DEFAULT 'GENERAL', -- 'RESERVASI', 'HOLDING', 'GENERAL'
    status TEXT NOT NULL DEFAULT 'BOT', -- 'BOT', 'WAITING_STAFF', 'ACTIVE', 'RESOLVED'
    unread_by_outlet BOOLEAN NOT NULL DEFAULT false,
    unread_by_admin BOOLEAN NOT NULL DEFAULT false,
    unread_by_member BOOLEAN NOT NULL DEFAULT false,
    last_message TEXT,
    last_message_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Create web_chat_messages table
CREATE TABLE IF NOT EXISTS public.web_chat_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id UUID NOT NULL REFERENCES public.web_chat_rooms(id) ON DELETE CASCADE,
    sender_type TEXT NOT NULL, -- 'MEMBER', 'BOT', 'OUTLET_STAFF', 'WEB_ADMIN'
    sender_name TEXT NOT NULL,
    sender_id UUID,
    message_text TEXT NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,
    is_read BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 4. Create web_chat_knowledge table (Bot Knowledge Base)
CREATE TABLE IF NOT EXISTS public.web_chat_knowledge (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category TEXT NOT NULL DEFAULT 'UMUM',
    keyword TEXT NOT NULL,
    question TEXT NOT NULL,
    answer TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    sort_order INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 5. Indexes for fast query performance
CREATE INDEX IF NOT EXISTS idx_web_chat_rooms_outlet_unread 
    ON public.web_chat_rooms(kode_outlet, unread_by_outlet, status);
CREATE INDEX IF NOT EXISTS idx_web_chat_rooms_admin_unread 
    ON public.web_chat_rooms(unread_by_admin, status);
CREATE INDEX IF NOT EXISTS idx_web_chat_rooms_member 
    ON public.web_chat_rooms(member_id);
CREATE INDEX IF NOT EXISTS idx_web_chat_rooms_last_msg 
    ON public.web_chat_rooms(last_message_at DESC);
CREATE INDEX IF NOT EXISTS idx_web_chat_messages_room_created 
    ON public.web_chat_messages(room_id, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_web_chat_knowledge_keyword 
    ON public.web_chat_knowledge(keyword);

-- 6. Trigger to keep web_chat_rooms updated automatically when a message is added
CREATE OR REPLACE FUNCTION public.fn_sync_web_chat_room_state()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.sender_type = 'MEMBER' THEN
        UPDATE public.web_chat_rooms
        SET last_message = NEW.message_text,
            last_message_at = NEW.created_at,
            updated_at = NEW.created_at,
            unread_by_outlet = CASE WHEN category = 'RESERVASI' AND kode_outlet IS NOT NULL THEN true ELSE unread_by_outlet END,
            unread_by_admin = CASE WHEN category = 'HOLDING' OR kode_outlet IS NULL THEN true ELSE unread_by_admin END,
            unread_by_member = false
        WHERE id = NEW.room_id;
    ELSIF NEW.sender_type IN ('OUTLET_STAFF', 'WEB_ADMIN', 'BOT') THEN
        UPDATE public.web_chat_rooms
        SET last_message = NEW.message_text,
            last_message_at = NEW.created_at,
            updated_at = NEW.created_at,
            unread_by_member = true,
            unread_by_outlet = CASE WHEN NEW.sender_type = 'OUTLET_STAFF' THEN false ELSE unread_by_outlet END,
            unread_by_admin = CASE WHEN NEW.sender_type = 'WEB_ADMIN' THEN false ELSE unread_by_admin END,
            status = CASE WHEN status = 'WAITING_STAFF' AND NEW.sender_type IN ('OUTLET_STAFF', 'WEB_ADMIN') THEN 'ACTIVE' ELSE status END
        WHERE id = NEW.room_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_web_chat_room_state ON public.web_chat_messages;
CREATE TRIGGER trg_sync_web_chat_room_state
    AFTER INSERT ON public.web_chat_messages
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_sync_web_chat_room_state();

-- 7. Add tables to Supabase Realtime Publication
DO $$
BEGIN
    BEGIN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.web_chat_rooms;
    EXCEPTION WHEN duplicate_object THEN null;
    END;
    BEGIN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.web_chat_messages;
    EXCEPTION WHEN duplicate_object THEN null;
    END;
END $$;

-- 8. Row Level Security (RLS) Policies
ALTER TABLE public.web_chat_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_chat_knowledge ENABLE ROW LEVEL SECURITY;

-- Permissions grants
GRANT SELECT, INSERT, UPDATE ON TABLE public.web_chat_rooms TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.web_chat_messages TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.web_chat_knowledge TO anon, authenticated, service_role;

-- Policies for web_chat_rooms
DROP POLICY IF EXISTS "Allow anon and auth read web_chat_rooms" ON public.web_chat_rooms;
CREATE POLICY "Allow anon and auth read web_chat_rooms"
    ON public.web_chat_rooms FOR SELECT
    TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS "Allow anon and auth insert web_chat_rooms" ON public.web_chat_rooms;
CREATE POLICY "Allow anon and auth insert web_chat_rooms"
    ON public.web_chat_rooms FOR INSERT
    TO anon, authenticated
    WITH CHECK (true);

DROP POLICY IF EXISTS "Allow anon and auth update web_chat_rooms" ON public.web_chat_rooms;
CREATE POLICY "Allow anon and auth update web_chat_rooms"
    ON public.web_chat_rooms FOR UPDATE
    TO anon, authenticated
    USING (true)
    WITH CHECK (true);

-- Policies for web_chat_messages
DROP POLICY IF EXISTS "Allow anon and auth read web_chat_messages" ON public.web_chat_messages;
CREATE POLICY "Allow anon and auth read web_chat_messages"
    ON public.web_chat_messages FOR SELECT
    TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS "Allow anon and auth insert web_chat_messages" ON public.web_chat_messages;
CREATE POLICY "Allow anon and auth insert web_chat_messages"
    ON public.web_chat_messages FOR INSERT
    TO anon, authenticated
    WITH CHECK (true);

DROP POLICY IF EXISTS "Allow anon and auth update web_chat_messages" ON public.web_chat_messages;
CREATE POLICY "Allow anon and auth update web_chat_messages"
    ON public.web_chat_messages FOR UPDATE
    TO anon, authenticated
    USING (true)
    WITH CHECK (true);

-- Policies for web_chat_knowledge
DROP POLICY IF EXISTS "Allow public read active knowledge" ON public.web_chat_knowledge;
CREATE POLICY "Allow public read active knowledge"
    ON public.web_chat_knowledge FOR SELECT
    TO anon, authenticated
    USING (is_active = true);

DROP POLICY IF EXISTS "Allow staff manage knowledge" ON public.web_chat_knowledge;
CREATE POLICY "Allow staff manage knowledge"
    ON public.web_chat_knowledge FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- 9. Seed Default Knowledge Base
INSERT INTO public.web_chat_knowledge (category, keyword, question, answer, sort_order) VALUES
('JAM_BUKA', 'jam buka, jam operasional, buka jam berapa, tutup jam berapa', 'Jam berapa jam operasional Zen Family Spa?', 'Zen Family Spa buka setiap hari mulai pukul 10:00 hingga 22:00 waktu setempat (WIB/WITA) di seluruh cabang di Indonesia.', 1),
('ETIKET', 'etiket, tata tertib, aturan, profesional, murni, pijat apa', 'Bagaimana etiket dan konsep layanan di Zen Family Spa?', 'Zen Family Spa adalah spa keluarga murni yang menjunjung tinggi profesionalisme dan kenyamanan seluruh anggota keluarga. Kami tidak mentolerir permintaan atau perilaku yang melanggar norma kesopanan dan etika pelayanan keluarga.', 2),
('RESERVASI', 'cara reservasi, booking, pesan jadwal', 'Bagaimana cara melakukan reservasi perawatan?', 'Anda dapat memilih opsi "Reservasi Cabang" pada menu chat ini untuk langsung terhubung dengan staf resepsionis cabang yang Anda tuju, atau menghubungi nomor WhatsApp cabang kami.', 3),
('PRODUK', 'minyak apa, aroma, essential oil', 'Minyak apa yang digunakan untuk perawatan?', 'Zen Family Spa menggunakan 100% natural blended essential oils yang diracik khusus dari tumbuhan alami untuk merelaksasi otot, melancarkan sirkulasi darah, dan menenangkan pikiran.', 4)
ON CONFLICT DO NOTHING;

