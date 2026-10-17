-- Supabase Migration: Complex POS Transaction Structure and Sync Prep
-- Description: Modifies ot_pos tables and adds GC and Point Member tables per architecture spec.

SET ROLE postgres;

-------------------------------------------------------------------------------
-- 1. ot_pos_trans_payment (Parent of Payments)
-------------------------------------------------------------------------------
-- Rename trans_id to id_payment
ALTER TABLE public.ot_pos_trans_payment 
  RENAME COLUMN trans_id TO id_payment;

-- Add UNIQUE constraint so other tables can reference it as a Foreign Key
ALTER TABLE public.ot_pos_trans_payment 
  ADD CONSTRAINT uq_payment_id UNIQUE (id_payment);

-- Rename amount to total
ALTER TABLE public.ot_pos_trans_payment 
  RENAME COLUMN amount TO total;

-- Add new columns
ALTER TABLE public.ot_pos_trans_payment
  ADD COLUMN user_uid TEXT,
  ADD COLUMN subtotal DECIMAL(15,2),
  ADD COLUMN disc_percent DECIMAL(5,2),
  ADD COLUMN disc_amount DECIMAL(15,2),
  ADD COLUMN rcpt TEXT;

-------------------------------------------------------------------------------
-- 2. ot_pos_trans_master (Parent of Details)
-------------------------------------------------------------------------------
-- Add UNIQUE constraint so detail table can reference it
ALTER TABLE public.ot_pos_trans_master 
  ADD CONSTRAINT uq_master_trans_id UNIQUE (trans_id);

-- Rename columns
ALTER TABLE public.ot_pos_trans_master RENAME COLUMN waktu TO start_time;
ALTER TABLE public.ot_pos_trans_master RENAME COLUMN status TO status_trans;
ALTER TABLE public.ot_pos_trans_master RENAME COLUMN total_amount TO subtotal;

-- Add new columns
ALTER TABLE public.ot_pos_trans_master
  ADD COLUMN end_time TIME,
  ADD COLUMN nama_customer TEXT,
  ADD COLUMN room_id TEXT,
  ADD COLUMN byrequest TEXT,
  ADD COLUMN typejasa TEXT,
  ADD COLUMN rcpt TEXT,
  ADD COLUMN id_payment TEXT REFERENCES public.ot_pos_trans_payment (id_payment) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD COLUMN user_uid TEXT;

-------------------------------------------------------------------------------
-- 3. ot_pos_trans_detail (Child of Master)
-------------------------------------------------------------------------------
ALTER TABLE public.ot_pos_trans_detail
  ADD COLUMN kode_karyawan TEXT REFERENCES public.ot_hrd_karyawan_info(kodekaryawan) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD COLUMN tanggal DATE,
  ADD COLUMN trans_type_id TEXT,
  ADD COLUMN produk_jasa_id TEXT,
  ADD COLUMN produk_jasa_nama TEXT,
  ADD COLUMN disc_amount DECIMAL(15,2),
  ADD COLUMN disc_percent DECIMAL(5,2),
  ADD COLUMN therapist_id TEXT,
  ADD COLUMN room_id TEXT,
  ADD COLUMN aroma_oil TEXT,
  ADD COLUMN lama INTEGER,
  ADD COLUMN id_payment TEXT REFERENCES public.ot_pos_trans_payment (id_payment) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD COLUMN user_uid TEXT;

-- Enforce Foreign Key relation to Master
ALTER TABLE public.ot_pos_trans_detail
  ADD CONSTRAINT fk_detail_to_master FOREIGN KEY (trans_id) REFERENCES public.ot_pos_trans_master (trans_id) ON DELETE CASCADE ON UPDATE CASCADE;

-------------------------------------------------------------------------------
-- 4. ot_pos_trans_payment_details (Child of Payment)
-------------------------------------------------------------------------------
-- Rename payment_id to id_payment
ALTER TABLE public.ot_pos_trans_payment_details 
  RENAME COLUMN payment_id TO id_payment;

-- Add FK relation to ot_pos_trans_payment
ALTER TABLE public.ot_pos_trans_payment_details
  ADD CONSTRAINT fk_payment_details_to_payment FOREIGN KEY (id_payment) REFERENCES public.ot_pos_trans_payment (id_payment) ON DELETE CASCADE ON UPDATE CASCADE;

-- Drop obsolete columns
ALTER TABLE public.ot_pos_trans_payment_details
  DROP COLUMN bank_name,
  DROP COLUMN card_number,
  DROP COLUMN approval_code;

-- Add new columns
ALTER TABLE public.ot_pos_trans_payment_details
  ADD COLUMN namapromo TEXT,
  ADD COLUMN refpromo TEXT,
  ADD COLUMN vpromo DECIMAL(15,2),
  ADD COLUMN refdisc TEXT,
  ADD COLUMN vdisc DECIMAL(15,2),
  ADD COLUMN total DECIMAL(15,2),
  ADD COLUMN vredeem DECIMAL(15,2),
  ADD COLUMN refgift TEXT,
  ADD COLUMN vgift DECIMAL(15,2),
  ADD COLUMN vcash DECIMAL(15,2),
  ADD COLUMN payment1 TEXT,
  ADD COLUMN bank1 TEXT,
  ADD COLUMN refpayment1 TEXT,
  ADD COLUMN vpayment1 DECIMAL(15,2),
  ADD COLUMN payment2 TEXT,
  ADD COLUMN bank2 TEXT,
  ADD COLUMN refpayment2 TEXT,
  ADD COLUMN vpayment2 DECIMAL(15,2),
  ADD COLUMN rcpt TEXT;

-------------------------------------------------------------------------------
-- 5. New Table: pos_trans_point_member
-------------------------------------------------------------------------------
CREATE TABLE public.pos_trans_point_member (
    uid UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    id_payment TEXT REFERENCES public.ot_pos_trans_payment (id_payment) ON DELETE CASCADE ON UPDATE CASCADE,
    user_uid TEXT,
    point_awal FLOAT,
    tambah_point FLOAT,
    kurang_point FLOAT,
    sisa_point FLOAT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-------------------------------------------------------------------------------
-- 6. New Table: ot_pos_gc_transaction
-------------------------------------------------------------------------------
CREATE TABLE public.ot_pos_gc_transaction (
    uid UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_uid TEXT,
    gc_number TEXT,
    gc_barcode TEXT,
    pack_number TEXT,
    nama_gc TEXT,
    value FLOAT,
    buy_at TIMESTAMPTZ,
    used_at TIMESTAMPTZ,
    has_used BOOLEAN DEFAULT false,
    id_payment_buy TEXT REFERENCES public.ot_pos_trans_payment (id_payment) ON DELETE SET NULL ON UPDATE CASCADE,
    id_payment_used TEXT REFERENCES public.ot_pos_trans_payment (id_payment) ON DELETE SET NULL ON UPDATE CASCADE,
    kode_outlet_buy TEXT REFERENCES public.master_outlet(kode_outlet) ON DELETE SET NULL ON UPDATE CASCADE,
    kode_outlet_used TEXT REFERENCES public.master_outlet(kode_outlet) ON DELETE SET NULL ON UPDATE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);
