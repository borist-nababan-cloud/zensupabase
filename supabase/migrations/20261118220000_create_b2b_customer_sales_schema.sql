-- ==============================================================================
-- MIGRATION: 20261118220000_create_b2b_customer_sales_schema.sql
-- Description:
--   Creates B2B Customer Master & Sales Transaction Flow tables, triggers,
--   RPCs, indexes, and RLS policies:
--   1. public.master_customer
--   2. public.cst_sales_orders
--   3. public.cst_sales_order_items
--   4. public.cst_shipments
--   5. public.cst_shipment_items (+ trigger_cst_shipment_deduct on inventory_balance)
--   6. public.cst_invoices
--   7. public.cst_payments_in
--   8. public.confirm_cst_payment_receipt() RPC
-- ==============================================================================

-- 1. Master Customer (B2B)
CREATE TABLE IF NOT EXISTS public.master_customer (
    kode_customer UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON UPDATE CASCADE,
    name TEXT NOT NULL,
    address TEXT,
    city TEXT,
    phone TEXT,
    email TEXT,
    pic_name TEXT,
    pic_phone TEXT,
    pic_mail TEXT,
    kode_bank UUID REFERENCES public.master_bank(kode_bank) ON DELETE SET NULL,
    no_rekening TEXT,
    nama_rekening TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID
);

CREATE INDEX IF NOT EXISTS idx_master_customer_outlet ON public.master_customer(kode_outlet);
CREATE INDEX IF NOT EXISTS idx_master_customer_name ON public.master_customer(name);

-- 2. Customer Sales Orders (Pesanan Penjualan)
CREATE TABLE IF NOT EXISTS public.cst_sales_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number TEXT NOT NULL UNIQUE,
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON UPDATE CASCADE,
    kode_customer UUID NOT NULL REFERENCES public.master_customer(kode_customer),
    order_date DATE NOT NULL DEFAULT CURRENT_DATE,
    expected_delivery_date DATE,
    shipping_cost NUMERIC(15,2) NOT NULL DEFAULT 0,
    total_items_amount NUMERIC(15,2) NOT NULL DEFAULT 0,
    total_amount NUMERIC(15,2) NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'ISSUED', 'SHIPPED', 'INVOICED', 'PAID', 'CANCELLED')),
    notes TEXT,
    created_by UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cst_sales_orders_outlet_date ON public.cst_sales_orders(kode_outlet, order_date DESC);
CREATE INDEX IF NOT EXISTS idx_cst_sales_orders_customer ON public.cst_sales_orders(kode_customer);
CREATE INDEX IF NOT EXISTS idx_cst_sales_orders_status ON public.cst_sales_orders(status);

