-- ============================================================================
-- Migration: Add Multi-Images JSONB Columns to view_report_sto_summary
-- Date: 2026-11-26
-- Author: Zen Family Spa Architect
-- Description:
--   Strictly append `shipment_images` and `receipt_images` (JSONB arrays of
--   slots 1..3 from `sto_shipments` and `sto_receipts`) to
--   `public.view_report_sto_summary` so Ringkasan Laporan STO can preview
--   uploaded photos from both Pengirim (Sender) and Penerima (Receiver).
-- ============================================================================

CREATE OR REPLACE VIEW public.view_report_sto_summary AS
SELECT
    o.id,
    o.created_at::date AS order_date,
    o.document_number,
    o.from_outlet,
    mo_from.name_outlet AS from_outlet_name,
    o.to_outlet,
    mo_to.name_outlet AS to_outlet_name,
    o.sender_status,
    o.recipient_status,
    COALESCE((
        SELECT string_agg(((mb.name || ' ('::text) || round(si.qty_requested)::text) || ')'::text, ', '::text) AS string_agg
        FROM public.sto_items si
        JOIN public.master_barang mb ON mb.id = si.barang_id
        WHERE si.sto_id = o.id
    ), '-'::text) AS items_summary,
    COALESCE(o.shipping_cost, 0::numeric) AS shipping_cost,
    COALESCE(o.grand_total, 0::numeric) AS grand_total,
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
                'gr_id', sr_img.id,
                'gr_doc', sr_img.document_number,
                'received_at', sr_img.received_at,
                'slot', u.slot,
                'url', TRIM(u.url)
            )
            ORDER BY sr_img.received_at DESC NULLS LAST, sr_img.document_number DESC, u.slot ASC
        )
        FROM public.sto_receipts sr_img
        CROSS JOIN LATERAL (
            VALUES
                (1, sr_img.image_url),
                (2, sr_img.image_url_2),
                (3, sr_img.image_url_3)
        ) AS u(slot, url)
        WHERE sr_img.sto_id = o.id
          AND NULLIF(TRIM(u.url), '') IS NOT NULL
    ), '[]'::jsonb) AS receipt_images
FROM public.sto_orders o
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

GRANT SELECT ON public.view_report_sto_summary TO authenticated, anon, service_role;

NOTIFY pgrst, 'reload schema';
