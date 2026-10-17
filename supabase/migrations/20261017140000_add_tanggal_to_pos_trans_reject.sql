-- Migration: 20261017140000_add_tanggal_to_pos_trans_reject.sql
-- Purpose: Add 'tanggal' DATE column to ot_pos_trans_reject for exact, timezone-agnostic
-- business date partitioning, matching ot_pos_trans_master, detail, and payment tables.

SET ROLE postgres;

-- 1. Add tanggal column to ot_pos_trans_reject
ALTER TABLE public.ot_pos_trans_reject 
  ADD COLUMN IF NOT EXISTS tanggal DATE;

-- 2. Create composite index on (tanggal, kode_outlet) for instant date queries
CREATE INDEX IF NOT EXISTS idx_ot_pos_trans_reject_tanggal 
  ON public.ot_pos_trans_reject (tanggal, kode_outlet);

-- 3. Backfill existing records from reject_date (converted to DATE)
UPDATE public.ot_pos_trans_reject
SET tanggal = reject_date::date
WHERE tanggal IS NULL
  AND reject_date IS NOT NULL;
