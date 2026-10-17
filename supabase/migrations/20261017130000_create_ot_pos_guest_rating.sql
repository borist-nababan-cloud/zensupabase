-- Supabase Migration: Create ot_pos_guest_rating table
-- Description: Stores guest ratings collected from outlet counters with dual sync tracking (n8n & Supabase).

SET ROLE postgres;

CREATE TABLE IF NOT EXISTS public.ot_pos_guest_rating (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_outlet TEXT NOT NULL,
    ratingcode TEXT NOT NULL,
    id_payment TEXT,
    trans_id TEXT,
    tanggal DATE,
    kodekaryawan TEXT,
    user_uid TEXT,
    room_id TEXT,
    isupload CHAR(1) DEFAULT 'Y',
    uploadtime TIMESTAMPTZ DEFAULT now(),
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by TEXT DEFAULT 'sync_agent',
    update_at TIMESTAMPTZ DEFAULT now(),
    update_by TEXT DEFAULT 'sync_agent',
    CONSTRAINT uq_ot_pos_guest_rating_code UNIQUE (ratingcode)
);

-- Performance & Lookup Indexes
CREATE INDEX IF NOT EXISTS idx_ot_pos_guest_rating_outlet ON public.ot_pos_guest_rating (kode_outlet);
CREATE INDEX IF NOT EXISTS idx_ot_pos_guest_rating_tanggal ON public.ot_pos_guest_rating (tanggal);
CREATE INDEX IF NOT EXISTS idx_ot_pos_guest_rating_payment ON public.ot_pos_guest_rating (id_payment);
CREATE INDEX IF NOT EXISTS idx_ot_pos_guest_rating_trans ON public.ot_pos_guest_rating (trans_id);
CREATE INDEX IF NOT EXISTS idx_ot_pos_guest_rating_karyawan ON public.ot_pos_guest_rating (kodekaryawan);
CREATE INDEX IF NOT EXISTS idx_ot_pos_guest_rating_user ON public.ot_pos_guest_rating (user_uid);

-- Row Level Security (RLS)
ALTER TABLE public.ot_pos_guest_rating ENABLE ROW LEVEL SECURITY;

-- RLS Policies
DO $$ 
BEGIN
    -- service_role full access
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_guest_rating' AND policyname = 'Allow service role all on ot_pos_guest_rating'
    ) THEN
        CREATE POLICY "Allow service role all on ot_pos_guest_rating" 
            ON public.ot_pos_guest_rating 
            AS PERMISSIVE FOR ALL 
            TO service_role 
            USING (true) 
            WITH CHECK (true);
    END IF;

    -- authenticated read
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_guest_rating' AND policyname = 'Allow authenticated read ot_pos_guest_rating'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_pos_guest_rating" 
            ON public.ot_pos_guest_rating 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- authenticated insert
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_guest_rating' AND policyname = 'Allow authenticated insert ot_pos_guest_rating'
    ) THEN
        CREATE POLICY "Allow authenticated insert ot_pos_guest_rating" 
            ON public.ot_pos_guest_rating 
            AS PERMISSIVE FOR INSERT 
            TO authenticated 
            WITH CHECK (true);
    END IF;

    -- authenticated update
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_guest_rating' AND policyname = 'Allow authenticated update ot_pos_guest_rating'
    ) THEN
        CREATE POLICY "Allow authenticated update ot_pos_guest_rating" 
            ON public.ot_pos_guest_rating 
            AS PERMISSIVE FOR UPDATE 
            TO authenticated 
            USING (true) 
            WITH CHECK (true);
    END IF;

    -- anon read
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_guest_rating' AND policyname = 'Allow anon read ot_pos_guest_rating'
    ) THEN
        CREATE POLICY "Allow anon read ot_pos_guest_rating" 
            ON public.ot_pos_guest_rating 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;

    -- anon insert
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_guest_rating' AND policyname = 'Allow anon insert ot_pos_guest_rating'
    ) THEN
        CREATE POLICY "Allow anon insert ot_pos_guest_rating" 
            ON public.ot_pos_guest_rating 
            AS PERMISSIVE FOR INSERT 
            TO anon 
            WITH CHECK (true);
    END IF;

    -- anon update
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_guest_rating' AND policyname = 'Allow anon update ot_pos_guest_rating'
    ) THEN
        CREATE POLICY "Allow anon update ot_pos_guest_rating" 
            ON public.ot_pos_guest_rating 
            AS PERMISSIVE FOR UPDATE 
            TO anon 
            USING (true) 
            WITH CHECK (true);
    END IF;
END $$;

-- Table Grants
GRANT ALL ON TABLE public.ot_pos_guest_rating TO postgres, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.ot_pos_guest_rating TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ot_pos_guest_rating TO anon;
