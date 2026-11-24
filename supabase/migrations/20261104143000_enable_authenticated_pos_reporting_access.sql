-- Supabase Migration: Enable authenticated read access for POS and HR reporting tables
-- Description: Grants SELECT privileges and creates permissive RLS read policies for authenticated users (Roles 5, 8, 13, etc.) on all POS and HR reporting tables.

SET ROLE postgres;

-- 1. Table Grants to authenticated
GRANT SELECT ON TABLE public.master_outlet TO authenticated;
GRANT SELECT ON TABLE public.ot_pos_trans_master TO authenticated;
GRANT SELECT ON TABLE public.ot_pos_trans_detail TO authenticated;
GRANT SELECT ON TABLE public.ot_pos_trans_payment TO authenticated;
GRANT SELECT ON TABLE public.ot_pos_trans_payment_details TO authenticated;
GRANT SELECT ON TABLE public.ot_pos_trans_reject TO authenticated;
GRANT SELECT ON TABLE public.ot_pos_gc_transaction TO authenticated;
GRANT SELECT ON TABLE public.ot_master_room TO authenticated;
GRANT SELECT ON TABLE public.ot_hrd_absen_harian TO authenticated;
GRANT SELECT ON TABLE public.ot_hrd_karyawan_info TO authenticated;
GRANT SELECT ON TABLE public.pos_trans_point_member TO authenticated;

-- 2. Permissive RLS Policies for authenticated SELECT
DO $$ 
BEGIN
    -- master_outlet
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'master_outlet' AND policyname = 'Allow authenticated read master_outlet'
    ) THEN
        CREATE POLICY "Allow authenticated read master_outlet" 
            ON public.master_outlet 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- ot_pos_trans_master
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_master' AND policyname = 'Allow authenticated read ot_pos_trans_master'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_pos_trans_master" 
            ON public.ot_pos_trans_master 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- ot_pos_trans_detail
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_detail' AND policyname = 'Allow authenticated read ot_pos_trans_detail'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_pos_trans_detail" 
            ON public.ot_pos_trans_detail 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- ot_pos_trans_payment
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_payment' AND policyname = 'Allow authenticated read ot_pos_trans_payment'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_pos_trans_payment" 
            ON public.ot_pos_trans_payment 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- ot_pos_trans_payment_details
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_payment_details' AND policyname = 'Allow authenticated read ot_pos_trans_payment_details'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_pos_trans_payment_details" 
            ON public.ot_pos_trans_payment_details 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- ot_pos_trans_reject
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_trans_reject' AND policyname = 'Allow authenticated read ot_pos_trans_reject'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_pos_trans_reject" 
            ON public.ot_pos_trans_reject 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- ot_pos_gc_transaction
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_gc_transaction' AND policyname = 'Allow authenticated read ot_pos_gc_transaction'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_pos_gc_transaction" 
            ON public.ot_pos_gc_transaction 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- ot_master_room
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

    -- ot_hrd_absen_harian
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_hrd_absen_harian' AND policyname = 'Allow authenticated read ot_hrd_absen_harian'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_hrd_absen_harian" 
            ON public.ot_hrd_absen_harian 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- ot_hrd_karyawan_info
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_hrd_karyawan_info' AND policyname = 'Allow authenticated read ot_hrd_karyawan_info'
    ) THEN
        CREATE POLICY "Allow authenticated read ot_hrd_karyawan_info" 
            ON public.ot_hrd_karyawan_info 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;

    -- pos_trans_point_member
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'pos_trans_point_member' AND policyname = 'Allow authenticated read pos_trans_point_member'
    ) THEN
        CREATE POLICY "Allow authenticated read pos_trans_point_member" 
            ON public.pos_trans_point_member 
            AS PERMISSIVE FOR SELECT 
            TO authenticated 
            USING (true);
    END IF;
END $$;

