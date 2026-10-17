-- Migration: 20261017010000_add_tanggal_to_pos_payment_tables.sql
-- Purpose: Add 'tanggal' DATE column to ot_pos_trans_payment and ot_pos_trans_payment_details
-- for exact, timezone-agnostic business date matching and high-velocity indexing.

-- 1. Add tanggal to ot_pos_trans_payment
ALTER TABLE public.ot_pos_trans_payment 
  ADD COLUMN IF NOT EXISTS tanggal DATE;

-- 2. Add tanggal to ot_pos_trans_payment_details
ALTER TABLE public.ot_pos_trans_payment_details 
  ADD COLUMN IF NOT EXISTS tanggal DATE;

-- 3. Composite Index on (tanggal, kode_outlet) for O(1) daily partition scans
CREATE INDEX IF NOT EXISTS idx_ot_pos_trans_payment_tanggal 
  ON public.ot_pos_trans_payment (tanggal, kode_outlet);

CREATE INDEX IF NOT EXISTS idx_ot_pos_trans_payment_details_tanggal 
  ON public.ot_pos_trans_payment_details (tanggal, kode_outlet);

-- 4. Backfill existing records:
-- Try to get tanggal from ot_pos_trans_master via id_payment first
UPDATE public.ot_pos_trans_payment p
SET tanggal = m.tanggal
FROM public.ot_pos_trans_master m
WHERE p.id_payment = m.id_payment
  AND p.tanggal IS NULL
  AND m.tanggal IS NOT NULL;

UPDATE public.ot_pos_trans_payment_details pd
SET tanggal = m.tanggal
FROM public.ot_pos_trans_master m
WHERE pd.id_payment = m.id_payment
  AND pd.tanggal IS NULL
  AND m.tanggal IS NOT NULL;

-- If still null, backfill from created_at converted to Indonesian Local Time (WIB UTC+7)
UPDATE public.ot_pos_trans_payment
SET tanggal = (created_at AT TIME ZONE 'Asia/Jakarta')::date
WHERE tanggal IS NULL;

UPDATE public.ot_pos_trans_payment_details
SET tanggal = (created_at AT TIME ZONE 'Asia/Jakarta')::date
WHERE tanggal IS NULL;
