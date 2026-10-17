-- Supabase Migration: Add unique constraint and decouple payment FKs on ot_pos_gc_transaction
-- Description: Enables idempotent UPSERT/ignore-duplicates on gc_number and decouples payment foreign keys for asynchronous hybrid sync.

SET ROLE postgres;

-- 1. Drop restrictive foreign keys on id_payment if they exist
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'ot_pos_gc_transaction_id_payment_buy_fkey' 
          AND table_name = 'ot_pos_gc_transaction'
    ) THEN
        ALTER TABLE public.ot_pos_gc_transaction 
            DROP CONSTRAINT ot_pos_gc_transaction_id_payment_buy_fkey;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'ot_pos_gc_transaction_id_payment_used_fkey' 
          AND table_name = 'ot_pos_gc_transaction'
    ) THEN
        ALTER TABLE public.ot_pos_gc_transaction 
            DROP CONSTRAINT ot_pos_gc_transaction_id_payment_used_fkey;
    END IF;
END $$;

-- 2. Add performance B-Tree indexes for payment lookups
CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_payment_buy ON public.ot_pos_gc_transaction (id_payment_buy);
CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_payment_used ON public.ot_pos_gc_transaction (id_payment_used);

-- 3. Add UNIQUE constraint on gc_number for PostgREST on_conflict / ignore-duplicates resolution
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'uq_pos_gc_trans_gc_number' 
          AND table_name = 'ot_pos_gc_transaction'
    ) THEN
        ALTER TABLE public.ot_pos_gc_transaction 
            ADD CONSTRAINT uq_pos_gc_trans_gc_number UNIQUE (gc_number);
    END IF;
END $$;

-- 4. Add index on gc_number and kode_outlet_buy
CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_gc_number ON public.ot_pos_gc_transaction (gc_number);
CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_outlet_buy ON public.ot_pos_gc_transaction (kode_outlet_buy);

-- 5. Row Level Security and Grants
ALTER TABLE public.ot_pos_gc_transaction ENABLE ROW LEVEL SECURITY;

DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_gc_transaction' AND policyname = 'Allow service role all on ot_pos_gc_transaction'
    ) THEN
        CREATE POLICY "Allow service role all on ot_pos_gc_transaction" 
            ON public.ot_pos_gc_transaction 
            AS PERMISSIVE FOR ALL 
            TO service_role 
            USING (true) 
            WITH CHECK (true);
    END IF;

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

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_gc_transaction' AND policyname = 'Allow authenticated insert ot_pos_gc_transaction'
    ) THEN
        CREATE POLICY "Allow authenticated insert ot_pos_gc_transaction" 
            ON public.ot_pos_gc_transaction 
            AS PERMISSIVE FOR INSERT 
            TO authenticated 
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'ot_pos_gc_transaction' AND policyname = 'Allow anon read ot_pos_gc_transaction'
    ) THEN
        CREATE POLICY "Allow anon read ot_pos_gc_transaction" 
            ON public.ot_pos_gc_transaction 
            AS PERMISSIVE FOR SELECT 
            TO anon 
            USING (true);
    END IF;
END $$;

GRANT ALL ON TABLE public.ot_pos_gc_transaction TO postgres, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.ot_pos_gc_transaction TO authenticated;
GRANT SELECT ON TABLE public.ot_pos_gc_transaction TO anon;
