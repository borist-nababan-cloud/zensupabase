-- Supabase Migration: Add Unique Constraints for POS details to allow Upserts
SET ROLE postgres;

-- 1. ot_pos_trans_payment_details: id_payment is unique since it's 1-to-1 with payment
DO $$ 
BEGIN
    ALTER TABLE public.ot_pos_trans_payment_details
    ADD CONSTRAINT uq_payment_details_id UNIQUE (id_payment);
EXCEPTION WHEN duplicate_table THEN null; WHEN duplicate_object THEN null;
    WHEN others THEN IF SQLSTATE = '42P07' THEN null; ELSE RAISE; END IF;
END $$;

-- 2. ot_pos_trans_detail: Needs local_autonum for upserts
DO $$ 
BEGIN
    ALTER TABLE public.ot_pos_trans_detail ADD COLUMN local_autonum BIGINT;
EXCEPTION WHEN duplicate_column THEN null; END $$;

DO $$ 
BEGIN
    ALTER TABLE public.ot_pos_trans_detail
    ADD CONSTRAINT uq_trans_detail_autonum UNIQUE (kode_outlet, local_autonum);
EXCEPTION WHEN duplicate_table THEN null; WHEN duplicate_object THEN null;
    WHEN others THEN IF SQLSTATE = '42P07' THEN null; ELSE RAISE; END IF;
END $$;

-- 3. pos_trans_point_member: id_payment is unique for point transactions
DO $$ 
BEGIN
    ALTER TABLE public.pos_trans_point_member
    ADD CONSTRAINT uq_point_member_payment UNIQUE (id_payment);
EXCEPTION WHEN duplicate_table THEN null; WHEN duplicate_object THEN null;
    WHEN others THEN IF SQLSTATE = '42P07' THEN null; ELSE RAISE; END IF;
END $$;
