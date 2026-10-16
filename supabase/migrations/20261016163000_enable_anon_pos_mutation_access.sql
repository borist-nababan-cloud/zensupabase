-- Supabase Migration: Enable anon update and insert access for POS Sync
-- Description: Grants UPDATE and INSERT privileges and creates RLS policies for anon role on POS transaction tables to enable idempotent upserts and payment reconciliation.

SET ROLE postgres;

-- 1. Table Grants to anon
GRANT SELECT, INSERT, UPDATE ON TABLE public.ot_pos_trans_master TO anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ot_pos_trans_detail TO anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ot_pos_trans_payment TO anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ot_pos_trans_payment_details TO anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ot_pos_trans_reject TO anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.pos_trans_point_member TO anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ot_pos_gc_transaction TO anon;

-- 2. RLS Policies for anon UPDATE & INSERT
DO $$ 
BEGIN
    -- ot_pos_trans_master UPDATE
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_master' AND policyname = 'Allow anon update ot_pos_trans_master'
    ) THEN
        CREATE POLICY "Allow anon update ot_pos_trans_master" 
            ON public.ot_pos_trans_master 
            FOR UPDATE 
            TO anon 
            USING (true) 
            WITH CHECK (true);
    END IF;

    -- ot_pos_trans_master INSERT
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_master' AND policyname = 'Allow anon insert ot_pos_trans_master'
    ) THEN
        CREATE POLICY "Allow anon insert ot_pos_trans_master" 
            ON public.ot_pos_trans_master 
            FOR INSERT 
            TO anon 
            WITH CHECK (true);
    END IF;

    -- ot_pos_trans_detail UPDATE
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_detail' AND policyname = 'Allow anon update ot_pos_trans_detail'
    ) THEN
        CREATE POLICY "Allow anon update ot_pos_trans_detail" 
            ON public.ot_pos_trans_detail 
            FOR UPDATE 
            TO anon 
            USING (true) 
            WITH CHECK (true);
    END IF;

    -- ot_pos_trans_detail INSERT
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_detail' AND policyname = 'Allow anon insert ot_pos_trans_detail'
    ) THEN
        CREATE POLICY "Allow anon insert ot_pos_trans_detail" 
            ON public.ot_pos_trans_detail 
            FOR INSERT 
            TO anon 
            WITH CHECK (true);
    END IF;

    -- ot_pos_trans_payment UPDATE
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_payment' AND policyname = 'Allow anon update ot_pos_trans_payment'
    ) THEN
        CREATE POLICY "Allow anon update ot_pos_trans_payment" 
            ON public.ot_pos_trans_payment 
            FOR UPDATE 
            TO anon 
            USING (true) 
            WITH CHECK (true);
    END IF;

    -- ot_pos_trans_payment INSERT
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_payment' AND policyname = 'Allow anon insert ot_pos_trans_payment'
    ) THEN
        CREATE POLICY "Allow anon insert ot_pos_trans_payment" 
            ON public.ot_pos_trans_payment 
            FOR INSERT 
            TO anon 
            WITH CHECK (true);
    END IF;

    -- ot_pos_trans_payment_details UPDATE
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_payment_details' AND policyname = 'Allow anon update ot_pos_trans_payment_details'
    ) THEN
        CREATE POLICY "Allow anon update ot_pos_trans_payment_details" 
            ON public.ot_pos_trans_payment_details 
            FOR UPDATE 
            TO anon 
            USING (true) 
            WITH CHECK (true);
    END IF;

    -- ot_pos_trans_payment_details INSERT
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_payment_details' AND policyname = 'Allow anon insert ot_pos_trans_payment_details'
    ) THEN
        CREATE POLICY "Allow anon insert ot_pos_trans_payment_details" 
            ON public.ot_pos_trans_payment_details 
            FOR INSERT 
            TO anon 
            WITH CHECK (true);
    END IF;

    -- ot_pos_gc_transaction UPDATE
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_gc_transaction' AND policyname = 'Allow anon update ot_pos_gc_transaction'
    ) THEN
        CREATE POLICY "Allow anon update ot_pos_gc_transaction" 
            ON public.ot_pos_gc_transaction 
            FOR UPDATE 
            TO anon 
            USING (true) 
            WITH CHECK (true);
    END IF;

    -- ot_pos_gc_transaction INSERT
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_gc_transaction' AND policyname = 'Allow anon insert ot_pos_gc_transaction'
    ) THEN
        CREATE POLICY "Allow anon insert ot_pos_gc_transaction" 
            ON public.ot_pos_gc_transaction 
            FOR INSERT 
            TO anon 
            WITH CHECK (true);
    END IF;

    -- pos_trans_point_member UPDATE
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'pos_trans_point_member' AND policyname = 'Allow anon update pos_trans_point_member'
    ) THEN
        CREATE POLICY "Allow anon update pos_trans_point_member" 
            ON public.pos_trans_point_member 
            FOR UPDATE 
            TO anon 
            USING (true) 
            WITH CHECK (true);
    END IF;

    -- pos_trans_point_member INSERT
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'pos_trans_point_member' AND policyname = 'Allow anon insert pos_trans_point_member'
    ) THEN
        CREATE POLICY "Allow anon insert pos_trans_point_member" 
            ON public.pos_trans_point_member 
            FOR INSERT 
            TO anon 
            WITH CHECK (true);
    END IF;

    -- ot_pos_trans_reject UPDATE
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_reject' AND policyname = 'Allow anon update ot_pos_trans_reject'
    ) THEN
        CREATE POLICY "Allow anon update ot_pos_trans_reject" 
            ON public.ot_pos_trans_reject 
            FOR UPDATE 
            TO anon 
            USING (true) 
            WITH CHECK (true);
    END IF;

    -- ot_pos_trans_reject INSERT
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_reject' AND policyname = 'Allow anon insert ot_pos_trans_reject'
    ) THEN
        CREATE POLICY "Allow anon insert ot_pos_trans_reject" 
            ON public.ot_pos_trans_reject 
            FOR INSERT 
            TO anon 
            WITH CHECK (true);
    END IF;
END $$;
