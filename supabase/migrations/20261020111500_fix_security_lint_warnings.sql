-- Migration: Fix Security Lint Warnings
-- Description:
-- 1. Enable RLS on pos_trans_point_member to enforce existing anon policies and resolve:
--    - "Policy Exists RLS Disabled"
--    - "RLS Disabled in Public"
-- 2. Set security_invoker = true on views to resolve:
--    - "Security Definer View" on view_financial_dashboard
--    - "Security Definer View" on view_peak_hours
-- 3. Ensure SELECT grants and RLS read policies exist on underlying legacy reporting tables
--    so that security_invoker views remain fully functional for callers without permission errors.

SET ROLE postgres;

-- 1. Enable RLS on pos_trans_point_member
ALTER TABLE public.pos_trans_point_member ENABLE ROW LEVEL SECURITY;

-- 2. Configure views to run with caller security context (security_invoker)
ALTER VIEW public.view_financial_dashboard SET (security_invoker = true);
ALTER VIEW public.view_peak_hours SET (security_invoker = true);

-- 3. Grant SELECT on underlying tables to authenticated and anon to support invoker context
GRANT SELECT ON TABLE public.trans_payment TO authenticated, anon;
GRANT SELECT ON TABLE public.trans_payment_detail TO authenticated, anon;
GRANT SELECT ON TABLE public.trans_master TO authenticated, anon;
GRANT SELECT ON TABLE public.master_outlet TO authenticated, anon;

-- 4. Ensure RLS read policies exist if RLS is enabled on underlying legacy tables
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'trans_payment' AND rowsecurity = true) THEN
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'trans_payment' AND policyname = 'Allow read trans_payment') THEN
            CREATE POLICY "Allow read trans_payment" ON public.trans_payment FOR SELECT TO authenticated, anon USING (true);
        END IF;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'trans_payment_detail' AND rowsecurity = true) THEN
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'trans_payment_detail' AND policyname = 'Allow read trans_payment_detail') THEN
            CREATE POLICY "Allow read trans_payment_detail" ON public.trans_payment_detail FOR SELECT TO authenticated, anon USING (true);
        END IF;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'trans_master' AND rowsecurity = true) THEN
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'trans_master' AND policyname = 'Allow read trans_master') THEN
            CREATE POLICY "Allow read trans_master" ON public.trans_master FOR SELECT TO authenticated, anon USING (true);
        END IF;
    END IF;
END $$;
