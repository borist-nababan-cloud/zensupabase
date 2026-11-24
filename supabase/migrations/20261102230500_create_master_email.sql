-- ==============================================================================
-- Migration: Create public.master_email
-- Description: Central notification email directory for automated alerts
--              (Testimonials moderation, Bad reviews alert, Daily/Periodic reports).
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.master_email (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL,
    name TEXT NOT NULL,
    kode_outlet TEXT REFERENCES public.master_outlet(kode_outlet) ON DELETE SET NULL,
    testi_notif BOOLEAN NOT NULL DEFAULT true,
    testi_bad BOOLEAN NOT NULL DEFAULT false,
    daily_report BOOLEAN NOT NULL DEFAULT false,
    periodic_report BOOLEAN NOT NULL DEFAULT false,
    others_report BOOLEAN NOT NULL DEFAULT false,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_master_email_outlet UNIQUE (email, kode_outlet)
);

CREATE INDEX IF NOT EXISTS idx_master_email_active ON public.master_email(active);
CREATE INDEX IF NOT EXISTS idx_master_email_testi_notif ON public.master_email(testi_notif) WHERE active = true;
CREATE INDEX IF NOT EXISTS idx_master_email_testi_bad ON public.master_email(testi_bad) WHERE active = true;
CREATE INDEX IF NOT EXISTS idx_master_email_kode_outlet ON public.master_email(kode_outlet);

-- Automatic updated_at trigger
CREATE OR REPLACE FUNCTION public.handle_master_email_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_master_email_updated_at ON public.master_email;
CREATE TRIGGER trg_master_email_updated_at
    BEFORE UPDATE ON public.master_email
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_master_email_updated_at();

-- Enable RLS
ALTER TABLE public.master_email ENABLE ROW LEVEL SECURITY;

-- Service role has full access (e.g. n8n workflows using service_role)
DROP POLICY IF EXISTS "Service role full access on master_email" ON public.master_email;
CREATE POLICY "Service role full access on master_email"
    ON public.master_email FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Authenticated staff can view and manage master_email (e.g. Supabase Studio / WHM admins)
DROP POLICY IF EXISTS "Authenticated staff can view master_email" ON public.master_email;
CREATE POLICY "Authenticated staff can view master_email"
    ON public.master_email FOR SELECT
    TO authenticated
    USING (true);

DROP POLICY IF EXISTS "Authenticated staff can manage master_email" ON public.master_email;
CREATE POLICY "Authenticated staff can manage master_email"
    ON public.master_email FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

