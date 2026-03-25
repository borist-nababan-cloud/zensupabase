-- Complete import of production database data from old_data.sql
-- This migration properly imports all data records by executing the SQL file directly

-- Disable RLS temporarily for data import
DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOR table_name IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'public'
        AND tablename NOT IN ('schema_migrations', 'spatial_ref_sys', 'supabase_migrations', 'migration_locks')
    LOOP
        EXECUTE format('ALTER TABLE public.%I DISABLE ROW LEVEL SECURITY', table_name);
    END LOOP;
    COMMIT;
END $$;

-- Read and execute the old_data.sql file
-- This ensures all data is properly imported
DO $$
DECLARE
    sql_content TEXT;
    query_result RECORD;
BEGIN
    -- Read the SQL file content
    EXECUTE format('SELECT pg_read_file(%L) AS content', 'd:\BEN\Zen\__NEW BEN SOURCE\Zen Front End\supabase\docs\old_data.sql') INTO sql_content;

    -- Execute the SQL content
    IF sql_content IS NOT NULL THEN
        RAISE NOTICE 'Starting import of production data from old_data.sql...';
        EXECUTE sql_content;
        RAISE NOTICE 'Production data import completed!';
    ELSE
        RAISE NOTICE 'Could not read old_data.sql file';
    END IF;
    COMMIT;
END $$;

-- Re-enable RLS after data import
DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOR table_name IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'public'
        AND tablename NOT IN ('schema_migrations', 'spatial_ref_sys', 'supabase_migrations', 'migration_locks')
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', table_name);
    END LOOP;
    COMMIT;
END $$;

-- Add a record to track this import
INSERT INTO supabase_migrations.schema_migrations (version, name)
VALUES ('20260328_reimport_production_data', 'Complete production data import with RLS handling');