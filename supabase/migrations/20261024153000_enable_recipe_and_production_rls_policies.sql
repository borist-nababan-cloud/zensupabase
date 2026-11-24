-- Enable RLS and add policies for master_recipes, master_recipe_items, and production run tables

-- Master Recipes policies
DROP POLICY IF EXISTS "Allow authenticated read master_recipes" ON public.master_recipes;
CREATE POLICY "Allow authenticated read master_recipes" ON public.master_recipes
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert master_recipes" ON public.master_recipes;
CREATE POLICY "Allow authenticated insert master_recipes" ON public.master_recipes
  FOR INSERT TO authenticated WITH CHECK (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
        AND (users_profile.kode_outlet = master_recipes.kode_outlet OR users_profile.user_role = ANY (ARRAY[1, 8]) OR master_recipes.kode_outlet = '111')
    )
  );

DROP POLICY IF EXISTS "Allow authenticated update master_recipes" ON public.master_recipes;
CREATE POLICY "Allow authenticated update master_recipes" ON public.master_recipes
  FOR UPDATE TO authenticated USING (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
        AND (users_profile.kode_outlet = master_recipes.kode_outlet OR users_profile.user_role = ANY (ARRAY[1, 8]) OR master_recipes.kode_outlet = '111')
    )
  );

DROP POLICY IF EXISTS "Allow authenticated delete master_recipes" ON public.master_recipes;
CREATE POLICY "Allow authenticated delete master_recipes" ON public.master_recipes
  FOR DELETE TO authenticated USING (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
        AND (users_profile.kode_outlet = master_recipes.kode_outlet OR users_profile.user_role = ANY (ARRAY[1, 8]) OR master_recipes.kode_outlet = '111')
    )
  );

-- Master Recipe Items policies
DROP POLICY IF EXISTS "Allow authenticated read master_recipe_items" ON public.master_recipe_items;
CREATE POLICY "Allow authenticated read master_recipe_items" ON public.master_recipe_items
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert master_recipe_items" ON public.master_recipe_items;
CREATE POLICY "Allow authenticated insert master_recipe_items" ON public.master_recipe_items
  FOR INSERT TO authenticated WITH CHECK (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Allow authenticated update master_recipe_items" ON public.master_recipe_items;
CREATE POLICY "Allow authenticated update master_recipe_items" ON public.master_recipe_items
  FOR UPDATE TO authenticated USING (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Allow authenticated delete master_recipe_items" ON public.master_recipe_items;
CREATE POLICY "Allow authenticated delete master_recipe_items" ON public.master_recipe_items
  FOR DELETE TO authenticated USING (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
    )
  );

-- Production Runs policies
DROP POLICY IF EXISTS "Allow authenticated read production_runs" ON public.production_runs;
CREATE POLICY "Allow authenticated read production_runs" ON public.production_runs
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert production_runs" ON public.production_runs;
CREATE POLICY "Allow authenticated insert production_runs" ON public.production_runs
  FOR INSERT TO authenticated WITH CHECK (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Allow authenticated update production_runs" ON public.production_runs;
CREATE POLICY "Allow authenticated update production_runs" ON public.production_runs
  FOR UPDATE TO authenticated USING (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Allow authenticated delete production_runs" ON public.production_runs;
CREATE POLICY "Allow authenticated delete production_runs" ON public.production_runs
  FOR DELETE TO authenticated USING (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
    )
  );

-- Production Run Ingredients policies
DROP POLICY IF EXISTS "Allow authenticated read production_run_ingredients" ON public.production_run_ingredients;
CREATE POLICY "Allow authenticated read production_run_ingredients" ON public.production_run_ingredients
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert production_run_ingredients" ON public.production_run_ingredients;
CREATE POLICY "Allow authenticated insert production_run_ingredients" ON public.production_run_ingredients
  FOR INSERT TO authenticated WITH CHECK (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
    )
  );

-- Production Run Outputs policies
DROP POLICY IF EXISTS "Allow authenticated read production_run_outputs" ON public.production_run_outputs;
CREATE POLICY "Allow authenticated read production_run_outputs" ON public.production_run_outputs
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Allow authenticated insert production_run_outputs" ON public.production_run_outputs;
CREATE POLICY "Allow authenticated insert production_run_outputs" ON public.production_run_outputs
  FOR INSERT TO authenticated WITH CHECK (
    EXISTS (
      SELECT 1 FROM users_profile
      WHERE users_profile.uid = auth.uid()
    )
  );
