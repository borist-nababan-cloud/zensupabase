-- Supabase Migration: Create ot_master_room table
-- Description: Master room table for outlet rooms, tracking room status, service types, gender segregation, and amenities.

SET ROLE postgres;

CREATE TABLE IF NOT EXISTS public.ot_master_room (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_outlet TEXT NOT NULL,
    room_id TEXT NOT NULL,
    active BOOLEAN NOT NULL DEFAULT true,
    jenis_jasa TEXT,
    room_gender TEXT,
    available BOOLEAN NOT NULL DEFAULT true,
    keterangan TEXT,
    fasilitas TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by TEXT,
    update_at TIMESTAMPTZ DEFAULT now(),
    update_by TEXT,
    CONSTRAINT uq_master_room_outlet_room UNIQUE (kode_outlet, room_id)
);

-- Indexes for fast querying by outlet and status
CREATE INDEX IF NOT EXISTS idx_ot_master_room_outlet ON public.ot_master_room (kode_outlet);
CREATE INDEX IF NOT EXISTS idx_ot_master_room_status ON public.ot_master_room (active, available);

-- Row Level Security (RLS)
ALTER TABLE public.ot_master_room ENABLE ROW LEVEL SECURITY;

-- RLS Policies
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_master_room' AND policyname = 'Allow service role all on ot_master_room'
    ) THEN
        CREATE POLICY "Allow service role all on ot_master_room" 
            ON public.ot_master_room 
            AS PERMISSIVE FOR ALL 
            TO service_role 
            USING (true) 
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_master_room' AND policyname = 'Allow authenticated read ot_master_room'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_master_room" 
            ON public.ot_master_room 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_master_room' AND policyname = 'Allow authenticated insert ot_master_room'
    ) THEN
        CREATE POLICY "Allow authenticated insert ot_master_room" 
            ON public.ot_master_room 
            AS PERMISSIVE FOR INSERT 
            TO authenticated 
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_master_room' AND policyname = 'Allow authenticated update ot_master_room'
    ) THEN
        CREATE POLICY "Allow authenticated update ot_master_room" 
            ON public.ot_master_room 
            AS PERMISSIVE FOR UPDATE 
            TO authenticated 
            USING (true) 
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_master_room' AND policyname = 'Allow anon read ot_master_room'
    ) THEN
        CREATE POLICY "Allow anon read ot_master_room" 
            ON public.ot_master_room 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;
END $$;

-- Table Grants
GRANT ALL ON TABLE public.ot_master_room TO postgres, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.ot_master_room TO authenticated;
GRANT SELECT ON TABLE public.ot_master_room TO anon;
