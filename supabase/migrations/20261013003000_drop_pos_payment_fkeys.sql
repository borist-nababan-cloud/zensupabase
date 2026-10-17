-- Supabase Migration: Drop restrictive payment foreign keys on POS transaction master & detail
-- Description: In hybrid cloud sync, POS transaction sessions are created upon check-in, 
-- while payments occur upon check-out (or across 12-hour sync window boundaries).
-- Enforcing hard foreign keys on id_payment causes batch sync rejections when master records
-- sync before their respective payment records. Dropping the foreign key constraint allows
-- seamless asynchronous ingestion while preserving indexed relational queries and JOINs.

SET ROLE postgres;

DO $$ 
BEGIN 
  -- 1. Drop FK on ot_pos_trans_master.id_payment
  IF EXISTS (
    SELECT 1 FROM information_schema.table_constraints 
    WHERE constraint_name = 'ot_pos_trans_master_id_payment_fkey' 
      AND table_name = 'ot_pos_trans_master'
  ) THEN 
    ALTER TABLE public.ot_pos_trans_master DROP CONSTRAINT ot_pos_trans_master_id_payment_fkey;
  END IF;

  -- 2. Drop FK on ot_pos_trans_detail.id_payment
  IF EXISTS (
    SELECT 1 FROM information_schema.table_constraints 
    WHERE constraint_name = 'ot_pos_trans_detail_id_payment_fkey' 
      AND table_name = 'ot_pos_trans_detail'
  ) THEN 
    ALTER TABLE public.ot_pos_trans_detail DROP CONSTRAINT ot_pos_trans_detail_id_payment_fkey;
  END IF;
END $$;

-- Ensure indexes exist for high performance JOINs
CREATE INDEX IF NOT EXISTS idx_ot_pos_trans_master_id_payment ON public.ot_pos_trans_master(id_payment);
CREATE INDEX IF NOT EXISTS idx_ot_pos_trans_detail_id_payment ON public.ot_pos_trans_detail(id_payment);
