-- Supabase Migration: Decouple GC Outlet FKs and Restore Complete Master Outlets
-- Description: 
-- 1. Decouples hard foreign key constraints on ot_pos_gc_transaction (kode_outlet_buy, kode_outlet_used)
--    to prevent distributed batch sync abortion in hybrid cloud offline-first architecture.
-- 2. Restores complete master_outlet registry (including 116 Mekarwangi, 117 Padalarang, 102 Riau, etc.)
--    that were omitted during historical table truncation.

SET ROLE postgres;

-------------------------------------------------------------------------------
-- 1. Decouple Hard Foreign Keys on ot_pos_gc_transaction
-------------------------------------------------------------------------------
DO $$ 
BEGIN 
  IF EXISTS (
    SELECT 1 FROM information_schema.table_constraints 
    WHERE constraint_name = 'ot_pos_gc_transaction_kode_outlet_buy_fkey' 
      AND table_name = 'ot_pos_gc_transaction'
  ) THEN 
    ALTER TABLE public.ot_pos_gc_transaction DROP CONSTRAINT ot_pos_gc_transaction_kode_outlet_buy_fkey;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.table_constraints 
    WHERE constraint_name = 'ot_pos_gc_transaction_kode_outlet_used_fkey' 
      AND table_name = 'ot_pos_gc_transaction'
  ) THEN 
    ALTER TABLE public.ot_pos_gc_transaction DROP CONSTRAINT ot_pos_gc_transaction_kode_outlet_used_fkey;
  END IF;
END $$;

-- Ensure B-Tree indexes exist for relational queries, JOINs, and reporting performance
CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_outlet_buy ON public.ot_pos_gc_transaction (kode_outlet_buy);
CREATE INDEX IF NOT EXISTS idx_ot_pos_gc_trans_outlet_used ON public.ot_pos_gc_transaction (kode_outlet_used);

-------------------------------------------------------------------------------
-- 2. Restore Master Outlets Registry (Idempotent UPSERT)
-------------------------------------------------------------------------------
INSERT INTO public.master_outlet (kode_outlet, name_outlet, alamat, no_telp, no_wa, location, province, outlet_group_id, email, active, city, can_sto)
VALUES
  ('101', 'ZEN SUKAJADI', 'JL. SUKAJADI NO 168', '021-87654321', NULL, '{}', 'DKI Jakarta', NULL, NULL, true, NULL, true),
  ('102', 'ZEN RIAU', 'Jl. Ahmad Yani Bekasi', '021-11223344', NULL, '{}', 'Jawa Barat', NULL, NULL, true, NULL, false),
  ('103', 'SURYA SUMANTRI', '', '021-55667788', NULL, '{}', 'JAWA BARAT', NULL, NULL, true, NULL, false),
  ('104', 'ZEN BLANK', NULL, NULL, NULL, NULL, NULL, NULL, NULL, false, NULL, false),
  ('105', 'ZEN GUNAWARMAN', NULL, NULL, NULL, '{}', NULL, NULL, NULL, true, NULL, true),
  ('106', 'ZEN PAKUBUWONO', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, true),
  ('107', 'ZEN PALU', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, true),
  ('108', 'ZEN SAMARINDA', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, false),
  ('109', 'ZEN SUNDA', NULL, NULL, NULL, '{}', NULL, NULL, NULL, true, NULL, true),
  ('110', 'ZEN BALI', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, true),
  ('111', 'ZEN HOLDING', 'JL. Surya Sumantri No. 182', '021-12345678', NULL, '{}', 'Jawa Barat', NULL, 'zenholding@zenfamilyspa.id', true, 'Bandung', false),
  ('112', 'ZEN DEPOK', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, true),
  ('113', 'ZEN BLANK 2', NULL, NULL, NULL, NULL, NULL, NULL, NULL, false, NULL, false),
  ('114', 'ZEN BLANK 3', NULL, NULL, NULL, NULL, NULL, NULL, NULL, false, NULL, false),
  ('115', 'ZEN MAKASAR', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, true),
  ('116', 'ZEN MEKARWANGI', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, true),
  ('117', 'ZEN PADALARANG', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, true),
  ('218', 'ZEN HILTON', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, true),
  ('901', 'ZEN PRODUCT', 'JL. Surya Sumantri No. 18', '022', '081', NULL, NULL, NULL, NULL, true, NULL, true),
  ('902', 'ZEN LAUNDRY', NULL, NULL, NULL, NULL, NULL, NULL, NULL, true, NULL, true)
ON CONFLICT (kode_outlet) DO UPDATE SET
  name_outlet = EXCLUDED.name_outlet,
  alamat = COALESCE(public.master_outlet.alamat, EXCLUDED.alamat),
  no_telp = COALESCE(public.master_outlet.no_telp, EXCLUDED.no_telp),
  no_wa = COALESCE(public.master_outlet.no_wa, EXCLUDED.no_wa),
  location = COALESCE(public.master_outlet.location, EXCLUDED.location),
  province = COALESCE(public.master_outlet.province, EXCLUDED.province),
  outlet_group_id = COALESCE(public.master_outlet.outlet_group_id, EXCLUDED.outlet_group_id),
  email = COALESCE(public.master_outlet.email, EXCLUDED.email),
  active = EXCLUDED.active,
  city = COALESCE(public.master_outlet.city, EXCLUDED.city),
  can_sto = EXCLUDED.can_sto;
