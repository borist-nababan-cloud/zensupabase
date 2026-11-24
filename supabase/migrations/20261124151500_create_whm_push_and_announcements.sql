-- ============================================================================
-- Migration: WHM Web Push Notifications & In-App Announcements
-- Date: 2026-11-24
-- Author: Zen Family Spa Architect
-- Description:
--   1. public.is_whm_superuser() helper (strict Role ID = 8 ONLY)
--   2. public.whm_push_subscriptions (per-device Web Push endpoints)
--   3. public.whm_announcements (broadcast history & in-app notification feed)
--   4. public.whm_announcement_reads (per-user read receipts)
--   5. Secure RPCs: get_whm_vapid_public_key, upsert_whm_push_subscription,
--      deactivate_whm_push_subscription, get_whm_push_stats
-- ============================================================================

-- 1. Helper: strict SUPERUSER (Role ID = 8 ONLY)
CREATE OR REPLACE FUNCTION public.is_whm_superuser()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users_profile
    WHERE uid = auth.uid()
      AND user_role = 8
  );
$$;

REVOKE ALL ON FUNCTION public.is_whm_superuser() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_whm_superuser() TO authenticated, service_role;

-- 2. Table: whm_push_subscriptions
CREATE TABLE IF NOT EXISTS public.whm_push_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  user_agent TEXT,
  platform TEXT DEFAULT 'other',
  is_active BOOLEAN NOT NULL DEFAULT true,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_whm_push_sub_user_id
  ON public.whm_push_subscriptions (user_id);

CREATE INDEX IF NOT EXISTS idx_whm_push_sub_active
  ON public.whm_push_subscriptions (is_active)
  WHERE is_active = true;

ALTER TABLE public.whm_push_subscriptions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.whm_push_subscriptions FROM anon;
GRANT SELECT, DELETE ON public.whm_push_subscriptions TO authenticated;
GRANT ALL ON public.whm_push_subscriptions TO service_role;

DROP POLICY IF EXISTS "Users can view own push subscriptions" ON public.whm_push_subscriptions;
CREATE POLICY "Users can view own push subscriptions"
  ON public.whm_push_subscriptions
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own push subscriptions" ON public.whm_push_subscriptions;
CREATE POLICY "Users can delete own push subscriptions"
  ON public.whm_push_subscriptions
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Service role full access push subscriptions" ON public.whm_push_subscriptions;
CREATE POLICY "Service role full access push subscriptions"
  ON public.whm_push_subscriptions
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- 3. Table: whm_announcements
CREATE TABLE IF NOT EXISTS public.whm_announcements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  url TEXT NOT NULL DEFAULT '/dashboard',
  category TEXT NOT NULL DEFAULT 'NEW_MODULE'
    CHECK (category IN ('NEW_MODULE', 'UPDATE', 'MAINTENANCE', 'INFO')),
  target_type TEXT NOT NULL DEFAULT 'ALL'
    CHECK (target_type IN ('ALL', 'ROLES', 'OUTLETS')),
  target_roles INTEGER[],
  target_outlets TEXT[],
  send_push BOOLEAN NOT NULL DEFAULT true,
  push_total_targeted INTEGER NOT NULL DEFAULT 0,
  push_sent_count INTEGER NOT NULL DEFAULT 0,
  push_failed_count INTEGER NOT NULL DEFAULT 0,
  push_cleaned_count INTEGER NOT NULL DEFAULT 0,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_whm_announcements_created_at
  ON public.whm_announcements (created_at DESC);

ALTER TABLE public.whm_announcements ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.whm_announcements FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.whm_announcements TO authenticated;
GRANT ALL ON public.whm_announcements TO service_role;

DROP POLICY IF EXISTS "Authenticated users can read targeted announcements" ON public.whm_announcements;
CREATE POLICY "Authenticated users can read targeted announcements"
  ON public.whm_announcements
  FOR SELECT
  TO authenticated
  USING (
    public.is_whm_superuser()
    OR target_type = 'ALL'
    OR (
      target_type = 'ROLES'
      AND EXISTS (
        SELECT 1
        FROM public.users_profile up
        WHERE up.uid = auth.uid()
          AND up.user_role = ANY(whm_announcements.target_roles)
      )
    )
    OR (
      target_type = 'OUTLETS'
      AND EXISTS (
        SELECT 1
        FROM public.users_profile up
        WHERE up.uid = auth.uid()
          AND up.kode_outlet = ANY(whm_announcements.target_outlets)
      )
    )
  );

DROP POLICY IF EXISTS "Superuser can manage announcements" ON public.whm_announcements;
CREATE POLICY "Superuser can manage announcements"
  ON public.whm_announcements
  FOR ALL
  TO authenticated
  USING (public.is_whm_superuser())
  WITH CHECK (public.is_whm_superuser());

