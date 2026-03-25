-- Enable Row Level Security on all tables in public schema
DO $$
DECLARE
    table_record RECORD;
BEGIN
    FOR table_record IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'public'
        AND tablename NOT LIKE 'pg_%'
        AND tablename NOT LIKE 'view_%' -- Skip views
    LOOP
        BEGIN
            EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', table_record.tablename);
            RAISE NOTICE 'Enabled RLS on table: %', table_record.tablename;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Could not enable RLS on table: % - %', table_record.tablename, SQLERRM;
        END;
    END LOOP;
END $$;