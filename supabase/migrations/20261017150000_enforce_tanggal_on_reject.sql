-- Migration: 20261017150000_enforce_tanggal_on_reject.sql
-- Purpose: Enforce NOT NULL and auto-fill trigger on ot_pos_trans_reject.tanggal
-- Guarantees that business date is always populated in Asia/Jakarta time, permanently
-- preventing timezone conversion mismatches and client device drift.

SET ROLE postgres;

-- 1. Ensure any remaining nulls are filled with Asia/Jakarta calendar date
UPDATE public.ot_pos_trans_reject
SET tanggal = COALESCE(
  (reject_date AT TIME ZONE 'Asia/Jakarta')::date,
  (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Jakarta')::date
)
WHERE tanggal IS NULL;

-- 2. Set default value to Asia/Jakarta current date
ALTER TABLE public.ot_pos_trans_reject
  ALTER COLUMN tanggal SET DEFAULT ((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Jakarta')::date);

-- 3. Set NOT NULL constraint
ALTER TABLE public.ot_pos_trans_reject
  ALTER COLUMN tanggal SET NOT NULL;

-- 4. Create trigger function to ensure tanggal is always assigned on INSERT/UPDATE
CREATE OR REPLACE FUNCTION public.trg_ot_pos_trans_reject_ensure_tanggal()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.tanggal IS NULL THEN
    IF NEW.reject_date IS NOT NULL THEN
      NEW.tanggal := (NEW.reject_date AT TIME ZONE 'Asia/Jakarta')::date;
    ELSE
      NEW.tanggal := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Jakarta')::date;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ensure_tanggal_reject ON public.ot_pos_trans_reject;
CREATE TRIGGER trg_ensure_tanggal_reject
BEFORE INSERT OR UPDATE ON public.ot_pos_trans_reject
FOR EACH ROW
EXECUTE FUNCTION public.trg_ot_pos_trans_reject_ensure_tanggal();
