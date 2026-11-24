-- ==============================================================================
-- MIGRATION: 20261026123500_create_sto_report_views.sql
-- Description: Create all missing STO report views, add settlement_status to sto_invoices,
--              and implement confirm_sto_payment_receipt RPC.
-- ==============================================================================

-- 1. Ensure columns exist on sto_invoices
ALTER TABLE public.sto_invoices 
    ADD COLUMN IF NOT EXISTS settlement_status text DEFAULT 'UNCLAIMED',
    ADD COLUMN IF NOT EXISTS invoice_date date DEFAULT CURRENT_DATE;

-- Add check constraint for settlement_status if not exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'sto_invoices_settlement_status_check'
    ) THEN
        ALTER TABLE public.sto_invoices 
            ADD CONSTRAINT sto_invoices_settlement_status_check 
            CHECK (settlement_status = ANY (ARRAY['UNCLAIMED'::text, 'RECEIVED'::text]));
    END IF;
END $$;

-- 2. VIEW 1: view_report_sto_summary
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
    COALESCE(
        (
            SELECT string_agg(mb.name || ' (' || ROUND(si.qty_requested)::text || ')', ', ')
            FROM public.sto_items si
            JOIN public.master_barang mb ON mb.id = si.barang_id
            WHERE si.sto_id = o.id
        ),
        '-'
    ) AS items_summary,
    COALESCE(o.shipping_cost, 0) AS shipping_cost,
    COALESCE(o.grand_total, 0) AS grand_total
FROM public.sto_orders o
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

-- 3. VIEW 2: view_report_sto_transit
CREATE OR REPLACE VIEW public.view_report_sto_transit AS
SELECT 
    o.id AS sto_id,
    o.document_number,
    COALESCE(s.shipped_at, o.created_at) AS shipped_at,
    o.from_outlet,
    mo_from.name_outlet AS from_outlet_name,
    o.to_outlet,
    mo_to.name_outlet AS to_outlet_name,
    COALESCE(o.grand_total, 0) AS grand_total,
    COALESCE(o.grand_total, 0) AS value_in_transit,
    GREATEST(0, EXTRACT(DAY FROM (now() - COALESCE(s.shipped_at, o.created_at))))::int AS days_in_transit,
    mo_from.no_telp AS sender_phone
FROM public.sto_orders o
LEFT JOIN LATERAL (
    SELECT shipped_at 
    FROM public.sto_shipments 
    WHERE sto_id = o.id 
    ORDER BY shipped_at DESC 
    LIMIT 1
) s ON true
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet
WHERE o.sender_status = 'SHIPPED' 
  AND o.recipient_status NOT IN ('ACCEPTED', 'COMPLETED', 'REJECTED');

-- 4. VIEW 3: view_report_sto_order_list
CREATE OR REPLACE VIEW public.view_report_sto_order_list AS
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
    COALESCE(o.grand_total, 0) AS grand_total
FROM public.sto_orders o
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

-- 5. VIEW 4: view_report_sto_order_items
CREATE OR REPLACE VIEW public.view_report_sto_order_items AS
SELECT 
    si.id,
    o.created_at::date AS order_date,
    o.document_number,
    o.from_outlet,
    mo_from.name_outlet AS from_outlet_name,
    o.to_outlet,
    mo_to.name_outlet AS to_outlet_name,
    mb.sku,
    mb.name AS item_name,
    si.qty_requested,
    si.price_unit,
    si.subtotal
FROM public.sto_items si
JOIN public.sto_orders o ON o.id = si.sto_id
LEFT JOIN public.master_barang mb ON mb.id = si.barang_id
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

-- 6. VIEW 5: view_report_sto_receipt_list
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
    COALESCE(o.grand_total, 0) AS grand_total
FROM public.sto_receipts r
JOIN public.sto_orders o ON o.id = r.sto_id
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

