-- Migration: 20261026113500_master_outlet_update_policy.sql
-- Description: Allow authenticated outlet admins (role 6) to update their own outlet information, and role 8 (Super Admin) to update any outlet.

-- Enable Row Level Security on master_outlet if not already enabled
ALTER TABLE public.master_outlet ENABLE ROW LEVEL SECURITY;

-- Drop policy if already exists
DROP POLICY IF EXISTS "Allow outlet admin update own outlet" ON public.master_outlet;
DROP POLICY IF EXISTS "Allow authenticated update master_outlet" ON public.master_outlet;

-- Create update policy
CREATE POLICY "Allow outlet admin update own outlet"
ON public.master_outlet
FOR UPDATE
TO authenticated
USING (
  -- Super admin (role 8) can update any outlet
  EXISTS (
    SELECT 1 FROM public.users_profile 
    WHERE uid = auth.uid() AND (user_role = 8 OR role_user = 8)
  )
  OR
  -- Outlet admin (role 6) can update their own outlet
  (
    kode_outlet = (
      SELECT kode_outlet FROM public.users_profile 
      WHERE uid = auth.uid()
    )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.users_profile 
    WHERE uid = auth.uid() AND (user_role = 8 OR role_user = 8)
  )
  OR
  (
    kode_outlet = (
      SELECT kode_outlet FROM public.users_profile 
      WHERE uid = auth.uid()
    )
  )
);

-- Ensure authenticated can also read group_outlet for group_name display
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'group_outlet') THEN
    ALTER TABLE public.group_outlet ENABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS "Allow authenticated read group_outlet" ON public.group_outlet;
    CREATE POLICY "Allow authenticated read group_outlet" ON public.group_outlet FOR SELECT TO authenticated USING (true);
    GRANT SELECT ON public.group_outlet TO authenticated;
  END IF;
END $$;
