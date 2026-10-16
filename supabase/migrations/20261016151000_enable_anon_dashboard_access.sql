-- Supabase Migration: Enable anon read access for Zen Dashboard
-- Description: Grants SELECT privileges and creates RLS read policies for anon role on POS and Outlet reporting tables.

SET ROLE postgres;

-- 1. Table Grants to anon
GRANT SELECT ON TABLE public.master_outlet TO anon;
GRANT SELECT ON TABLE public.ot_pos_trans_master TO anon;
GRANT SELECT ON TABLE public.ot_pos_trans_detail TO anon;
GRANT SELECT ON TABLE public.ot_pos_trans_payment TO anon;
GRANT SELECT ON TABLE public.ot_pos_trans_payment_details TO anon;
GRANT SELECT ON TABLE public.ot_pos_trans_reject TO anon;
GRANT SELECT ON TABLE public.pos_trans_point_member TO anon;

-- 2. RLS Policies for anon SELECT
DO $$ 
BEGIN
    -- master_outlet
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'master_outlet' AND policyname = 'Allow anon read master_outlet'
    ) THEN
        CREATE POLICY "Allow anon read master_outlet" 
            ON public.master_outlet 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;

    -- ot_pos_trans_master
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_master' AND policyname = 'Allow anon read ot_pos_trans_master'
    ) THEN
        CREATE POLICY "Allow anon read ot_pos_trans_master" 
            ON public.ot_pos_trans_master 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;

    -- ot_pos_trans_detail
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_detail' AND policyname = 'Allow anon read ot_pos_trans_detail'
    ) THEN
        CREATE POLICY "Allow anon read ot_pos_trans_detail" 
            ON public.ot_pos_trans_detail 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;

    -- ot_pos_trans_payment
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_payment' AND policyname = 'Allow anon read ot_pos_trans_payment'
    ) THEN
        CREATE POLICY "Allow anon read ot_pos_trans_payment" 
            ON public.ot_pos_trans_payment 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;

    -- ot_pos_trans_payment_details
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_payment_details' AND policyname = 'Allow anon read ot_pos_trans_payment_details'
    ) THEN
        CREATE POLICY "Allow anon read ot_pos_trans_payment_details" 
            ON public.ot_pos_trans_payment_details 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;

    -- ot_pos_trans_reject
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_reject' AND policyname = 'Allow anon read ot_pos_trans_reject'
    ) THEN
        CREATE POLICY "Allow anon read ot_pos_trans_reject" 
            ON public.ot_pos_trans_reject 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;

    -- pos_trans_point_member
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'pos_trans_point_member' AND policyname = 'Allow anon read pos_trans_point_member'
    ) THEN
        CREATE POLICY "Allow anon read pos_trans_point_member" 
            ON public.pos_trans_point_member 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;
END $$;