-- 7. VIEW 6: view_report_sto_receipt_items
CREATE OR REPLACE VIEW public.view_report_sto_receipt_items AS
SELECT 
    ri.id,
    r.received_at,
    r.document_number,
    o.document_number AS order_number,
    o.from_outlet,
    mo_from.name_outlet AS from_outlet_name,
    o.to_outlet,
    mo_to.name_outlet AS to_outlet_name,
    mb.sku,
    mb.name AS item_name,
    ri.qty_received
FROM public.sto_receipt_items ri
JOIN public.sto_receipts r ON r.id = ri.receipt_id
JOIN public.sto_orders o ON o.id = r.sto_id
LEFT JOIN public.master_barang mb ON mb.id = ri.barang_id
LEFT JOIN public.master_outlet mo_from ON mo_from.kode_outlet = o.from_outlet
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

-- 8. VIEW 7: view_report_sto_ar
CREATE OR REPLACE VIEW public.view_report_sto_ar AS
SELECT 
    inv.id AS invoice_id,
    inv.document_number,
    COALESCE(inv.invoice_date, inv.created_at::date) AS invoice_date,
    inv.due_date,
    inv.total_amount,
    COALESCE(inv.status, 'UNPAID') AS payment_status,
    COALESCE(inv.settlement_status, 'UNCLAIMED') AS settlement_status,
    inv.owe_to_outlet_id AS creditor_outlet,
    o.to_outlet AS debtor_outlet_code,
    mo_to.name_outlet AS debtor_outlet_name,
    o.document_number AS sto_doc_number
FROM public.sto_invoices inv
JOIN public.sto_orders o ON o.id = inv.sto_id
LEFT JOIN public.master_outlet mo_to ON mo_to.kode_outlet = o.to_outlet;

-- 9. RPC FUNCTION: confirm_sto_payment_receipt
CREATE OR REPLACE FUNCTION public.confirm_sto_payment_receipt(
    p_invoice_id uuid,
    p_account_id uuid,
    p_received_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_inv RECORD;
    v_new_balance numeric(15,2);
    v_doc_no text;
BEGIN
    SELECT * INTO v_inv FROM public.sto_invoices WHERE id = p_invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice not found';
    END IF;

    -- Update settlement_status on sto_invoices
    UPDATE public.sto_invoices
    SET settlement_status = 'RECEIVED',
        update_at = now()
    WHERE id = p_invoice_id;

    -- Generate doc number for finance_general_transactions
    v_doc_no := 'TRX-IN.' || v_inv.owe_to_outlet_id || '.' || to_char(now(), 'YYMM') || '.' || lpad(floor(random() * 10000)::text, 4, '0');

    -- Insert into finance_general_transactions (trigger will update account balance automatically)
    INSERT INTO public.finance_general_transactions (
        document_number,
        kode_outlet,
        financial_account_id,
        transaction_type,
        amount,
        transaction_date,
        description,
        created_at
    ) VALUES (
        v_doc_no,
        v_inv.owe_to_outlet_id,
        p_account_id,
        'IN',
        v_inv.total_amount,
        p_received_date,
        'Pelunasan STO Piutang ' || v_inv.document_number,
        now()
    );

    -- Get updated balance
    SELECT balance INTO v_new_balance FROM public.master_financial_accounts WHERE id = p_account_id;

    RETURN jsonb_build_object('success', true, 'new_balance', v_new_balance);
END;
$$;

-- 10. GRANTS
GRANT SELECT ON public.view_report_sto_summary TO authenticated, anon;
GRANT SELECT ON public.view_report_sto_transit TO authenticated, anon;
GRANT SELECT ON public.view_report_sto_order_list TO authenticated, anon;
GRANT SELECT ON public.view_report_sto_order_items TO authenticated, anon;
GRANT SELECT ON public.view_report_sto_receipt_list TO authenticated, anon;
GRANT SELECT ON public.view_report_sto_receipt_items TO authenticated, anon;
GRANT SELECT ON public.view_report_sto_ar TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.confirm_sto_payment_receipt(uuid, uuid, date) TO authenticated;
