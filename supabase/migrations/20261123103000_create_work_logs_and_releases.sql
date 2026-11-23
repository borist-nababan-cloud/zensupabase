-- ==============================================================================
-- MIGRATION: 20261123103000_create_work_logs_and_releases.sql
-- Description:
--   1. Create helper function public.is_worklogs_superuser() (Role ID = 8 ONLY)
--   2. Create table public.work_logs with indexes and BEFORE INSERT/UPDATE trigger
--   3. Create table public.work_log_releases with updated_at trigger
--   4. Configure RLS (Public SELECT, Strict Role 8 ONLY for INSERT/UPDATE/DELETE)
--   5. Expand MIME types on bucket 'zen-releases' (add .exe) & harden storage RLS
-- ==============================================================================

-- 1. Helper Function: Strict Role ID = 8 (SUPERUSER) ONLY
CREATE OR REPLACE FUNCTION public.is_worklogs_superuser()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users_profile
        WHERE uid = auth.uid()
          AND (user_role = 8 OR role_user = 8)
    );
$$;

GRANT EXECUTE ON FUNCTION public.is_worklogs_superuser() TO anon, authenticated, service_role;

-- 2. Table: public.work_logs
CREATE TABLE IF NOT EXISTS public.work_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tanggal DATE NOT NULL,
    apps_name TEXT NOT NULL,
    path TEXT NOT NULL,
    title TEXT NOT NULL,
    have_done TEXT NOT NULL,
    aksi TEXT NOT NULL DEFAULT 'Diperbarui',
    tested BOOLEAN NOT NULL DEFAULT true,
    trained BOOLEAN NOT NULL DEFAULT false,
    trained_at TIMESTAMPTZ,
    trained_by UUID,
    commit_hash TEXT,
    source_hash TEXT UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_work_logs_tanggal_desc ON public.work_logs(tanggal DESC, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_work_logs_apps_name ON public.work_logs(apps_name);
CREATE INDEX IF NOT EXISTS idx_work_logs_trained ON public.work_logs(trained);

CREATE OR REPLACE FUNCTION public.fn_work_logs_before_write()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    NEW.tested := COALESCE(NEW.tested, true);

    IF TG_OP = 'INSERT' THEN
        IF NEW.trained = true THEN
            IF NEW.trained_at IS NULL THEN
                NEW.trained_at := now();
            END IF;
            NEW.trained_by := COALESCE(NEW.trained_by, auth.uid());
        ELSE
            NEW.trained_at := NULL;
            NEW.trained_by := NULL;
        END IF;
    ELSIF TG_OP = 'UPDATE' THEN
        NEW.updated_at := now();
        IF NEW.trained = true AND COALESCE(OLD.trained, false) = false THEN
            NEW.trained_at := now();
            NEW.trained_by := COALESCE(auth.uid(), NEW.trained_by);
        ELSIF NEW.trained = false AND COALESCE(OLD.trained, false) = true THEN
            NEW.trained_at := NULL;
            NEW.trained_by := NULL;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_logs_before_write ON public.work_logs;
CREATE TRIGGER trg_work_logs_before_write
    BEFORE INSERT OR UPDATE ON public.work_logs
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_work_logs_before_write();

-- 3. Table: public.work_log_releases
CREATE TABLE IF NOT EXISTS public.work_log_releases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_category TEXT UNIQUE NOT NULL,
    app_name TEXT NOT NULL,
    filename TEXT NOT NULL,
    original_name TEXT NOT NULL,
    version TEXT,
    mime_type TEXT,
    size BIGINT NOT NULL DEFAULT 0,
    storage_path TEXT NOT NULL,
    download_url TEXT NOT NULL,
    notes TEXT,
    uploaded_by UUID,
    uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.fn_work_log_releases_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_log_releases_updated_at ON public.work_log_releases;
CREATE TRIGGER trg_work_log_releases_updated_at
    BEFORE UPDATE ON public.work_log_releases
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_work_log_releases_updated_at();

-- 4. Grants & Row Level Security (RLS)
ALTER TABLE public.work_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_log_releases ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.work_logs, public.work_log_releases TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.work_logs, public.work_log_releases TO authenticated, service_role;
GRANT ALL ON public.work_logs, public.work_log_releases TO service_role;

-- Policies on public.work_logs (Public Read, Strict Role 8 Write)
DROP POLICY IF EXISTS "Public can read work_logs" ON public.work_logs;
CREATE POLICY "Public can read work_logs"
    ON public.work_logs FOR SELECT
    TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS "Superuser can insert work_logs" ON public.work_logs;
CREATE POLICY "Superuser can insert work_logs"
    ON public.work_logs FOR INSERT
    TO authenticated
    WITH CHECK (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "Superuser can update work_logs" ON public.work_logs;
CREATE POLICY "Superuser can update work_logs"
    ON public.work_logs FOR UPDATE
    TO authenticated
    USING (public.is_worklogs_superuser())
    WITH CHECK (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "Superuser can delete work_logs" ON public.work_logs;
CREATE POLICY "Superuser can delete work_logs"
    ON public.work_logs FOR DELETE
    TO authenticated
    USING (public.is_worklogs_superuser());

-- Policies on public.work_log_releases (Public Read, Strict Role 8 Write)
DROP POLICY IF EXISTS "Public can read work_log_releases" ON public.work_log_releases;
CREATE POLICY "Public can read work_log_releases"
    ON public.work_log_releases FOR SELECT
    TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS "Superuser can insert work_log_releases" ON public.work_log_releases;
CREATE POLICY "Superuser can insert work_log_releases"
    ON public.work_log_releases FOR INSERT
    TO authenticated
    WITH CHECK (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "Superuser can update work_log_releases" ON public.work_log_releases;
CREATE POLICY "Superuser can update work_log_releases"
    ON public.work_log_releases FOR UPDATE
    TO authenticated
    USING (public.is_worklogs_superuser())
    WITH CHECK (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "Superuser can delete work_log_releases" ON public.work_log_releases;
CREATE POLICY "Superuser can delete work_log_releases"
    ON public.work_log_releases FOR DELETE
    TO authenticated
    USING (public.is_worklogs_superuser());

-- 5. Storage Bucket 'zen-releases': Expand MIME types (.exe support) & Harden RLS (Role 8 ONLY)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'zen-releases',
    'zen-releases',
    true,
    524288000, -- 500MB max file size
    ARRAY[
        'application/zip',
        'application/x-zip-compressed',
        'application/octet-stream',
        'application/vnd.android.package-archive',
        'application/vnd.microsoft.portable-executable',
        'application/x-msdownload',
        'application/x-msdos-program',
        'application/x-dosexec',
        'text/markdown',
        'text/plain'
    ]
)
ON CONFLICT (id) DO UPDATE SET
    public = true,
    file_size_limit = 524288000,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Drop legacy open policies on storage.objects
DROP POLICY IF EXISTS "Allow Select in zen-releases" ON storage.objects;
DROP POLICY IF EXISTS "Public Read Access on zen-releases" ON storage.objects;
DROP POLICY IF EXISTS "Allow Upload to zen-releases" ON storage.objects;
DROP POLICY IF EXISTS "Allow Update to zen-releases" ON storage.objects;
DROP POLICY IF EXISTS "Allow Delete in zen-releases" ON storage.objects;

-- Recreate hardened policies strictly for Role 8 (SUPERUSER)
DROP POLICY IF EXISTS "Superuser select zen-releases" ON storage.objects;
CREATE POLICY "Superuser select zen-releases"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (bucket_id = 'zen-releases' AND public.is_worklogs_superuser());

DROP POLICY IF EXISTS "Superuser insert zen-releases" ON storage.objects;
CREATE POLICY "Superuser insert zen-releases"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (bucket_id = 'zen-releases' AND public.is_worklogs_superuser());

DROP POLICY IF EXISTS "Superuser update zen-releases" ON storage.objects;
CREATE POLICY "Superuser update zen-releases"
    ON storage.objects FOR UPDATE
    TO authenticated
    USING (bucket_id = 'zen-releases' AND public.is_worklogs_superuser())
    WITH CHECK (bucket_id = 'zen-releases' AND public.is_worklogs_superuser());

DROP POLICY IF EXISTS "Superuser delete zen-releases" ON storage.objects;
CREATE POLICY "Superuser delete zen-releases"
    ON storage.objects FOR DELETE
    TO authenticated
    USING (bucket_id = 'zen-releases' AND public.is_worklogs_superuser());

NOTIFY pgrst, 'reload schema';
