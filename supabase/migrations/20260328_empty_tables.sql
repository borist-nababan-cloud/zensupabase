-- Empty all tables for manual production data import
-- This prepares the database for manual import via Supabase Studio

-- Empty all data tables (truncate but keep structure)
TRUNCATE TABLE locations CASCADE;
TRUNCATE TABLE profiles CASCADE;
TRUNCATE TABLE role_user CASCADE;
TRUNCATE TABLE users_profile CASCADE;
TRUNCATE TABLE master_outlet CASCADE;
TRUNCATE TABLE group_outlet CASCADE;
TRUNCATE TABLE master_type CASCADE;
TRUNCATE TABLE master_barang CASCADE;
TRUNCATE TABLE barang_prices CASCADE;
TRUNCATE TABLE barang_units CASCADE;
TRUNCATE TABLE barang_price_history CASCADE;
TRUNCATE TABLE master_financial_accounts CASCADE;
TRUNCATE TABLE finance_account_ledger CASCADE;
TRUNCATE TABLE finance_ap_ledger CASCADE;
TRUNCATE TABLE finance_transaction_categories CASCADE;
TRUNCATE TABLE purchase_order_items CASCADE;
TRUNCATE TABLE purchase_orders CASCADE;
TRUNCATE TABLE purchase_invoices CASCADE;
TRUNCATE TABLE goods_receipt_items CASCADE;
TRUNCATE TABLE goods_receipts CASCADE;
TRUNCATE TABLE inventory_balance CASCADE;
TRUNCATE TABLE inventory_shrinkage_logs CASCADE;
TRUNCATE TABLE master_shrinkage_categories CASCADE;
TRUNCATE TABLE master_recipe_items CASCADE;
TRUNCATE TABLE master_recipes CASCADE;
TRUNCATE TABLE production_runs CASCADE;
TRUNCATE TABLE production_run_ingredients CASCADE;
TRUNCATE TABLE production_run_outputs CASCADE;
TRUNCATE TABLE master_supplier CASCADE;
TRUNCATE TABLE master_bank CASCADE;
TRUNCATE TABLE locations CASCADE;
TRUNCATE TABLE sto_invoices CASCADE;
TRUNCATE TABLE sto_items CASCADE;
TRUNCATE TABLE sto_orders CASCADE;
TRUNCATE TABLE sto_receipts CASCADE;
TRUNCATE TABLE sto_shipments CASCADE;
TRUNCATE TABLE sto_receipt_items CASCADE;
TRUNCATE TABLE sto_shipment_items CASCADE;
TRUNCATE TABLE stock_opname_headers CASCADE;
TRUNCATE TABLE stock_opname_items CASCADE;
TRUNCATE TABLE trans_detail CASCADE;
TRUNCATE TABLE trans_master CASCADE;
TRUNCATE TABLE trans_payment CASCADE;
TRUNCATE TABLE trans_payment_detail CASCADE;
TRUNCATE TABLE finance_general_transactions CASCADE;
TRUNCATE TABLE finance_payment_allocations CASCADE;
TRUNCATE TABLE finance_payments_out CASCADE;

-- Add migration record
INSERT INTO supabase_migrations.schema_migrations (version, name)
VALUES ('20260328_empty_tables', 'Empty all tables for manual production data import via Supabase Studio');