DROP POLICY IF EXISTS "Service role full access announcements" ON public.whm_announcements;
CREATE POLICY "Service role full access announcements"
  ON public.whm_announcements
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- 4. Table: whm_announcement_reads
CREATE TABLE IF NOT EXISTS public.whm_announcement_reads (
  announcement_id UUID NOT NULL REFERENCES public.whm_announcements(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  read_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (announcement_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_whm_announcement_reads_user
  ON public.whm_announcement_reads (user_id);

ALTER TABLE public.whm_announcement_reads ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.whm_announcement_reads FROM anon;
GRANT SELECT, INSERT, DELETE ON public.whm_announcement_reads TO authenticated;
GRANT ALL ON public.whm_announcement_reads TO service_role;

DROP POLICY IF EXISTS "Users can manage own announcement reads" ON public.whm_announcement_reads;
CREATE POLICY "Users can manage own announcement reads"
  ON public.whm_announcement_reads
  FOR ALL
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- 5. RPC: get_whm_vapid_public_key (public applicationServerKey only — never private key)
CREATE OR REPLACE FUNCTION public.get_whm_vapid_public_key()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 'BDdNiPrekWoNUk9fUN99cxDAZRbFDzauJOxuyVla9tbAYHX-AEnR_OBurrQbcedg8b2InsPoQqhbXJh7Na0YB_U'::TEXT;
$$;

REVOKE ALL ON FUNCTION public.get_whm_vapid_public_key() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_whm_vapid_public_key() TO authenticated, service_role;

-- 6. RPC: upsert_whm_push_subscription (handles shared device account switches cleanly)
CREATE OR REPLACE FUNCTION public.upsert_whm_push_subscription(
  p_endpoint TEXT,
  p_p256dh TEXT,
  p_auth TEXT,
  p_user_agent TEXT DEFAULT NULL,
  p_platform TEXT DEFAULT 'other'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_id UUID;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_endpoint IS NULL OR length(trim(p_endpoint)) < 10
     OR p_p256dh IS NULL OR length(trim(p_p256dh)) < 10
     OR p_auth IS NULL OR length(trim(p_auth)) < 10 THEN
    RAISE EXCEPTION 'Invalid push subscription payload' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.whm_push_subscriptions (
    user_id, endpoint, p256dh, auth, user_agent, platform, is_active, last_seen_at, updated_at
  )
  VALUES (
    v_uid, trim(p_endpoint), trim(p_p256dh), trim(p_auth),
    left(coalesce(p_user_agent, ''), 500),
    coalesce(nullif(trim(p_platform), ''), 'other'),
    true, now(), now()
  )
  ON CONFLICT (endpoint) DO UPDATE SET
    user_id = EXCLUDED.user_id,
    p256dh = EXCLUDED.p256dh,
    auth = EXCLUDED.auth,
    user_agent = EXCLUDED.user_agent,
    platform = EXCLUDED.platform,
    is_active = true,
    last_seen_at = now(),
    updated_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_whm_push_subscription(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_whm_push_subscription(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- 7. RPC: deactivate_whm_push_subscription
CREATE OR REPLACE FUNCTION public.deactivate_whm_push_subscription(
  p_endpoint TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_rows INTEGER;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.whm_push_subscriptions
  SET is_active = false, updated_at = now()
  WHERE endpoint = trim(p_endpoint)
    AND user_id = v_uid;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.deactivate_whm_push_subscription(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.deactivate_whm_push_subscription(TEXT) TO authenticated;

-- 8. RPC: get_whm_push_stats (SUPERUSER Role 8 ONLY — aggregate stats, never leaks keys)
CREATE OR REPLACE FUNCTION public.get_whm_push_stats()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active_devices INTEGER;
  v_unique_users INTEGER;
  v_by_platform JSONB;
BEGIN
  IF NOT public.is_whm_superuser() THEN
    RAISE EXCEPTION 'Forbidden: Role 8 SUPERUSER required' USING ERRCODE = '42501';
  END IF;

  SELECT
    COUNT(*)::INTEGER,
    COUNT(DISTINCT user_id)::INTEGER
  INTO v_active_devices, v_unique_users
  FROM public.whm_push_subscriptions
  WHERE is_active = true;

  SELECT COALESCE(jsonb_object_agg(platform_key, cnt), '{}'::jsonb)
  INTO v_by_platform
  FROM (
    SELECT COALESCE(NULLIF(platform, ''), 'other') AS platform_key, COUNT(*)::INTEGER AS cnt
    FROM public.whm_push_subscriptions
    WHERE is_active = true
    GROUP BY 1
  ) t;

  RETURN jsonb_build_object(
    'active_devices', COALESCE(v_active_devices, 0),
    'unique_users', COALESCE(v_unique_users, 0),
    'by_platform', COALESCE(v_by_platform, '{}'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_whm_push_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_whm_push_stats() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
