-- ==============================================================================
-- Migration: Add unique check function and trigger for web_members.phone_wa
-- Description: Ensures phone_wa cannot be shared or duplicated across members,
--              normalizing Indonesian phone formats (e.g., 08... vs 628... vs +628...).
-- ==============================================================================

-- 1. RPC function to check if phone_wa is available for a member
CREATE OR REPLACE FUNCTION public.check_member_phone_wa_available(
    p_member_id UUID,
    p_phone_wa TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_cleaned TEXT;
    v_exists BOOLEAN;
BEGIN
    IF p_phone_wa IS NULL OR TRIM(p_phone_wa) = '' THEN
        RETURN TRUE;
    END IF;

    -- Strip non-digit characters
    v_cleaned := REGEXP_REPLACE(p_phone_wa, '[^0-9]', '', 'g');
    
    -- Normalize 628... to 08...
    IF v_cleaned LIKE '62%' THEN
        v_cleaned := '0' || SUBSTRING(v_cleaned FROM 3);
    END IF;

    -- Look for any other member with the same normalized phone
    SELECT EXISTS (
        SELECT 1
        FROM public.web_members
        WHERE id <> p_member_id
          AND phone_wa IS NOT NULL
          AND TRIM(phone_wa) <> ''
          AND (
              REGEXP_REPLACE(phone_wa, '[^0-9]', '', 'g') = v_cleaned
              OR (
                  REGEXP_REPLACE(phone_wa, '[^0-9]', '', 'g') LIKE '62%'
                  AND '0' || SUBSTRING(REGEXP_REPLACE(phone_wa, '[^0-9]', '', 'g') FROM 3) = v_cleaned
              )
          )
    ) INTO v_exists;

    RETURN NOT v_exists;
END;
$$;

-- Grant execution to public and authenticated roles
GRANT EXECUTE ON FUNCTION public.check_member_phone_wa_available(UUID, TEXT) TO public, authenticated, anon;


-- 2. Trigger function to enforce uniqueness and normalize phone_wa on insert / update
CREATE OR REPLACE FUNCTION public.trg_fn_prevent_duplicate_member_phone_wa()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_cleaned TEXT;
    v_duplicate_exists BOOLEAN;
BEGIN
    IF NEW.phone_wa IS NOT NULL AND TRIM(NEW.phone_wa) <> '' THEN
        -- Strip non-digit characters
        v_cleaned := REGEXP_REPLACE(NEW.phone_wa, '[^0-9]', '', 'g');
        
        -- Normalize 628... to 08...
        IF v_cleaned LIKE '62%' THEN
            v_cleaned := '0' || SUBSTRING(v_cleaned FROM 3);
        END IF;

        -- Validate minimum length for mobile phone
        IF LENGTH(v_cleaned) < 9 THEN
            RAISE EXCEPTION 'Nomor WhatsApp tidak valid (minimal 9 digit).';
        END IF;

        -- Check if another member already uses this normalized number
        SELECT EXISTS (
            SELECT 1
            FROM public.web_members
            WHERE id <> NEW.id
              AND phone_wa IS NOT NULL
              AND TRIM(phone_wa) <> ''
              AND (
                  REGEXP_REPLACE(phone_wa, '[^0-9]', '', 'g') = v_cleaned
                  OR (
                      REGEXP_REPLACE(phone_wa, '[^0-9]', '', 'g') LIKE '62%'
                      AND '0' || SUBSTRING(REGEXP_REPLACE(phone_wa, '[^0-9]', '', 'g') FROM 3) = v_cleaned
                  )
              )
        ) INTO v_duplicate_exists;

        IF v_duplicate_exists THEN
            RAISE EXCEPTION 'Nomor WhatsApp % sudah terdaftar pada akun member lain.', NEW.phone_wa;
        END IF;

        -- Store standardized format (08...)
        NEW.phone_wa := v_cleaned;
    END IF;

    RETURN NEW;
END;
$$;

-- 3. Attach trigger to web_members
DROP TRIGGER IF EXISTS trg_prevent_duplicate_member_phone_wa ON public.web_members;
CREATE TRIGGER trg_prevent_duplicate_member_phone_wa
BEFORE INSERT OR UPDATE OF phone_wa ON public.web_members
FOR EACH ROW
EXECUTE FUNCTION public.trg_fn_prevent_duplicate_member_phone_wa();
