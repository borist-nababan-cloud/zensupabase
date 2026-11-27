-- ============================================================================
-- Migration: STO Shipments & Receipts Multi-Images Support (Max 3 Photos Each)
-- Date: 2026-11-26
-- Author: Zen Family Spa Architect
-- Description:
--   1. Add `image_url_2 TEXT NULL` and `image_url_3 TEXT NULL` to
--      `public.sto_shipments` and `public.sto_receipts` (matching GR 3-photo standard).
--   2. Update `public.view_report_sto_receipt_list` with backward-compatible
--      fallbacks on `shipment_image_url` / `receipt_image_url` and strictly
--      appended JSONB columns `shipment_images` & `receipt_images`.
-- ============================================================================

-- 1. Schema Extensions
ALTER TABLE public.sto_shipments
    ADD COLUMN IF NOT EXISTS image_url_2 TEXT NULL;

ALTER TABLE public.sto_shipments
    ADD COLUMN IF NOT EXISTS image_url_3 TEXT NULL;

ALTER TABLE public.sto_receipts
    ADD COLUMN IF NOT EXISTS image_url_2 TEXT NULL;

ALTER TABLE public.sto_receipts
    ADD COLUMN IF NOT EXISTS image_url_3 TEXT NULL;

-- 2. Update Reporting View (Strictly Append New Columns at End)
CREATE OR REPLACE VIEW public.view_report_sto_receipt_list AS
SELECT
    r.id,
    r.received_at,
    r.document_number,
    o.document_number AS order_number,
    o.from_outlet,
    mo_from.name_outlet AS from_outlet_name,
    o.to_outlet,
    mo_to.name_outlet AS to_outlet_name,
    COALESCE(o.grand_total, 0::numeric) AS grand_total,
    r.sto_id,
    (
        SELECT COALESCE(
            NULLIF(TRIM(ss.image_url), ''),
            NULLIF(TRIM(ss.image_url_2), ''),
            NULLIF(TRIM(ss.image_url_3), '')
        )
        FROM public.sto_shipments ss
        WHERE ss.sto_id = o.id
          AND (
              NULLIF(TRIM(ss.image_url), '') IS NOT NULL
              OR NULLIF(TRIM(ss.image_url_2), '') IS NOT NULL
              OR NULLIF(TRIM(ss.image_url_3), '') IS NOT NULL
          )
        ORDER BY ss.shipped_at DESC
        LIMIT 1
    ) AS shipment_image_url,
    COALESCE(
        NULLIF(TRIM(r.image_url), ''),
        NULLIF(TRIM(r.image_url_2), ''),
        NULLIF(TRIM(r.image_url_3), '')
    ) AS receipt_image_url,
    COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object(
                'gr_id', ss_img.id,
                'gr_doc', ss_img.document_number,
                'received_at', ss_img.shipped_at,
                'slot', u.slot,
                'url', TRIM(u.url)
            )
            ORDER BY ss_img.shipped_at DESC NULLS LAST, ss_img.document_number DESC, u.slot ASC
        )
        FROM public.sto_shipments ss_img
        CROSS JOIN LATERAL (
            VALUES
                (1, ss_img.image_url),
                (2, ss_img.image_url_2),
                (3, ss_img.image_url_3)
        ) AS u(slot, url)
        WHERE ss_img.sto_id = o.id
          AND NULLIF(TRIM(u.url), '') IS NOT NULL
    ), '[]'::jsonb) AS shipment_images,
    COALESCE((
        SELECT jsonb_agg(
            jsonb_build_object(
                'gr_id', r.id,
                'gr_doc', r.document_number,
                'received_at', r.received_at,
                'slot', u.slot,
                'url', TRIM(u.url)
            )
            ORDER BY u.slot ASC
        )
        FROM (
            VALUES
                (1, r.image_url),
                (2, r.image_url_2),
                (3, r.image_url_3)
        ) AS u(slot, url)
        WHERE NULLIF(TRIM(u.url), '') IS NOT NULL
    ), '[]'::jsonb) AS receipt_images
FROM public.sto_receipts r
JOIN public.sto_orders o ON o.id = r.sto_id
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

GRANT SELECT ON public.view_report_sto_receipt_list TO authenticated, anon, service_role;

NOTIFY pgrst, 'reload schema';
