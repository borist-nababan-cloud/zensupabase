-- ============================================================================
-- Migration: 20261029233000_add_image_url_to_sto_shipments_and_goods_receipts.sql
-- Purpose:
--   1. Add optional `image_url` column to `public.sto_shipments` (Goods Issue photo)
--      and `public.goods_receipts` (Supplier Goods Receipt photo).
--   2. Create public storage bucket `transaction-images` (5MB limit, JPEG/PNG/WEBP)
--      with RLS policies for authenticated uploads and public viewing.
--   3. Extend `public.view_report_purchase_orders` and `public.view_report_sto_receipt_list`
--      by appending image URL columns for report inspection.
-- ============================================================================

BEGIN;

-- 1. Add optional image_url columns
ALTER TABLE public.sto_shipments
ADD COLUMN IF NOT EXISTS image_url TEXT NULL;

ALTER TABLE public.goods_receipts
ADD COLUMN IF NOT EXISTS image_url TEXT NULL;

-- 2. Create Supabase Storage bucket for transaction proof images
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'transaction-images',
    'transaction-images',
    true,
    5242880, -- 5 MB limit
    ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 3. Storage RLS Policies for transaction-images bucket
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Public read access for transaction-images'
    ) THEN
        CREATE POLICY "Public read access for transaction-images"
        ON storage.objects FOR SELECT
        USING (bucket_id = 'transaction-images');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can upload transaction-images'
    ) THEN
        CREATE POLICY "Authenticated users can upload transaction-images"
        ON storage.objects FOR INSERT
        TO authenticated
        WITH CHECK (bucket_id = 'transaction-images');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can update transaction-images'
    ) THEN
        CREATE POLICY "Authenticated users can update transaction-images"
        ON storage.objects FOR UPDATE
        TO authenticated
        USING (bucket_id = 'transaction-images')
        WITH CHECK (bucket_id = 'transaction-images');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'Authenticated users can delete transaction-images'
    ) THEN
        CREATE POLICY "Authenticated users can delete transaction-images"
        ON storage.objects FOR DELETE
        TO authenticated
        USING (bucket_id = 'transaction-images');
    END IF;
END
$$;

-- 4. Append receipt_image_url (and po_doc_number alias) to view_report_purchase_orders
CREATE OR REPLACE VIEW public.view_report_purchase_orders AS
SELECT
    po.id AS po_id,
    po.document_number,
    po.created_at AS po_date,
    po.expected_delivery_date,
    po.status,
    po.grand_total,
    po.kode_outlet,
    s.name AS supplier_name,
    s.kode_supplier,
    (
        SELECT purchase_invoices.id
        FROM public.purchase_invoices
        WHERE purchase_invoices.purchase_order_id = po.id
        LIMIT 1
    ) AS linked_invoice_id,
    po.document_number AS po_doc_number,
    (
        SELECT gr.image_url
        FROM public.goods_receipts gr
        WHERE gr.po_id = po.id
          AND gr.image_url IS NOT NULL
        ORDER BY gr.received_at DESC
        LIMIT 1
    ) AS receipt_image_url
FROM public.purchase_orders po
JOIN public.master_supplier s ON po.kode_supplier = s.kode_supplier;

-- 5. Append sto_id and shipment_image_url to view_report_sto_receipt_list
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
        SELECT ss.image_url
        FROM public.sto_shipments ss
        WHERE ss.sto_id = o.id
          AND ss.image_url IS NOT NULL
        ORDER BY ss.shipped_at DESC
        LIMIT 1
    ) AS shipment_image_url
FROM public.sto_receipts r
JOIN public.sto_orders o ON o.id = r.sto_id
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

COMMIT;

