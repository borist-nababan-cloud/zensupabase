npm init -y
npm install --save-dev supabase
npx supabase start
npx supabase migration new init_schema
npx supabase db reset
npx supabase link okchlapizmhoueeeldrh

We need to tell the Supabase CLI: "Look at what I changed in the GUI, and write the SQL code for me."
npx supabase db diff -f added_testing_table

Push to Staging (Cloud)
npx supabase link --project-ref <your-staging-ref>
npx supabase db push