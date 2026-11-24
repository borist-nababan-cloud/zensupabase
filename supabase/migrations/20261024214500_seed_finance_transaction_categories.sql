-- Seed standard categories for finance_transaction_categories
INSERT INTO public.finance_transaction_categories (name, type, description, is_active)
VALUES
  ('Setoran Modal', 'IN', 'Setoran modal dari pemilik / investor', true),
  ('Pengisian Kas Kecil', 'IN', 'Penerimaan dana kas kecil / petty cash', true),
  ('Pendapatan Lain-lain', 'IN', 'Penerimaan atau pendapatan operasional lain', true),
  ('Pengembalian Dana', 'IN', 'Refund / pengembalian dana masuk', true),
  ('Pemasukan Lainnya', 'IN', 'Pemasukan lain yang tidak terklasifikasi', true),
  ('Beban Operasional', 'OUT', 'Pengeluaran rutin operasional cabang', true),
  ('Pembelian Langsung', 'OUT', 'Pembelian perlengkapan / bahan secara tunai', true),
  ('Refill Kas Kecil', 'OUT', 'Pengeluaran untuk mengisi kas kecil', true),
  ('Penarikan Modal (Prive)', 'OUT', 'Penarikan dana oleh pemilik', true),
  ('Listrik, Air & Internet', 'OUT', 'Beban utilitas bulanan', true),
  ('Pemeliharaan & Perbaikan', 'OUT', 'Biaya service alat, AC, dan renovasi', true),
  ('Perlengkapan & Bahan', 'OUT', 'Biaya perlengkapan kerja & habis pakai', true),
  ('Pengeluaran Lainnya', 'OUT', 'Pengeluaran lain yang tidak terklasifikasi', true)
ON CONFLICT (name, type) DO UPDATE 
SET description = EXCLUDED.description, is_active = true;
