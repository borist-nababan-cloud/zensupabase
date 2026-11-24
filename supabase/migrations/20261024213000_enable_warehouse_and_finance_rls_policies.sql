-- Ensure ro_number exists on purchase_orders
ALTER TABLE public.purchase_orders ADD COLUMN IF NOT EXISTS ro_number text;

-- Financial Accounts policies
DROP POLICY IF EXISTS "Allow authenticated select master_financial_accounts" ON public.master_financial_accounts;
CREATE POLICY "Allow authenticated select master_financial_accounts" ON public.master_financial_accounts
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "Allow authenticated insert master_financial_accounts" ON public.master_financial_accounts;
CREATE POLICY "Allow authenticated insert master_financial_accounts" ON public.master_financial_accounts
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated update master_financial_accounts" ON public.master_financial_accounts;
CREATE POLICY "Allow authenticated update master_financial_accounts" ON public.master_financial_accounts
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated delete master_financial_accounts" ON public.master_financial_accounts;
CREATE POLICY "Allow authenticated delete master_financial_accounts" ON public.master_financial_accounts
  FOR DELETE TO authenticated USING (true);

-- Purchase Orders policies
DROP POLICY IF EXISTS "Allow authenticated select purchase_orders" ON public.purchase_orders;
CREATE POLICY "Allow authenticated select purchase_orders" ON public.purchase_orders
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "Allow authenticated insert purchase_orders" ON public.purchase_orders;
CREATE POLICY "Allow authenticated insert purchase_orders" ON public.purchase_orders
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated update purchase_orders" ON public.purchase_orders;
CREATE POLICY "Allow authenticated update purchase_orders" ON public.purchase_orders
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated delete purchase_orders" ON public.purchase_orders;
CREATE POLICY "Allow authenticated delete purchase_orders" ON public.purchase_orders
  FOR DELETE TO authenticated USING (true);

-- Purchase Order Items policies
DROP POLICY IF EXISTS "Allow authenticated select purchase_order_items" ON public.purchase_order_items;
CREATE POLICY "Allow authenticated select purchase_order_items" ON public.purchase_order_items
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "Allow authenticated insert purchase_order_items" ON public.purchase_order_items;
CREATE POLICY "Allow authenticated insert purchase_order_items" ON public.purchase_order_items
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated update purchase_order_items" ON public.purchase_order_items;
CREATE POLICY "Allow authenticated update purchase_order_items" ON public.purchase_order_items
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated delete purchase_order_items" ON public.purchase_order_items;
CREATE POLICY "Allow authenticated delete purchase_order_items" ON public.purchase_order_items
  FOR DELETE TO authenticated USING (true);

-- Stock Opname Headers & Items policies
DROP POLICY IF EXISTS "Allow authenticated select stock_opname_headers" ON public.stock_opname_headers;
CREATE POLICY "Allow authenticated select stock_opname_headers" ON public.stock_opname_headers
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "Allow authenticated insert stock_opname_headers" ON public.stock_opname_headers;
CREATE POLICY "Allow authenticated insert stock_opname_headers" ON public.stock_opname_headers
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated update stock_opname_headers" ON public.stock_opname_headers;
CREATE POLICY "Allow authenticated update stock_opname_headers" ON public.stock_opname_headers
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated delete stock_opname_headers" ON public.stock_opname_headers;
CREATE POLICY "Allow authenticated delete stock_opname_headers" ON public.stock_opname_headers
  FOR DELETE TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated select stock_opname_items" ON public.stock_opname_items;
CREATE POLICY "Allow authenticated select stock_opname_items" ON public.stock_opname_items
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "Allow authenticated insert stock_opname_items" ON public.stock_opname_items;
CREATE POLICY "Allow authenticated insert stock_opname_items" ON public.stock_opname_items
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated update stock_opname_items" ON public.stock_opname_items;
CREATE POLICY "Allow authenticated update stock_opname_items" ON public.stock_opname_items
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated delete stock_opname_items" ON public.stock_opname_items;
CREATE POLICY "Allow authenticated delete stock_opname_items" ON public.stock_opname_items
  FOR DELETE TO authenticated USING (true);

-- Inventory Balance policies
DROP POLICY IF EXISTS "Allow authenticated select inventory_balance" ON public.inventory_balance;
CREATE POLICY "Allow authenticated select inventory_balance" ON public.inventory_balance
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "Allow authenticated insert inventory_balance" ON public.inventory_balance;
CREATE POLICY "Allow authenticated insert inventory_balance" ON public.inventory_balance
  FOR INSERT TO authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated update inventory_balance" ON public.inventory_balance;
CREATE POLICY "Allow authenticated update inventory_balance" ON public.inventory_balance
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "Allow authenticated delete inventory_balance" ON public.inventory_balance;
CREATE POLICY "Allow authenticated delete inventory_balance" ON public.inventory_balance
  FOR DELETE TO authenticated USING (true);
