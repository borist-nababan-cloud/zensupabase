-- Supabase Migration: Create ot_pos_tr_flow_master & ot_pos_tr_flow_detail with 2-day retention and daily status_slot rollover
-- Description:
--   1. public.ot_pos_tr_flow_master: Stores daily therapist flow slot toggle (0=ATAS, 1=BAWAH) per outlet.
--      Automatically retains only 2 days (today and yesterday in Asia/Jakarta WIB).
--   2. public.ot_pos_tr_flow_detail: Stores current therapist group & slot order per outlet (no date key needed;
--      updated on-demand when branch adjusts therapist group/slot rotation).
--   3. public.fn_rollover_tr_flow_master(): Daily automation scheduled via pg_cron at 00:05 WIB (17:05 UTC)
--      to flip status_slot (0 <-> 1) opposite of yesterday and prune rows older than yesterday.

SET ROLE postgres;

-- ============================================================================
-- 1. TABLE: public.ot_pos_tr_flow_master
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.ot_pos_tr_flow_master (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_outlet TEXT NOT NULL,
    tanggal DATE NOT NULL DEFAULT ((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Jakarta')::date),
    status_slot SMALLINT NOT NULL CHECK (status_slot IN (0, 1)),
    source TEXT NOT NULL DEFAULT 'DESKTOP',
    updated_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_tr_flow_master_outlet_tanggal UNIQUE (kode_outlet, tanggal)
);

CREATE INDEX IF NOT EXISTS idx_ot_pos_tr_flow_master_outlet_tanggal
    ON public.ot_pos_tr_flow_master (kode_outlet, tanggal DESC);

CREATE INDEX IF NOT EXISTS idx_ot_pos_tr_flow_master_tanggal
    ON public.ot_pos_tr_flow_master (tanggal DESC);

-- ============================================================================
-- 2. TABLE: public.ot_pos_tr_flow_detail
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.ot_pos_tr_flow_detail (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_outlet TEXT NOT NULL,
    kodekaryawan TEXT NOT NULL,
    idkaryawan TEXT,
    namakaryawan TEXT,
    departemen TEXT NOT NULL CHECK (departemen IN ('TR', 'TB')),
    ngroup TEXT,
    noslot TEXT,
    updated_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_tr_flow_detail_outlet_karyawan UNIQUE (kode_outlet, kodekaryawan)
);

CREATE INDEX IF NOT EXISTS idx_ot_pos_tr_flow_detail_outlet_dept
    ON public.ot_pos_tr_flow_detail (kode_outlet, departemen, ngroup, noslot);

-- ============================================================================
-- 3. TRIGGERS: updated_at & 2-day retention on ot_pos_tr_flow_master
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_tr_flow_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tr_flow_master_updated_at ON public.ot_pos_tr_flow_master;
CREATE TRIGGER trg_tr_flow_master_updated_at
    BEFORE UPDATE ON public.ot_pos_tr_flow_master
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_tr_flow_set_updated_at();

DROP TRIGGER IF EXISTS trg_tr_flow_detail_updated_at ON public.ot_pos_tr_flow_detail;
CREATE TRIGGER trg_tr_flow_detail_updated_at
    BEFORE UPDATE ON public.ot_pos_tr_flow_detail
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_tr_flow_set_updated_at();

-- Keep only today and yesterday (WIB) per outlet on ot_pos_tr_flow_master
CREATE OR REPLACE FUNCTION public.fn_tr_flow_master_keep_two_days()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_yesterday DATE;
BEGIN
    v_yesterday := ((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Jakarta')::date - INTERVAL '1 day')::date;

    DELETE FROM public.ot_pos_tr_flow_master
    WHERE kode_outlet = NEW.kode_outlet
      AND tanggal < v_yesterday;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tr_flow_master_keep_two_days ON public.ot_pos_tr_flow_master;
CREATE TRIGGER trg_tr_flow_master_keep_two_days
    AFTER INSERT OR UPDATE ON public.ot_pos_tr_flow_master
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_tr_flow_master_keep_two_days();

-- ============================================================================
-- 4. DAILY ROLLOVER FUNCTION (0 <-> 1 opposite of yesterday)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_rollover_tr_flow_master()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_today DATE;
    v_yesterday DATE;
    v_inserted INTEGER := 0;
    v_pruned INTEGER := 0;
BEGIN
    v_today := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Jakarta')::date;
    v_yesterday := (v_today - INTERVAL '1 day')::date;

    -- Flip status_slot opposite of yesterday for every outlet not yet set today
    INSERT INTO public.ot_pos_tr_flow_master (
        kode_outlet,
        tanggal,
        status_slot,
        source,
        updated_by,
        created_at,
        updated_at
    )
    SELECT
        m.kode_outlet,
        v_today,
        CASE WHEN m.status_slot = 0 THEN 1 ELSE 0 END,
        'AUTO_CRON',
        'pg_cron',
        now(),
        now()
    FROM public.ot_pos_tr_flow_master m
    WHERE m.tanggal = v_yesterday
    ON CONFLICT (kode_outlet, tanggal) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- Prune any records older than yesterday across all outlets
    DELETE FROM public.ot_pos_tr_flow_master
    WHERE tanggal < v_yesterday;

    GET DIAGNOSTICS v_pruned = ROW_COUNT;

    RETURN jsonb_build_object(
        'today_wib', v_today,
        'yesterday_wib', v_yesterday,
        'inserted_count', v_inserted,
        'pruned_count', v_pruned,
        'executed_at', now()
    );
END;
$$;

REVOKE ALL ON FUNCTION public.fn_rollover_tr_flow_master() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_rollover_tr_flow_master() TO postgres, service_role;

-- ============================================================================
-- 5. PG_CRON SCHEDULE (00:05 WIB = 17:05 UTC daily)
-- ============================================================================
DO $$
DECLARE
    v_job_id BIGINT;
BEGIN
    BEGIN
        CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'pg_cron extension creation skipped or managed by Supabase: %', SQLERRM;
    END;

    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cron') THEN
        FOR v_job_id IN
            SELECT jobid FROM cron.job WHERE jobname = 'zen_rollover_tr_flow_master'
        LOOP
            PERFORM cron.unschedule(v_job_id);
        END LOOP;

        PERFORM cron.schedule(
            'zen_rollover_tr_flow_master',
            '5 17 * * *',
            'SELECT public.fn_rollover_tr_flow_master();'
        );
    ELSE
        RAISE NOTICE 'cron schema not available in this environment; schedule zen_rollover_tr_flow_master skipped.';
    END IF;
END $$;

-- ============================================================================
-- 6. ROW LEVEL SECURITY (RLS) & GRANTS
-- ============================================================================
ALTER TABLE public.ot_pos_tr_flow_master ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ot_pos_tr_flow_detail ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    -- ot_pos_tr_flow_master policies
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'ot_pos_tr_flow_master' AND policyname = 'Allow service role all on ot_pos_tr_flow_master'
    ) THEN
        CREATE POLICY "Allow service role all on ot_pos_tr_flow_master"
            ON public.ot_pos_tr_flow_master
            AS PERMISSIVE FOR ALL
            TO service_role
            USING (true)
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'ot_pos_tr_flow_master' AND policyname = 'Allow authenticated all on ot_pos_tr_flow_master'
    ) THEN
        CREATE POLICY "Allow authenticated all on ot_pos_tr_flow_master"
            ON public.ot_pos_tr_flow_master
            AS PERMISSIVE FOR ALL
            TO authenticated
            USING (true)
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'ot_pos_tr_flow_master' AND policyname = 'Allow anon read ot_pos_tr_flow_master'
    ) THEN
        CREATE POLICY "Allow anon read ot_pos_tr_flow_master"
            ON public.ot_pos_tr_flow_master
            AS PERMISSIVE FOR SELECT
            TO anon
            USING (true);
    END IF;

    -- ot_pos_tr_flow_detail policies
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'ot_pos_tr_flow_detail' AND policyname = 'Allow service role all on ot_pos_tr_flow_detail'
    ) THEN
        CREATE POLICY "Allow service role all on ot_pos_tr_flow_detail"
            ON public.ot_pos_tr_flow_detail
            AS PERMISSIVE FOR ALL
            TO service_role
            USING (true)
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'ot_pos_tr_flow_detail' AND policyname = 'Allow authenticated all on ot_pos_tr_flow_detail'
    ) THEN
        CREATE POLICY "Allow authenticated all on ot_pos_tr_flow_detail"
            ON public.ot_pos_tr_flow_detail
            AS PERMISSIVE FOR ALL
            TO authenticated
            USING (true)
            WITH CHECK (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'ot_pos_tr_flow_detail' AND policyname = 'Allow anon read ot_pos_tr_flow_detail'
    ) THEN
        CREATE POLICY "Allow anon read ot_pos_tr_flow_detail"
            ON public.ot_pos_tr_flow_detail
            AS PERMISSIVE FOR SELECT
            TO anon
            USING (true);
    END IF;
END $$;

GRANT ALL ON TABLE public.ot_pos_tr_flow_master TO postgres, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.ot_pos_tr_flow_master TO authenticated;
GRANT SELECT ON TABLE public.ot_pos_tr_flow_master TO anon;

GRANT ALL ON TABLE public.ot_pos_tr_flow_detail TO postgres, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.ot_pos_tr_flow_detail TO authenticated;
GRANT SELECT ON TABLE public.ot_pos_tr_flow_detail TO anon;
