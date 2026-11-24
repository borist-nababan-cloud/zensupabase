-- ==============================================================================
-- Migration: Create RPC get_testimonial_notification_payload
-- Description: Bundles testimonial, member profile, outlet details, and master_email
--              recipients into a single HTTPS-callable JSON payload for n8n.
--              Solves IPv4 direct connection limitations completely.
-- ==============================================================================

CREATE OR REPLACE FUNCTION public.get_testimonial_notification_payload(p_testimonial_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_testi RECORD;
    v_recipients TEXT[];
    v_result JSONB;
BEGIN
    -- 1. Fetch testimonial + member + outlet
    SELECT 
        t.id,
        t.rating,
        t.comment,
        t.photo_url,
        t.kode_outlet,
        t.created_at,
        COALESCE(m.full_name, t.customer_name) AS customer_name,
        COALESCE(m.email, '-') AS customer_email,
        COALESCE(m.phone_wa, '-') AS customer_wa,
        COALESCE(o.name_outlet, 'Zen Holding (Pusat)') AS outlet_name,
        COALESCE(o.city, 'Indonesia') AS outlet_city
    INTO v_testi
    FROM public.web_testimonials t
    LEFT JOIN public.web_members m ON m.auth_user_id = t.auth_user_id
    LEFT JOIN public.master_outlet o ON o.kode_outlet = t.kode_outlet
    WHERE t.id = p_testimonial_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('found', false);
    END IF;

    -- 2. Fetch recipient email list from master_email
    SELECT array_agg(DISTINCT email)
    INTO v_recipients
    FROM public.master_email
    WHERE active = true
      AND (
        (v_testi.rating < 3 AND testi_bad = true)
        OR
        (v_testi.rating >= 3 AND testi_notif = true)
      )
      AND (
        kode_outlet IS NULL 
        OR kode_outlet = v_testi.kode_outlet
      );

    -- 3. Return consolidated JSON object
    v_result := jsonb_build_object(
        'found', true,
        'rating', v_testi.rating,
        'comment', v_testi.comment,
        'photo_url', v_testi.photo_url,
        'kode_outlet', v_testi.kode_outlet,
        'created_at', v_testi.created_at,
        'customer_name', v_testi.customer_name,
        'customer_email', v_testi.customer_email,
        'customer_wa', v_testi.customer_wa,
        'outlet_name', v_testi.outlet_name,
        'outlet_city', v_testi.outlet_city,
        'recipients', COALESCE(v_recipients, ARRAY[]::TEXT[])
    );

    RETURN v_result;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.get_testimonial_notification_payload(UUID) TO anon, authenticated, service_role;

