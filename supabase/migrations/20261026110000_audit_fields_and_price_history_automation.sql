-- Migration: 20261026110000_audit_fields_and_price_history_automation.sql
-- Description:
-- 1. Fix replica identity and primary key on barang_prices to resolve Error 55000 in process_production_run
-- 2. Ensure sequence on barang_price_history.id and create trigger on barang_prices to automatically record price history
-- 3. Add or update audit fields (created_by uuid, created_at timestamptz, update_by uuid, update_at timestamptz) on 12 tables

-- ============================================================================
-- 1. FIX BARANG_PRICES (PRIMARY KEY & REPLICA IDENTITY)
-- ============================================================================
DO $$
BEGIN
    -- Ensure id is primary key so logical replication / updates work seamlessly
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conrelid = 'public.barang_prices'::regclass AND contype = 'p'
    ) THEN
        ALTER TABLE public.barang_prices ADD CONSTRAINT barang_prices_pkey PRIMARY KEY (id);
    END IF;
END $$;

ALTER TABLE public.barang_prices REPLICA IDENTITY FULL;

-- Convert update_by to uuid if it is currently text/varchar
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' AND table_name = 'barang_prices' 
          AND column_name = 'update_by' AND data_type NOT IN ('uuid')
    ) THEN
        ALTER TABLE public.barang_prices 
          ALTER COLUMN update_by TYPE uuid 
          USING (CASE WHEN update_by ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN update_by::uuid ELSE NULL END);
    END IF;
END $$;

-- Convert barang_units.update_by to uuid if needed
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' AND table_name = 'barang_units' 
          AND column_name = 'update_by' AND data_type NOT IN ('uuid')
    ) THEN
        ALTER TABLE public.barang_units 
          ALTER COLUMN update_by TYPE uuid 
          USING (CASE WHEN update_by ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN update_by::uuid ELSE NULL END);
    END IF;
END $$;

-- ============================================================================
-- 2. ENSURE AUDIT FIELDS ON THE 12 TABLES
-- (created_by uuid, created_at timestamptz, update_by uuid, update_at timestamptz)
-- ============================================================================

-- Helper block for all 12 tables
DO $$
DECLARE
    t text;
    tables text[] := ARRAY[
        'barang_units',
        'barang_prices',
        'barang_price_history',
        'master_financial_accounts',
        'master_outlet',
        'master_recipe_items',
        'master_barang',
        'master_shrinkage_categories',
        'master_supplier',
        'sto_invoices',
        'production_run_ingredients',
        'production_run_outputs'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        -- created_by (uuid)
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' AND table_name = t AND column_name = 'created_by'
        ) THEN
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN created_by uuid;', t);
        ELSE
            -- Ensure it is uuid
            IF EXISTS (
                SELECT 1 FROM information_schema.columns 
                WHERE table_schema = 'public' AND table_name = t AND column_name = 'created_by' AND data_type <> 'uuid'
            ) THEN
                EXECUTE format('ALTER TABLE public.%I ALTER COLUMN created_by TYPE uuid USING (CASE WHEN created_by::text ~* ''^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'' THEN created_by::uuid ELSE NULL END);', t);
            END IF;
        END IF;

        -- created_at (timestamptz)
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' AND table_name = t AND column_name = 'created_at'
        ) THEN
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN created_at timestamptz DEFAULT now();', t);
        END IF;

        -- update_by (uuid)
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' AND table_name = t AND column_name = 'update_by'
        ) THEN
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN update_by uuid;', t);
        ELSE
            -- Ensure it is uuid
            IF EXISTS (
                SELECT 1 FROM information_schema.columns 
                WHERE table_schema = 'public' AND table_name = t AND column_name = 'update_by' AND data_type <> 'uuid'
            ) THEN
                EXECUTE format('ALTER TABLE public.%I ALTER COLUMN update_by TYPE uuid USING (CASE WHEN update_by::text ~* ''^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'' THEN update_by::uuid ELSE NULL END);', t);
            END IF;
        END IF;

        -- update_at (timestamptz)
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'public' AND table_name = t AND column_name = 'update_at'
        ) THEN
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN update_at timestamptz DEFAULT now();', t);
        END IF;
    END LOOP;
END $$;

-- ============================================================================
-- 3. BARANG_PRICE_HISTORY SEQUENCE & TRIGGER AUTOMATION
-- ============================================================================

-- Ensure identity or sequence exists for barang_price_history.id
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' AND table_name = 'barang_price_history' 
          AND column_name = 'id' AND (is_identity = 'YES' OR column_default IS NOT NULL)
    ) THEN
        IF NOT EXISTS (SELECT 1 FROM pg_sequences WHERE schemaname = 'public' AND sequencename = 'barang_price_history_id_seq') THEN
            CREATE SEQUENCE public.barang_price_history_id_seq;
        END IF;
        ALTER TABLE public.barang_price_history ALTER COLUMN id SET DEFAULT nextval('public.barang_price_history_id_seq');
        ALTER SEQUENCE public.barang_price_history_id_seq OWNED BY public.barang_price_history.id;
    END IF;
END $$;

-- Price history tracking function
CREATE OR REPLACE FUNCTION public.fn_log_barang_price_history()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id uuid;
BEGIN
    -- Determine user who made the change
    v_user_id := COALESCE(NEW.update_by, NEW.created_by, auth.uid());

    -- Also keep update_at fresh
    NEW.update_at := now();

    -- Track BUY price change
    IF (TG_OP = 'INSERT' AND NEW.buy_price IS NOT NULL) OR 
       (TG_OP = 'UPDATE' AND (OLD.buy_price IS DISTINCT FROM NEW.buy_price)) THEN
        INSERT INTO public.barang_price_history (
            barang_id,
            kode_outlet,
            old_price,
            new_price,
            price_type,
            changed_at,
            changed_by,
            created_by,
            created_at,
            update_by,
            update_at
        ) VALUES (
            NEW.barang_id,
            NEW.kode_outlet,
            CASE WHEN TG_OP = 'UPDATE' THEN OLD.buy_price ELSE NULL END,
            NEW.buy_price,
            'BUY',
            now(),
            v_user_id,
            v_user_id,
            now(),
            v_user_id,
            now()
        );
    END IF;

    -- Track SELL price change
    IF (TG_OP = 'INSERT' AND NEW.sell_price IS NOT NULL) OR 
       (TG_OP = 'UPDATE' AND (OLD.sell_price IS DISTINCT FROM NEW.sell_price)) THEN
        INSERT INTO public.barang_price_history (
            barang_id,
            kode_outlet,
            old_price,
            new_price,
            price_type,
            changed_at,
            changed_by,
            created_by,
            created_at,
            update_by,
            update_at
        ) VALUES (
            NEW.barang_id,
            NEW.kode_outlet,
            CASE WHEN TG_OP = 'UPDATE' THEN OLD.sell_price ELSE NULL END,
            NEW.sell_price,
            'SELL',
            now(),
            v_user_id,
            v_user_id,
            now(),
            v_user_id,
            now()
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Attach trigger to public.barang_prices
DROP TRIGGER IF EXISTS trg_barang_prices_log_history ON public.barang_prices;
CREATE TRIGGER trg_barang_prices_log_history
BEFORE INSERT OR UPDATE ON public.barang_prices
FOR EACH ROW
EXECUTE FUNCTION public.fn_log_barang_price_history();

-- Grant permissions if necessary
GRANT ALL ON public.barang_price_history TO authenticated;
GRANT ALL ON public.barang_price_history TO service_role;
