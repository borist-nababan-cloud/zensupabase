-- Implement RLS policies from previous Supabase installation

-- Locations policies
CREATE POLICY "Allow public read locations" ON "public"."locations" AS PERMISSIVE FOR SELECT TO public USING (true);
CREATE POLICY "Allow authenticated insert locations" ON "public"."locations" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update locations" ON "public"."locations" AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "Allow all users to read locations" ON "public"."locations" AS PERMISSIVE FOR SELECT TO public USING (true);
CREATE POLICY "Allow authenticated users to insert locations" ON "public"."locations" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated users to update locations" ON "public"."locations" AS PERMISSIVE FOR UPDATE TO authenticated USING (true);

-- Profiles policies
CREATE POLICY "Allow public read profiles" ON "public"."profiles" AS PERMISSIVE FOR SELECT TO public USING (true);
CREATE POLICY "Allow service role insert profiles" ON "public"."profiles" AS PERMISSIVE FOR INSERT TO service_role WITH CHECK (true);
CREATE POLICY "Allow users update own profile" ON "public"."profiles" AS PERMISSIVE FOR UPDATE TO authenticated USING ((auth.uid()::text = id)) WITH CHECK ((auth.uid()::text = id));
CREATE POLICY "Allow service role update profiles" ON "public"."profiles" AS PERMISSIVE FOR UPDATE TO service_role USING (true) WITH CHECK (true);

-- Role user policies
CREATE POLICY "Allow public read roles" ON "public"."role_user" AS PERMISSIVE FOR SELECT TO public USING (true);

-- Users profile policies
CREATE POLICY "Allow service insert profile" ON "public"."users_profile" AS PERMISSIVE FOR INSERT TO service_role WITH CHECK (true);
CREATE POLICY "Allow service update profile" ON "public"."users_profile" AS PERMISSIVE FOR UPDATE TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "Allow authenticated read all profiles" ON "public"."users_profile" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "Users can view own profile" ON "public"."users_profile" AS PERMISSIVE FOR SELECT TO authenticated USING ((uid = auth.uid()));

-- Outlet policies
CREATE POLICY "Allow authenticated read outlets" ON "public"."master_outlet" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow service insert outlets" ON "public"."master_outlet" AS PERMISSIVE FOR INSERT TO service_role WITH CHECK (true);
CREATE POLICY "Allow service update outlets" ON "public"."master_outlet" AS PERMISSIVE FOR UPDATE TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "Authenticated can read master_outlet" ON "public"."master_outlet" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Outlet groups policies
CREATE POLICY "Allow authenticated read outlet groups" ON "public"."group_outlet" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "Allow service insert outlet groups" ON "public"."group_outlet" AS PERMISSIVE FOR INSERT TO service_role WITH CHECK (true);

-- Master type policies
CREATE POLICY "Authenticated can read product types" ON "public"."master_type" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated can read master_type" ON "public"."master_type" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "Admin can insert product types" ON "public"."master_type" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = 1));
CREATE POLICY "Admin can update product types" ON "public"."master_type" AS PERMISSIVE FOR UPDATE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = 1)) WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = 1));
CREATE POLICY "Admin can delete product types" ON "public"."master_type" AS PERMISSIVE FOR DELETE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = 1));

-- Master barang (products) policies
CREATE POLICY "Admin and Superuser can read all products" ON "public"."master_barang" AS PERMISSIVE FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = ANY (ARRAY[1, 8])));
CREATE POLICY "Admin can insert products" ON "public"."master_barang" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = 1 AND users_profile.kode_outlet = master_barang.kode_outlet));
CREATE POLICY "Outlet users can insert products" ON "public"."master_barang" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = ANY (ARRAY[5, 6]) AND users_profile.kode_outlet = master_barang.kode_outlet));
CREATE POLICY "Admin can update products" ON "public"."master_barang" AS PERMISSIVE FOR UPDATE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = 1 AND users_profile.kode_outlet = master_barang.kode_outlet)) WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = 1 AND users_profile.kode_outlet = master_barang.kode_outlet));
CREATE POLICY "Outlet users can update products" ON "public"."master_barang" AS PERMISSIVE FOR UPDATE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = ANY (ARRAY[5, 6]) AND users_profile.kode_outlet = master_barang.kode_outlet)) WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = ANY (ARRAY[5, 6]) AND users_profile.kode_outlet = master_barang.kode_outlet));
CREATE POLICY "Admin can delete products" ON "public"."master_barang" AS PERMISSIVE FOR DELETE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = 1 AND users_profile.kode_outlet = master_barang.kode_outlet));
CREATE POLICY "Outlet users can delete products" ON "public"."master_barang" AS PERMISSIVE FOR DELETE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = ANY (ARRAY[5, 6]) AND users_profile.kode_outlet = master_barang.kode_outlet));
CREATE POLICY "Outlet users can read own outlet and holding products" ON "public"."master_barang" AS PERMISSIVE FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.kode_outlet = master_barang.kode_outlet OR master_barang.kode_outlet = '111' OR users_profile.user_role = ANY (ARRAY[1, 8]))));
CREATE POLICY "Enable read access for authenticated users" ON "public"."master_barang" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Barang prices policies
CREATE POLICY "Authenticated can read barang_prices" ON "public"."barang_prices" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated can insert prices" ON "public"."barang_prices" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.kode_outlet = barang_prices.kode_outlet OR users_profile.user_role = ANY (ARRAY[1, 8]))));
CREATE POLICY "Authenticated can update prices" ON "public"."barang_prices" AS PERMISSIVE FOR UPDATE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.kode_outlet = barang_prices.kode_outlet OR users_profile.user_role = ANY (ARRAY[1, 8])))) WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.kode_outlet = barang_prices.kode_outlet OR users_profile.user_role = ANY (ARRAY[1, 8]))));

