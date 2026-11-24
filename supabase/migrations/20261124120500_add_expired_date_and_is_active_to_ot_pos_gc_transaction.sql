-- Supabase Migration: Add expired_date and is_active to ot_pos_gc_transaction
-- Date: 2026-11-24
-- Description:
--   Supports direct ZenSystem Desktop & SyncAgent Gift Certificate (GC) lifecycle
--   on Supabase without legacy central MySQL server (MERGERDBNAME):
--   1. Adds expired_date (DATE) and is_active (BOOLEAN DEFAULT true NOT NULL)
--   2. Backfills expired_date (buy_at WIB + 120 days) for existing rows
--   3. Adds index on is_active and reloads PostgREST schema cache

SET ROLE postgres;

ALTER TABLE public.ot_pos_gc_transaction
    ADD COLUMN IF NOT EXISTS expired_date DATE;

ALTER TABLE public.ot_pos_gc_transaction
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT true;

-- Backfill expired_date for existing sold GCs where expired_date is null
UPDATE public.ot_pos_gc_transaction
SET expired_date = ((buy_at AT TIME ZONE 'Asia/Jakarta')::date + INTERVAL '120 days')::date
WHERE expired_date IS NULL
  AND buy_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_is_active
    ON public.ot_pos_gc_transaction (is_active);

-- Ensure PostgREST immediately recognizes the new columns
NOTIFY pgrst, 'reload schema';
