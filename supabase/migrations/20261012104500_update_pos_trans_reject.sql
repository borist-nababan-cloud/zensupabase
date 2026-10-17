-- Supabase Migration: Update ot_pos_trans_reject schema and add upsert constraint
SET ROLE postgres;

-- 1. Remove obsolete trans_id column
DO $$ 
BEGIN
    ALTER TABLE public.ot_pos_trans_reject DROP COLUMN IF EXISTS trans_id;
EXCEPTION WHEN others THEN null;
END $$;

-- 2. Add jenis_jasa and lasteditdate columns
DO $$ 
BEGIN
    ALTER TABLE public.ot_pos_trans_reject ADD COLUMN IF NOT EXISTS jenis_jasa TEXT;
    ALTER TABLE public.ot_pos_trans_reject ADD COLUMN IF NOT EXISTS lasteditdate TIMESTAMPTZ;
EXCEPTION WHEN others THEN null;
END $$;

-- 3. Add Unique Constraint on (kode_outlet, local_autonum) for multi-outlet upserts
DO $$ 
BEGIN
    ALTER TABLE public.ot_pos_trans_reject
    ADD CONSTRAINT uq_pos_trans_reject_autonum UNIQUE (kode_outlet, local_autonum);
EXCEPTION WHEN duplicate_table THEN null; WHEN duplicate_object THEN null;
    WHEN others THEN IF SQLSTATE = '42P07' THEN null; ELSE RAISE; END IF;
END $$;
