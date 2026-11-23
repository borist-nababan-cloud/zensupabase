-- ==============================================================================
-- MIGRATION: 20261123123000_create_vps_watchdog_schema.sql
-- Description:
--   1. Create table public.vps_watchdog_tokens (token hashes, zero direct client access)
--   2. Create table public.vps_nodes (live VPS snapshot, Role ID 8 ONLY)
--   3. Create table public.vps_metrics_history (7-day rolling metrics, Role ID 8 ONLY)
--   4. Create table public.vps_alerts (deduplicated security & health alerts, Role ID 8 ONLY)
--   5. Create SECURITY DEFINER RPCs:
--      - public.ingest_vps_watchdog(p_token TEXT, p_payload JSONB)
--      - public.generate_vps_watchdog_token(p_node_id TEXT, p_label TEXT)
--      - public.list_vps_watchdog_tokens()
--      - public.revoke_vps_watchdog_token(p_node_id TEXT)
--      - public.acknowledge_vps_alert(p_alert_id UUID)
-- ==============================================================================

-- 1. Table: public.vps_watchdog_tokens (strictly hidden from anon & authenticated)
CREATE TABLE IF NOT EXISTS public.vps_watchdog_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id TEXT UNIQUE NOT NULL CHECK (node_id ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
    label TEXT NOT NULL,
    token_hash TEXT UNIQUE NOT NULL,
    token_prefix TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    last_used_at TIMESTAMPTZ,
    created_by UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.vps_watchdog_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vps_watchdog_tokens FROM anon, authenticated;
GRANT ALL ON public.vps_watchdog_tokens TO service_role;

-- 2. Table: public.vps_nodes
CREATE TABLE IF NOT EXISTS public.vps_nodes (
    node_id TEXT PRIMARY KEY CHECK (node_id ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
    label TEXT NOT NULL DEFAULT 'VPS Server',
    hostname TEXT,
    os_info TEXT,
    kernel_version TEXT,
    cpu_cores INT NOT NULL DEFAULT 1,
    uptime_seconds BIGINT NOT NULL DEFAULT 0,
    cpu_total NUMERIC(5,2) NOT NULL DEFAULT 0,
    cpu_user NUMERIC(5,2) NOT NULL DEFAULT 0,
    cpu_system NUMERIC(5,2) NOT NULL DEFAULT 0,
    cpu_nice NUMERIC(5,2) NOT NULL DEFAULT 0,
    cpu_iowait NUMERIC(5,2) NOT NULL DEFAULT 0,
    load_1m NUMERIC(8,2) NOT NULL DEFAULT 0,
    load_5m NUMERIC(8,2) NOT NULL DEFAULT 0,
    load_15m NUMERIC(8,2) NOT NULL DEFAULT 0,
    mem_total_mb INT NOT NULL DEFAULT 0,
    mem_used_mb INT NOT NULL DEFAULT 0,
    mem_available_mb INT NOT NULL DEFAULT 0,
    mem_percent NUMERIC(5,2) NOT NULL DEFAULT 0,
    swap_total_mb INT NOT NULL DEFAULT 0,
    swap_used_mb INT NOT NULL DEFAULT 0,
    swap_percent NUMERIC(5,2) NOT NULL DEFAULT 0,
    disk_total_gb NUMERIC(10,2) NOT NULL DEFAULT 0,
    disk_used_gb NUMERIC(10,2) NOT NULL DEFAULT 0,
    disk_percent NUMERIC(5,2) NOT NULL DEFAULT 0,
    process_total INT NOT NULL DEFAULT 0,
    process_running INT NOT NULL DEFAULT 0,
    zombie_count INT NOT NULL DEFAULT 0,
    suspicious_count INT NOT NULL DEFAULT 0,
    container_total INT NOT NULL DEFAULT 0,
    container_running INT NOT NULL DEFAULT 0,
    container_unhealthy INT NOT NULL DEFAULT 0,
    containers JSONB NOT NULL DEFAULT '[]'::jsonb,
    top_processes JSONB NOT NULL DEFAULT '[]'::jsonb,
    agent_version TEXT,
    last_heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.vps_nodes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vps_nodes FROM anon;
GRANT SELECT, UPDATE, DELETE ON public.vps_nodes TO authenticated;
GRANT ALL ON public.vps_nodes TO service_role;

DROP POLICY IF EXISTS "vps_nodes_select_superuser" ON public.vps_nodes;
CREATE POLICY "vps_nodes_select_superuser"
    ON public.vps_nodes FOR SELECT
    TO authenticated
    USING (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "vps_nodes_insert_superuser" ON public.vps_nodes;
CREATE POLICY "vps_nodes_insert_superuser"
    ON public.vps_nodes FOR INSERT
    TO authenticated
    WITH CHECK (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "vps_nodes_update_superuser" ON public.vps_nodes;
CREATE POLICY "vps_nodes_update_superuser"
    ON public.vps_nodes FOR UPDATE
    TO authenticated
    USING (public.is_worklogs_superuser())
    WITH CHECK (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "vps_nodes_delete_superuser" ON public.vps_nodes;
CREATE POLICY "vps_nodes_delete_superuser"
    ON public.vps_nodes FOR DELETE
    TO authenticated
    USING (public.is_worklogs_superuser());

-- 3. Table: public.vps_metrics_history
CREATE TABLE IF NOT EXISTS public.vps_metrics_history (
    id BIGSERIAL PRIMARY KEY,
    node_id TEXT NOT NULL REFERENCES public.vps_nodes(node_id) ON DELETE CASCADE,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    cpu_total NUMERIC(5,2) NOT NULL DEFAULT 0,
    cpu_nice NUMERIC(5,2) NOT NULL DEFAULT 0,
    mem_percent NUMERIC(5,2) NOT NULL DEFAULT 0,
    swap_percent NUMERIC(5,2) NOT NULL DEFAULT 0,
    load_1m NUMERIC(8,2) NOT NULL DEFAULT 0,
    load_5m NUMERIC(8,2) NOT NULL DEFAULT 0,
    disk_percent NUMERIC(5,2) NOT NULL DEFAULT 0,
    zombie_count INT NOT NULL DEFAULT 0,
    suspicious_count INT NOT NULL DEFAULT 0,
    container_running INT NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_vps_metrics_history_node_time
    ON public.vps_metrics_history(node_id, recorded_at DESC);

ALTER TABLE public.vps_metrics_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vps_metrics_history FROM anon;
GRANT SELECT, DELETE ON public.vps_metrics_history TO authenticated;
GRANT ALL ON public.vps_metrics_history TO service_role;

DROP POLICY IF EXISTS "vps_metrics_history_select_superuser" ON public.vps_metrics_history;
CREATE POLICY "vps_metrics_history_select_superuser"
    ON public.vps_metrics_history FOR SELECT
    TO authenticated
    USING (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "vps_metrics_history_delete_superuser" ON public.vps_metrics_history;
CREATE POLICY "vps_metrics_history_delete_superuser"
    ON public.vps_metrics_history FOR DELETE
    TO authenticated
    USING (public.is_worklogs_superuser());

-- 4. Table: public.vps_alerts
CREATE TABLE IF NOT EXISTS public.vps_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id TEXT NOT NULL REFERENCES public.vps_nodes(node_id) ON DELETE CASCADE,
    alert_key TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('INFO', 'WARNING', 'CRITICAL')),
    status TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'ACKNOWLEDGED', 'RESOLVED')),
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    occurrences INT NOT NULL DEFAULT 1,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    acknowledged_at TIMESTAMPTZ,
    acknowledged_by UUID,
    resolved_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_vps_alerts_active_key
    ON public.vps_alerts(node_id, alert_key)
    WHERE status IN ('OPEN', 'ACKNOWLEDGED');

CREATE INDEX IF NOT EXISTS idx_vps_alerts_node_status
    ON public.vps_alerts(node_id, status, last_seen_at DESC);

ALTER TABLE public.vps_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vps_alerts FROM anon;
GRANT SELECT, UPDATE, DELETE ON public.vps_alerts TO authenticated;
GRANT ALL ON public.vps_alerts TO service_role;

DROP POLICY IF EXISTS "vps_alerts_select_superuser" ON public.vps_alerts;
CREATE POLICY "vps_alerts_select_superuser"
    ON public.vps_alerts FOR SELECT
    TO authenticated
    USING (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "vps_alerts_update_superuser" ON public.vps_alerts;
CREATE POLICY "vps_alerts_update_superuser"
    ON public.vps_alerts FOR UPDATE
    TO authenticated
    USING (public.is_worklogs_superuser())
    WITH CHECK (public.is_worklogs_superuser());

DROP POLICY IF EXISTS "vps_alerts_delete_superuser" ON public.vps_alerts;
CREATE POLICY "vps_alerts_delete_superuser"
    ON public.vps_alerts FOR DELETE
    TO authenticated
    USING (public.is_worklogs_superuser());

-- 5. RPC: public.ingest_vps_watchdog(p_token TEXT, p_payload JSONB)
CREATE OR REPLACE FUNCTION public.ingest_vps_watchdog(
    p_token TEXT,
    p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_token_trimmed TEXT;
    v_token_hash TEXT;
    v_tok public.vps_watchdog_tokens%ROWTYPE;
    v_containers JSONB;
    v_top_processes JSONB;
    v_alerts JSONB;
    v_alert JSONB;
    v_alert_key TEXT;
    v_severity TEXT;
    v_title TEXT;
    v_message TEXT;
    v_details JSONB;
    v_existing_alert_id UUID;
    v_active_keys TEXT[] := ARRAY[]::TEXT[];
    v_newly_opened TEXT[] := ARRAY[]::TEXT[];
    v_newly_resolved TEXT[] := ARRAY[]::TEXT[];
    v_recent_history_exists BOOLEAN := false;
BEGIN
    v_token_trimmed := trim(COALESCE(p_token, ''));
    IF length(v_token_trimmed) < 16 THEN
        RAISE EXCEPTION 'Invalid or missing watchdog ingest token' USING ERRCODE = '42501';
    END IF;

    v_token_hash := encode(sha256(convert_to(v_token_trimmed, 'UTF8')), 'hex');

    SELECT *
    INTO v_tok
    FROM public.vps_watchdog_tokens
    WHERE token_hash = v_token_hash
      AND is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unauthorized or revoked watchdog ingest token' USING ERRCODE = '42501';
    END IF;

    IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
        RAISE EXCEPTION 'Invalid watchdog payload: JSON object required' USING ERRCODE = '22023';
    END IF;

    UPDATE public.vps_watchdog_tokens
    SET last_used_at = now(),
        updated_at = now()
    WHERE id = v_tok.id;

    v_containers := CASE
        WHEN jsonb_typeof(p_payload->'containers') = 'array' THEN p_payload->'containers'
        ELSE '[]'::jsonb
    END;

    v_top_processes := CASE
        WHEN jsonb_typeof(p_payload->'top_processes') = 'array' THEN p_payload->'top_processes'
        ELSE '[]'::jsonb
    END;

    INSERT INTO public.vps_nodes (
        node_id,
        label,
        hostname,
        os_info,
        kernel_version,
        cpu_cores,
        uptime_seconds,
        cpu_total,
        cpu_user,
        cpu_system,
        cpu_nice,
        cpu_iowait,
        load_1m,
        load_5m,
        load_15m,
        mem_total_mb,
        mem_used_mb,
        mem_available_mb,
        mem_percent,
        swap_total_mb,
        swap_used_mb,
        swap_percent,
        disk_total_gb,
        disk_used_gb,
        disk_percent,
        process_total,
        process_running,
        zombie_count,
        suspicious_count,
        container_total,
        container_running,
        container_unhealthy,
        containers,
        top_processes,
        agent_version,
        last_heartbeat_at,
        updated_at
    )
    VALUES (
        v_tok.node_id,
        v_tok.label,
        NULLIF(left(COALESCE(p_payload->>'hostname', ''), 128), ''),
        NULLIF(left(COALESCE(p_payload->>'os_info', ''), 128), ''),
        NULLIF(left(COALESCE(p_payload->>'kernel_version', ''), 128), ''),
        GREATEST(1, COALESCE((p_payload->>'cpu_cores')::INT, 1)),
        GREATEST(0, COALESCE((p_payload->>'uptime_seconds')::BIGINT, 0)),
        LEAST(100, GREATEST(0, COALESCE((p_payload->>'cpu_total')::NUMERIC(5,2), 0))),
        LEAST(100, GREATEST(0, COALESCE((p_payload->>'cpu_user')::NUMERIC(5,2), 0))),
        LEAST(100, GREATEST(0, COALESCE((p_payload->>'cpu_system')::NUMERIC(5,2), 0))),
        LEAST(100, GREATEST(0, COALESCE((p_payload->>'cpu_nice')::NUMERIC(5,2), 0))),
        LEAST(100, GREATEST(0, COALESCE((p_payload->>'cpu_iowait')::NUMERIC(5,2), 0))),
        GREATEST(0, COALESCE((p_payload->>'load_1m')::NUMERIC(8,2), 0)),
        GREATEST(0, COALESCE((p_payload->>'load_5m')::NUMERIC(8,2), 0)),
        GREATEST(0, COALESCE((p_payload->>'load_15m')::NUMERIC(8,2), 0)),
        GREATEST(0, COALESCE((p_payload->>'mem_total_mb')::INT, 0)),
        GREATEST(0, COALESCE((p_payload->>'mem_used_mb')::INT, 0)),
        GREATEST(0, COALESCE((p_payload->>'mem_available_mb')::INT, 0)),
        LEAST(100, GREATEST(0, COALESCE((p_payload->>'mem_percent')::NUMERIC(5,2), 0))),
        GREATEST(0, COALESCE((p_payload->>'swap_total_mb')::INT, 0)),
        GREATEST(0, COALESCE((p_payload->>'swap_used_mb')::INT, 0)),
        LEAST(100, GREATEST(0, COALESCE((p_payload->>'swap_percent')::NUMERIC(5,2), 0))),
        GREATEST(0, COALESCE((p_payload->>'disk_total_gb')::NUMERIC(10,2), 0)),
        GREATEST(0, COALESCE((p_payload->>'disk_used_gb')::NUMERIC(10,2), 0)),
        LEAST(100, GREATEST(0, COALESCE((p_payload->>'disk_percent')::NUMERIC(5,2), 0))),
        GREATEST(0, COALESCE((p_payload->>'process_total')::INT, 0)),
        GREATEST(0, COALESCE((p_payload->>'process_running')::INT, 0)),
        GREATEST(0, COALESCE((p_payload->>'zombie_count')::INT, 0)),
        GREATEST(0, COALESCE((p_payload->>'suspicious_count')::INT, 0)),
        GREATEST(0, COALESCE((p_payload->>'container_total')::INT, 0)),
        GREATEST(0, COALESCE((p_payload->>'container_running')::INT, 0)),
        GREATEST(0, COALESCE((p_payload->>'container_unhealthy')::INT, 0)),
        v_containers,
        v_top_processes,
        NULLIF(left(COALESCE(p_payload->>'agent_version', ''), 32), ''),
        now(),
        now()
    )
    ON CONFLICT (node_id) DO UPDATE SET
        label = EXCLUDED.label,
        hostname = EXCLUDED.hostname,
        os_info = EXCLUDED.os_info,
        kernel_version = EXCLUDED.kernel_version,
        cpu_cores = EXCLUDED.cpu_cores,
        uptime_seconds = EXCLUDED.uptime_seconds,
        cpu_total = EXCLUDED.cpu_total,
        cpu_user = EXCLUDED.cpu_user,
        cpu_system = EXCLUDED.cpu_system,
        cpu_nice = EXCLUDED.cpu_nice,
        cpu_iowait = EXCLUDED.cpu_iowait,
        load_1m = EXCLUDED.load_1m,
        load_5m = EXCLUDED.load_5m,
        load_15m = EXCLUDED.load_15m,
        mem_total_mb = EXCLUDED.mem_total_mb,
        mem_used_mb = EXCLUDED.mem_used_mb,
        mem_available_mb = EXCLUDED.mem_available_mb,
        mem_percent = EXCLUDED.mem_percent,
        swap_total_mb = EXCLUDED.swap_total_mb,
        swap_used_mb = EXCLUDED.swap_used_mb,
        swap_percent = EXCLUDED.swap_percent,
        disk_total_gb = EXCLUDED.disk_total_gb,
        disk_used_gb = EXCLUDED.disk_used_gb,
        disk_percent = EXCLUDED.disk_percent,
        process_total = EXCLUDED.process_total,
        process_running = EXCLUDED.process_running,
        zombie_count = EXCLUDED.zombie_count,
        suspicious_count = EXCLUDED.suspicious_count,
        container_total = EXCLUDED.container_total,
        container_running = EXCLUDED.container_running,
        container_unhealthy = EXCLUDED.container_unhealthy,
        containers = EXCLUDED.containers,
        top_processes = EXCLUDED.top_processes,
        agent_version = EXCLUDED.agent_version,
        last_heartbeat_at = now(),
        updated_at = now();

    SELECT EXISTS (
        SELECT 1
        FROM public.vps_metrics_history h
        WHERE h.node_id = v_tok.node_id
          AND h.recorded_at > now() - INTERVAL '55 seconds'
    ) INTO v_recent_history_exists;

    IF NOT v_recent_history_exists THEN
        INSERT INTO public.vps_metrics_history (
            node_id,
            recorded_at,
            cpu_total,
            cpu_nice,
            mem_percent,
            swap_percent,
            load_1m,
            load_5m,
            disk_percent,
            zombie_count,
            suspicious_count,
            container_running
        )
        VALUES (
            v_tok.node_id,
            now(),
            LEAST(100, GREATEST(0, COALESCE((p_payload->>'cpu_total')::NUMERIC(5,2), 0))),
            LEAST(100, GREATEST(0, COALESCE((p_payload->>'cpu_nice')::NUMERIC(5,2), 0))),
            LEAST(100, GREATEST(0, COALESCE((p_payload->>'mem_percent')::NUMERIC(5,2), 0))),
            LEAST(100, GREATEST(0, COALESCE((p_payload->>'swap_percent')::NUMERIC(5,2), 0))),
            GREATEST(0, COALESCE((p_payload->>'load_1m')::NUMERIC(8,2), 0)),
            GREATEST(0, COALESCE((p_payload->>'load_5m')::NUMERIC(8,2), 0)),
            LEAST(100, GREATEST(0, COALESCE((p_payload->>'disk_percent')::NUMERIC(5,2), 0))),
            GREATEST(0, COALESCE((p_payload->>'zombie_count')::INT, 0)),
            GREATEST(0, COALESCE((p_payload->>'suspicious_count')::INT, 0)),
            GREATEST(0, COALESCE((p_payload->>'container_running')::INT, 0))
        );
    END IF;

    -- 7-day rolling retention pruning (occasional / top of the hour)
    IF EXTRACT(MINUTE FROM now())::INT = 0 OR random() < 0.02 THEN
        DELETE FROM public.vps_metrics_history
        WHERE recorded_at < now() - INTERVAL '7 days';
    END IF;

    -- Reconcile active alerts
    v_alerts := CASE
        WHEN jsonb_typeof(p_payload->'alerts') = 'array' THEN p_payload->'alerts'
        ELSE '[]'::jsonb
    END;

    FOR v_alert IN SELECT value FROM jsonb_array_elements(v_alerts) LOOP
        IF jsonb_typeof(v_alert) <> 'object' THEN
            CONTINUE;
        END IF;

        v_alert_key := left(trim(COALESCE(v_alert->>'alert_key', '')), 120);
        IF v_alert_key = '' THEN
            CONTINUE;
        END IF;

        v_severity := upper(trim(COALESCE(v_alert->>'severity', 'WARNING')));
        IF v_severity NOT IN ('INFO', 'WARNING', 'CRITICAL') THEN
            v_severity := 'WARNING';
        END IF;

        v_title := left(trim(COALESCE(v_alert->>'title', v_alert_key)), 200);
        v_message := left(trim(COALESCE(v_alert->>'message', '')), 2000);
        v_details := CASE
            WHEN jsonb_typeof(v_alert->'details') = 'object' THEN v_alert->'details'
            ELSE '{}'::jsonb
        END;

        v_active_keys := array_append(v_active_keys, v_alert_key);

        SELECT a.id
        INTO v_existing_alert_id
        FROM public.vps_alerts a
        WHERE a.node_id = v_tok.node_id
          AND a.alert_key = v_alert_key
          AND a.status IN ('OPEN', 'ACKNOWLEDGED')
        LIMIT 1;

        IF FOUND THEN
            UPDATE public.vps_alerts
            SET severity = v_severity,
                title = v_title,
                message = v_message,
                details = v_details,
                occurrences = occurrences + 1,
                last_seen_at = now()
            WHERE id = v_existing_alert_id;
        ELSE
            INSERT INTO public.vps_alerts (
                node_id,
                alert_key,
                severity,
                status,
                title,
                message,
                details,
                occurrences,
                first_seen_at,
                last_seen_at
            )
            VALUES (
                v_tok.node_id,
                v_alert_key,
                v_severity,
                'OPEN',
                v_title,
                v_message,
                v_details,
                1,
                now(),
                now()
            );
            v_newly_opened := array_append(v_newly_opened, v_alert_key);
        END IF;
    END LOOP;

    WITH resolved_rows AS (
        UPDATE public.vps_alerts
        SET status = 'RESOLVED',
            resolved_at = now()
        WHERE node_id = v_tok.node_id
          AND status IN ('OPEN', 'ACKNOWLEDGED')
          AND (
              COALESCE(array_length(v_active_keys, 1), 0) = 0
              OR NOT (alert_key = ANY(v_active_keys))
          )
        RETURNING alert_key
    )
    SELECT COALESCE(array_agg(alert_key), ARRAY[]::TEXT[])
    INTO v_newly_resolved
    FROM resolved_rows;

    RETURN jsonb_build_object(
        'ok', true,
        'node_id', v_tok.node_id,
        'newly_opened', to_jsonb(v_newly_opened),
        'newly_resolved', to_jsonb(v_newly_resolved),
        'server_time', now()
    );
END;
$$;

REVOKE ALL ON FUNCTION public.ingest_vps_watchdog(TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ingest_vps_watchdog(TEXT, JSONB) TO anon, authenticated, service_role;

-- 6. RPC: public.generate_vps_watchdog_token(p_node_id TEXT, p_label TEXT) - STRICT Role ID 8 ONLY
CREATE OR REPLACE FUNCTION public.generate_vps_watchdog_token(
    p_node_id TEXT,
    p_label TEXT DEFAULT 'VPS Server'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_node_id TEXT;
    v_label TEXT;
    v_raw TEXT;
    v_hash TEXT;
    v_prefix TEXT;
BEGIN
    IF NOT public.is_worklogs_superuser() THEN
        RAISE EXCEPTION 'Forbidden: SUPERUSER Role ID 8 required' USING ERRCODE = '42501';
    END IF;

    v_node_id := lower(trim(COALESCE(p_node_id, '')));
    IF v_node_id !~ '^[a-z0-9][a-z0-9_-]{1,63}$' THEN
        RAISE EXCEPTION 'Invalid node_id: use 2-64 lowercase letters, digits, hyphens, or underscores' USING ERRCODE = '22023';
    END IF;

    v_label := left(NULLIF(trim(COALESCE(p_label, '')), ''), 100);
    IF v_label IS NULL THEN
        v_label := v_node_id;
    END IF;

    v_raw := 'zwd_' || encode(extensions.gen_random_bytes(32), 'hex');
    v_hash := encode(sha256(convert_to(v_raw, 'UTF8')), 'hex');
    v_prefix := left(v_raw, 12);

    INSERT INTO public.vps_watchdog_tokens (
        node_id,
        label,
        token_hash,
        token_prefix,
        is_active,
        created_by,
        created_at,
        updated_at
    )
    VALUES (
        v_node_id,
        v_label,
        v_hash,
        v_prefix,
        true,
        auth.uid(),
        now(),
        now()
    )
    ON CONFLICT (node_id) DO UPDATE SET
        label = EXCLUDED.label,
        token_hash = EXCLUDED.token_hash,
        token_prefix = EXCLUDED.token_prefix,
        is_active = true,
        created_by = COALESCE(auth.uid(), public.vps_watchdog_tokens.created_by),
        updated_at = now();

    UPDATE public.vps_nodes
    SET label = v_label,
        updated_at = now()
    WHERE node_id = v_node_id;

    RETURN jsonb_build_object(
        'node_id', v_node_id,
        'label', v_label,
        'token', v_raw,
        'token_prefix', v_prefix
    );
END;
$$;

REVOKE ALL ON FUNCTION public.generate_vps_watchdog_token(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.generate_vps_watchdog_token(TEXT, TEXT) TO authenticated, service_role;

-- 7. RPC: public.list_vps_watchdog_tokens() - STRICT Role ID 8 ONLY
CREATE OR REPLACE FUNCTION public.list_vps_watchdog_tokens()
RETURNS TABLE (
    id UUID,
    node_id TEXT,
    label TEXT,
    token_prefix TEXT,
    is_active BOOLEAN,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, extensions
AS $$
BEGIN
    IF NOT public.is_worklogs_superuser() THEN
        RAISE EXCEPTION 'Forbidden: SUPERUSER Role ID 8 required' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        t.id,
        t.node_id,
        t.label,
        t.token_prefix,
        t.is_active,
        t.last_used_at,
        t.created_at,
        t.updated_at
    FROM public.vps_watchdog_tokens t
    ORDER BY t.created_at ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_vps_watchdog_tokens() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_vps_watchdog_tokens() TO authenticated, service_role;

-- 8. RPC: public.revoke_vps_watchdog_token(p_node_id TEXT) - STRICT Role ID 8 ONLY
CREATE OR REPLACE FUNCTION public.revoke_vps_watchdog_token(p_node_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_updated INT := 0;
BEGIN
    IF NOT public.is_worklogs_superuser() THEN
        RAISE EXCEPTION 'Forbidden: SUPERUSER Role ID 8 required' USING ERRCODE = '42501';
    END IF;

    UPDATE public.vps_watchdog_tokens
    SET is_active = false,
        updated_at = now()
    WHERE node_id = lower(trim(COALESCE(p_node_id, '')));

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN v_updated > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_vps_watchdog_token(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_vps_watchdog_token(TEXT) TO authenticated, service_role;

-- 9. RPC: public.acknowledge_vps_alert(p_alert_id UUID) - STRICT Role ID 8 ONLY
CREATE OR REPLACE FUNCTION public.acknowledge_vps_alert(p_alert_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_updated INT := 0;
BEGIN
    IF NOT public.is_worklogs_superuser() THEN
        RAISE EXCEPTION 'Forbidden: SUPERUSER Role ID 8 required' USING ERRCODE = '42501';
    END IF;

    UPDATE public.vps_alerts
    SET status = 'ACKNOWLEDGED',
        acknowledged_at = now(),
        acknowledged_by = auth.uid()
    WHERE id = p_alert_id
      AND status = 'OPEN';

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN v_updated > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.acknowledge_vps_alert(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.acknowledge_vps_alert(UUID) TO authenticated, service_role;
