-- Drop DELETE policy to strictly disallow row deletion
DROP POLICY IF EXISTS "Allow authenticated delete finance_transaction_categories" ON public.finance_transaction_categories;

-- Ensure SELECT, INSERT, UPDATE policies exist
DROP POLICY IF EXISTS "Allow authenticated select finance_transaction_categories" ON public.finance_transaction_categories;
CREATE POLICY "Allow authenticated select finance_transaction_categories" ON public.finance_transaction_categories
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert finance_transaction_categories" ON public.finance_transaction_categories;
CREATE POLICY "Allow authenticated insert finance_transaction_categories" ON public.finance_transaction_categories
  FOR INSERT TO authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update finance_transaction_categories" ON public.finance_transaction_categories;
CREATE POLICY "Allow authenticated update finance_transaction_categories" ON public.finance_transaction_categories
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