-- Barang units policies
CREATE POLICY "Authenticated can read barang_units" ON "public"."barang_units" AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated can insert units" ON "public"."barang_units" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.kode_outlet = barang_units.kode_outlet OR users_profile.user_role = ANY (ARRAY[1, 8]))));
CREATE POLICY "Authenticated can update units" ON "public"."barang_units" AS PERMISSIVE FOR UPDATE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.kode_outlet = barang_units.kode_outlet OR users_profile.user_role = ANY (ARRAY[1, 8])))) WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.kode_outlet = barang_units.kode_outlet OR users_profile.user_role = ANY (ARRAY[1, 8]))));

-- Bank policies
CREATE POLICY "Authenticated users can view banks" ON "public"."master_bank" AS PERMISSIVE FOR SELECT TO authenticated USING (true);

-- Supplier policies
CREATE POLICY "Users can view own outlet suppliers" ON "public"."master_supplier" AS PERMISSIVE FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.user_role = ANY (ARRAY[5, 8]) OR users_profile.user_role = ANY (ARRAY[1, 2]) OR users_profile.kode_outlet = '111' OR users_profile.kode_outlet = master_supplier.kode_outlet)));
CREATE POLICY "Role 1, 6 can insert suppliers" ON "public"."master_supplier" AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = ANY (ARRAY[1, 6]) AND users_profile.kode_outlet = master_supplier.kode_outlet));
CREATE POLICY "Role 1, 6 can update own suppliers" ON "public"."master_supplier" AS PERMISSIVE FOR UPDATE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = ANY (ARRAY[1, 6]) AND (users_profile.kode_outlet = master_supplier.kode_outlet OR users_profile.kode_outlet = '111'))) WITH CHECK (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = ANY (ARRAY[1, 6]) AND (users_profile.kode_outlet = master_supplier.kode_outlet OR users_profile.kode_outlet = '111')));
CREATE POLICY "Role 1, 6 can delete own suppliers" ON "public"."master_supplier" AS PERMISSIVE FOR DELETE TO authenticated USING (EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND users_profile.user_role = ANY (ARRAY[1, 6]) AND (users_profile.kode_outlet = master_supplier.kode_outlet OR users_profile.kode_outlet = '111')));

-- Goods receipts policies
CREATE POLICY "Users see receipts for their outlet" ON "public"."goods_receipts" AS PERMISSIVE FOR SELECT TO public USING (kode_outlet = (SELECT users_profile.kode_outlet FROM users_profile WHERE users_profile.uid = auth.uid()) OR EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.kode_outlet = '111' OR users_profile.user_role = ANY (ARRAY[1, 8]))));
CREATE POLICY "Users insert receipts for their outlet" ON "public"."goods_receipts" AS PERMISSIVE FOR INSERT TO public WITH CHECK (kode_outlet = (SELECT users_profile.kode_outlet FROM users_profile WHERE users_profile.uid = auth.uid()) OR EXISTS (SELECT 1 FROM users_profile WHERE users_profile.uid = auth.uid() AND (users_profile.kode_outlet = '111' OR users_profile.user_role = ANY (ARRAY[1, 8]))));

-- Transaction dashboard access policies
CREATE POLICY "Dashboard Access - Payment" ON "public"."trans_payment" AS PERMISSIVE FOR SELECT TO authenticated USING ((SELECT user_role FROM users_profile WHERE uid = auth.uid()) = ANY (ARRAY[5, 8]) OR kode_outlet::text = (SELECT kode_outlet FROM users_profile WHERE uid = auth.uid()));
CREATE POLICY "Dashboard Access - Detail" ON "public"."trans_payment_detail" AS PERMISSIVE FOR SELECT TO authenticated USING ((SELECT user_role FROM users_profile WHERE uid = auth.uid()) = ANY (ARRAY[5, 8]) OR kode_outlet::text = (SELECT kode_outlet FROM users_profile WHERE uid = auth.uid()));
CREATE POLICY "Dashboard Access - Master" ON "public"."trans_master" AS PERMISSIVE FOR SELECT TO authenticated USING ((SELECT user_role FROM users_profile WHERE uid = auth.uid()) = ANY (ARRAY[5, 8]) OR kode_outlet::text = (SELECT kode_outlet FROM users_profile WHERE uid = auth.uid()));
CREATE POLICY "Dashboard Access - Detail Items" ON "public"."trans_detail" AS PERMISSIVE FOR SELECT TO authenticated USING ((SELECT user_role FROM users_profile WHERE uid = auth.uid()) = ANY (ARRAY[5, 8]) OR kode_outlet::text = (SELECT kode_outlet FROM users_profile WHERE uid = auth.uid()));