-- 3. Customer Sales Order Items
CREATE TABLE IF NOT EXISTS public.cst_sales_order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    so_id UUID NOT NULL REFERENCES public.cst_sales_orders(id) ON DELETE CASCADE,
    barang_id BIGINT NOT NULL REFERENCES public.master_barang(id),
    qty_ordered NUMERIC(15,2) NOT NULL DEFAULT 0,
    uom TEXT NOT NULL DEFAULT 'PCS',
    price_per_unit NUMERIC(15,2) NOT NULL DEFAULT 0,
    subtotal NUMERIC(15,2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cst_sales_order_items_so ON public.cst_sales_order_items(so_id);
CREATE INDEX IF NOT EXISTS idx_cst_sales_order_items_barang ON public.cst_sales_order_items(barang_id);

-- 4. Customer Shipments (Pengiriman Barang / Surat Jalan)
CREATE TABLE IF NOT EXISTS public.cst_shipments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number TEXT NOT NULL UNIQUE,
    so_id UUID NOT NULL REFERENCES public.cst_sales_orders(id) ON DELETE CASCADE,
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON UPDATE CASCADE,
    kode_customer UUID NOT NULL REFERENCES public.master_customer(kode_customer),
    shipment_date TIMESTAMPTZ NOT NULL DEFAULT now(),
    shipped_by UUID,
    image_url TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cst_shipments_so ON public.cst_shipments(so_id);
CREATE INDEX IF NOT EXISTS idx_cst_shipments_outlet_date ON public.cst_shipments(kode_outlet, shipment_date DESC);
CREATE INDEX IF NOT EXISTS idx_cst_shipments_customer ON public.cst_shipments(kode_customer);

-- 5. Customer Shipment Items + Stock Deduction Trigger
CREATE TABLE IF NOT EXISTS public.cst_shipment_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id UUID NOT NULL REFERENCES public.cst_shipments(id) ON DELETE CASCADE,
    so_item_id UUID NOT NULL REFERENCES public.cst_sales_order_items(id),
    barang_id BIGINT NOT NULL REFERENCES public.master_barang(id),
    qty_shipped NUMERIC(15,2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cst_shipment_items_shipment ON public.cst_shipment_items(shipment_id);
CREATE INDEX IF NOT EXISTS idx_cst_shipment_items_so_item ON public.cst_shipment_items(so_item_id);

CREATE OR REPLACE FUNCTION public.process_cst_shipment_deduct()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_outlet TEXT;
BEGIN
    SELECT kode_outlet INTO v_outlet
    FROM public.cst_shipments
    WHERE id = NEW.shipment_id;

    IF v_outlet IS NOT NULL AND COALESCE(NEW.qty_shipped, 0) > 0 THEN
        PERFORM public.ensure_outlet_inventory(NEW.barang_id, v_outlet);

        UPDATE public.inventory_balance
        SET qty_on_hand = qty_on_hand - NEW.qty_shipped,
            last_movement_at = NOW()
        WHERE barang_id = NEW.barang_id
          AND kode_outlet = v_outlet;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_cst_shipment_deduct ON public.cst_shipment_items;
CREATE TRIGGER trigger_cst_shipment_deduct
    AFTER INSERT ON public.cst_shipment_items
    FOR EACH ROW
    EXECUTE FUNCTION public.process_cst_shipment_deduct();

-- 6. Customer Invoices (Faktur Penjualan)
CREATE TABLE IF NOT EXISTS public.cst_invoices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number TEXT NOT NULL UNIQUE,
    so_id UUID NOT NULL REFERENCES public.cst_sales_orders(id),
    shipment_id UUID REFERENCES public.cst_shipments(id),
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON UPDATE CASCADE,
    kode_customer UUID NOT NULL REFERENCES public.master_customer(kode_customer),
    invoice_date DATE NOT NULL DEFAULT CURRENT_DATE,
    due_date DATE,
    subtotal_items NUMERIC(15,2) NOT NULL DEFAULT 0,
    discount_amount NUMERIC(15,2) NOT NULL DEFAULT 0,
    use_tax BOOLEAN NOT NULL DEFAULT false,
    tax_percent NUMERIC(5,2) NOT NULL DEFAULT 11.00,
    tax_amount NUMERIC(15,2) NOT NULL DEFAULT 0,
    shipping_cost NUMERIC(15,2) NOT NULL DEFAULT 0,
    grand_total NUMERIC(15,2) NOT NULL DEFAULT 0,
    payment_status TEXT NOT NULL DEFAULT 'UNPAID' CHECK (payment_status IN ('UNPAID', 'PAID')),
    paid_at TIMESTAMPTZ,
    paid_account_id UUID REFERENCES public.master_financial_accounts(id),
    notes TEXT,
    created_by UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cst_invoices_so ON public.cst_invoices(so_id);
CREATE INDEX IF NOT EXISTS idx_cst_invoices_outlet_status ON public.cst_invoices(kode_outlet, payment_status);
CREATE INDEX IF NOT EXISTS idx_cst_invoices_customer ON public.cst_invoices(kode_customer);

-- 7. Customer Payments In (Pelunasan Customer / AR)
CREATE TABLE IF NOT EXISTS public.cst_payments_in (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_number TEXT NOT NULL UNIQUE,
    cst_invoice_id UUID NOT NULL REFERENCES public.cst_invoices(id),
    so_id UUID NOT NULL REFERENCES public.cst_sales_orders(id),
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON UPDATE CASCADE,
    kode_customer UUID NOT NULL REFERENCES public.master_customer(kode_customer),
    financial_account_id UUID NOT NULL REFERENCES public.master_financial_accounts(id),
    amount NUMERIC(15,2) NOT NULL DEFAULT 0,
    received_date DATE NOT NULL DEFAULT CURRENT_DATE,
    notes TEXT,
    created_by UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cst_payments_in_invoice ON public.cst_payments_in(cst_invoice_id);
CREATE INDEX IF NOT EXISTS idx_cst_payments_in_outlet ON public.cst_payments_in(kode_outlet);

-- 8. RPC: confirm_cst_payment_receipt (Atomic Customer Payment Settlement)
CREATE OR REPLACE FUNCTION public.confirm_cst_payment_receipt(
    p_invoice_id UUID,
    p_account_id UUID,
    p_received_date DATE DEFAULT CURRENT_DATE,
    p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inv RECORD;
    v_cust_name TEXT;
    v_rcv_doc TEXT;
    v_trx_doc TEXT;
    v_new_balance NUMERIC(15,2);
BEGIN
    SELECT * INTO v_inv
    FROM public.cst_invoices
    WHERE id = p_invoice_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Faktur Penjualan tidak ditemukan';
    END IF;

    IF v_inv.payment_status = 'PAID' THEN
        RAISE EXCEPTION 'Faktur Penjualan ini sudah berstatus LUNAS (PAID)';
    END IF;

    SELECT name INTO v_cust_name
    FROM public.master_customer
    WHERE kode_customer = v_inv.kode_customer;

    -- 1. Update cst_invoices
    UPDATE public.cst_invoices
    SET payment_status = 'PAID',
        paid_at = now(),
        paid_account_id = p_account_id,
        update_at = now(),
        update_by = auth.uid()
    WHERE id = p_invoice_id;

    -- 2. Update cst_sales_orders status to PAID
    UPDATE public.cst_sales_orders
    SET status = 'PAID',
        update_at = now(),
        update_by = auth.uid()
    WHERE id = v_inv.so_id;

    -- 3. Insert into cst_payments_in
    v_rcv_doc := 'RCV-CST.' || v_inv.kode_outlet || '.' || to_char(now(), 'YYMM') || '.' || lpad(floor(random() * 10000)::text, 4, '0');
    INSERT INTO public.cst_payments_in (
        document_number,
        cst_invoice_id,
        so_id,
        kode_outlet,
        kode_customer,
        financial_account_id,
        amount,
        received_date,
        notes,
        created_by
    ) VALUES (
        v_rcv_doc,
        v_inv.id,
        v_inv.so_id,
        v_inv.kode_outlet,
        v_inv.kode_customer,
        p_account_id,
        v_inv.grand_total,
        p_received_date,
        p_notes,
        auth.uid()
    );

    -- 4. Insert into finance_general_transactions (Trigger automatically updates account balance and ledger)
    v_trx_doc := 'TRX-IN.' || v_inv.kode_outlet || '.' || to_char(now(), 'YYMM') || '.' || lpad(floor(random() * 10000)::text, 4, '0');
    INSERT INTO public.finance_general_transactions (
        document_number,
        kode_outlet,
        financial_account_id,
        transaction_type,
        amount,
        transaction_date,
        description,
        created_by,
        created_at
    ) VALUES (
        v_trx_doc,
        v_inv.kode_outlet,
        p_account_id,
        'IN',
        v_inv.grand_total,
        p_received_date,
        'Pelunasan Customer (' || COALESCE(v_cust_name, '-') || ') - ' || v_inv.document_number,
        auth.uid(),
        now()
    );

    SELECT balance INTO v_new_balance
    FROM public.master_financial_accounts
    WHERE id = p_account_id;

    RETURN jsonb_build_object(
        'success', true,
        'payment_document', v_rcv_doc,
        'new_balance', v_new_balance
    );
END;
$$;

-- 9. Grants & Row Level Security (RLS)
ALTER TABLE public.master_customer ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cst_sales_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cst_sales_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cst_shipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cst_shipment_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cst_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cst_payments_in ENABLE ROW LEVEL SECURITY;

GRANT ALL ON TABLE public.master_customer TO authenticated, service_role;
GRANT ALL ON TABLE public.cst_sales_orders TO authenticated, service_role;
GRANT ALL ON TABLE public.cst_sales_order_items TO authenticated, service_role;
GRANT ALL ON TABLE public.cst_shipments TO authenticated, service_role;
GRANT ALL ON TABLE public.cst_shipment_items TO authenticated, service_role;
GRANT ALL ON TABLE public.cst_invoices TO authenticated, service_role;
GRANT ALL ON TABLE public.cst_payments_in TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.confirm_cst_payment_receipt(UUID, UUID, DATE, TEXT) TO authenticated, service_role;

DO $$
DECLARE
    tbl TEXT;
BEGIN
    FOREACH tbl IN ARRAY ARRAY[
        'master_customer',
        'cst_sales_orders',
        'cst_sales_order_items',
        'cst_shipments',
        'cst_shipment_items',
        'cst_invoices',
        'cst_payments_in'
    ]
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS "Allow authenticated read %1$s" ON public.%1$I;', tbl);
        EXECUTE format('CREATE POLICY "Allow authenticated read %1$s" ON public.%1$I FOR SELECT TO authenticated, service_role USING (true);', tbl);

        EXECUTE format('DROP POLICY IF EXISTS "Allow authenticated insert %1$s" ON public.%1$I;', tbl);
        EXECUTE format('CREATE POLICY "Allow authenticated insert %1$s" ON public.%1$I FOR INSERT TO authenticated, service_role WITH CHECK (true);', tbl);

        EXECUTE format('DROP POLICY IF EXISTS "Allow authenticated update %1$s" ON public.%1$I;', tbl);
        EXECUTE format('CREATE POLICY "Allow authenticated update %1$s" ON public.%1$I FOR UPDATE TO authenticated, service_role USING (true) WITH CHECK (true);', tbl);

        EXECUTE format('DROP POLICY IF EXISTS "Allow authenticated delete %1$s" ON public.%1$I;', tbl);
        EXECUTE format('CREATE POLICY "Allow authenticated delete %1$s" ON public.%1$I FOR DELETE TO authenticated, service_role USING (true);', tbl);
    END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
