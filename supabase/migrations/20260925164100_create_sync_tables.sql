-- Supabase Migration: Create Cloud Sync Tables for Multi-Tenant Architecture
-- Description: Maps local MySQL tables to Supabase with UUIDs, audit fields, and FK constraints.

-- 1. ot_hrd_karyawan_info
CREATE TABLE public.ot_hrd_karyawan_info (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_autonum BIGINT,
    kode_outlet TEXT,
    kodekaryawan TEXT UNIQUE NOT NULL, -- UNIQUE required for Foreign Key references
    idkaryawan TEXT,
    namakaryawan TEXT,
    departemen TEXT,
    jadwaltetap TEXT,
    kodejadwal INTEGER,
    kodekontrak TEXT,
    tglmasukkerja DATE,
    tglhabiskontrak DATE,
    namabank TEXT,
    norek TEXT,
    namarek TEXT,
    active TEXT,
    
    -- Audit fields
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 2. ot_hrd_absen_harian
CREATE TABLE public.ot_hrd_absen_harian (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_autonum BIGINT,
    kode_outlet TEXT,
    kodekaryawan TEXT REFERENCES public.ot_hrd_karyawan_info(kodekaryawan),
    id_karyawan TEXT,
    nama TEXT,
    tanggal DATE,
    waktu TIME,
    status TEXT,
    notes TEXT,
    fp_in TIMESTAMPTZ,
    fp_out TIMESTAMPTZ,

    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 3. ot_hrd_karyawan_details
CREATE TABLE public.ot_hrd_karyawan_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_autonum BIGINT,
    kode_outlet TEXT,
    kodekaryawan TEXT REFERENCES public.ot_hrd_karyawan_info(kodekaryawan),
    idkaryawan TEXT,
    namakaryawan TEXT,
    noidentitas TEXT,
    sex TEXT,
    alamatktp TEXT,
    alamattinggal TEXT,
    telpfixline TEXT,
    telpponsel TEXT,
    tempatlahir TEXT,
    tgllahir DATE,
    agamaid TEXT,
    goldarah TEXT,
    alamatemail TEXT,
    active TEXT,

    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 4. ot_hrd_karyawan_payroll_details
CREATE TABLE public.ot_hrd_karyawan_payroll_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_autonum BIGINT,
    kode_outlet TEXT,
    kodekaryawan TEXT REFERENCES public.ot_hrd_karyawan_info(kodekaryawan),
    
    payroll_data JSONB, -- Flexible store for payroll metrics unless explicitly defined
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 5. ot_pos_trans_master
CREATE TABLE public.ot_pos_trans_master (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_autonum BIGINT,
    kode_outlet TEXT,
    kodekaryawan TEXT REFERENCES public.ot_hrd_karyawan_info(kodekaryawan),
    
    trans_id TEXT,
    tanggal DATE,
    waktu TIME,
    total_amount DECIMAL(15,2),
    status TEXT,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 6. ot_pos_trans_detail
CREATE TABLE public.ot_pos_trans_detail (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_autonum BIGINT,
    kode_outlet TEXT,
    
    trans_id TEXT,
    item_id TEXT,
    qty DECIMAL(10,2),
    price DECIMAL(15,2),
    subtotal DECIMAL(15,2),
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 7. ot_pos_trans_payment
CREATE TABLE public.ot_pos_trans_payment (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_autonum BIGINT,
    kode_outlet TEXT,
    
    trans_id TEXT,
    payment_method TEXT,
    amount DECIMAL(15,2),
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 8. ot_pos_trans_payment_details
CREATE TABLE public.ot_pos_trans_payment_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_autonum BIGINT,
    kode_outlet TEXT,
    
    payment_id TEXT,
    bank_name TEXT,
    card_number TEXT,
    approval_code TEXT,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 9. ot_pos_trans_reject
CREATE TABLE public.ot_pos_trans_reject (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    local_autonum BIGINT,
    kode_outlet TEXT,
    
    trans_id TEXT,
    reason TEXT,
    reject_date TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- Adding RLS (Row Level Security) policies placeholder
-- Ensures that if web apps access these tables, security is enabled
ALTER TABLE public.ot_hrd_karyawan_info ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ot_hrd_absen_harian ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ot_hrd_karyawan_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ot_hrd_karyawan_payroll_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ot_pos_trans_master ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ot_pos_trans_detail ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ot_pos_trans_payment ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ot_pos_trans_payment_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ot_pos_trans_reject ENABLE ROW LEVEL SECURITY;

-- Creating indexes for frequently queried relational fields
CREATE INDEX idx_ot_hrd_absen_kode_outlet ON public.ot_hrd_absen_harian(kode_outlet);
CREATE INDEX idx_ot_pos_trans_master_outlet ON public.ot_pos_trans_master(kode_outlet);
CREATE INDEX idx_ot_pos_trans_master_karyawan ON public.ot_pos_trans_master(kodekaryawan);
