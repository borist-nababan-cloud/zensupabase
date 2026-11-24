-- ==============================================================================
-- MIGRATION: 20261026201500_update_master_issue_category_is_active_and_no_delete.sql
-- Description:
-- 1. Add is_active column to public.master_issue_category (defaults to true).
-- 2. Explicitly revoke DELETE permissions on public.master_issue_category.
-- 3. Ensure no DELETE policy exists and maintain strict SELECT, INSERT, UPDATE policies.
-- 4. Add update_at automatic timestamp trigger.
-- ==============================================================================

-- 1. ADD is_active COLUMN
ALTER TABLE public.master_issue_category 
ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true NOT NULL;

-- 2. AUTOMATIC TIMESTAMP TRIGGER FOR update_at
CREATE OR REPLACE FUNCTION fn_update_master_issue_category_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.update_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_master_issue_category_timestamp ON public.master_issue_category;
CREATE TRIGGER trg_master_issue_category_timestamp
BEFORE UPDATE ON public.master_issue_category
FOR EACH ROW
EXECUTE FUNCTION fn_update_master_issue_category_timestamp();

-- 3. ENSURE RLS POLICIES (NO DELETE ALLOWED)
ALTER TABLE public.master_issue_category ENABLE ROW LEVEL SECURITY;

-- Drop any previous delete policies
DROP POLICY IF EXISTS "Allow authenticated delete master_issue_category" ON public.master_issue_category;
DROP POLICY IF EXISTS "Allow anon delete master_issue_category" ON public.master_issue_category;

-- Ensure SELECT policy
DROP POLICY IF EXISTS "Allow authenticated read master_issue_category" ON public.master_issue_category;
CREATE POLICY "Allow authenticated read master_issue_category" 
ON public.master_issue_category FOR SELECT 
TO authenticated, anon 
USING (true);

-- Ensure INSERT policy
DROP POLICY IF EXISTS "Allow authenticated insert master_issue_category" ON public.master_issue_category;
CREATE POLICY "Allow authenticated insert master_issue_category" 
ON public.master_issue_category FOR INSERT 
TO authenticated 
WITH CHECK (true);

-- Ensure UPDATE policy
DROP POLICY IF EXISTS "Allow authenticated update master_issue_category" ON public.master_issue_category;
CREATE POLICY "Allow authenticated update master_issue_category" 
ON public.master_issue_category FOR UPDATE 
TO authenticated 
USING (true);

-- 4. REVOKE DELETE PRIVILEGE
REVOKE DELETE ON public.master_issue_category FROM authenticated, anon;
GRANT SELECT, INSERT, UPDATE ON public.master_issue_category TO authenticated;
GRANT SELECT ON public.master_issue_category TO anon;
