CREATE TABLE public.ot_hrd_presensi_rekap (
    -- Modern Supabase Primary Key
    id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    
    -- Outlet ID standardized per Global Rules
    kode_outlet varchar(3) NOT NULL,
    
    -- Legacy Local Identifiers (Used for Upserts)
    autonum bigint NOT NULL,
    
    -- Core Data
    payrollperiode varchar(50),
    tanggal date,
    kodekaryawan varchar(30) NOT NULL,
    idkaryawan varchar(5),
    tagmasuk varchar(3),
    tagkeluar varchar(3),
    tagauto varchar(3),
    tagresult varchar(3),
    selmasuk integer,
    selkeluar integer,
    jkwajib numeric,
    jkreal numeric,
    komisi numeric,
    notes text,
    keterangan text,
    libnas varchar(1) DEFAULT 'N',
    
    -- Legacy Audit
    lastedituser varchar(30),
    lasteditdate timestamptz,
    
    -- Modern Supabase Audit Fields
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    created_by text,
    
    -- Enforce uniqueness across all 10 outlets for the Sync Agent to Upsert against
    CONSTRAINT uq_presensi_rekap_outlet_autonum UNIQUE (kode_outlet, autonum),
    
    -- Foreign Key Constraint 
    CONSTRAINT fk_presensi_rekap_karyawan FOREIGN KEY (kodekaryawan) 
        REFERENCES public.ot_hrd_karyawan_info (kodekaryawan) 
        ON DELETE RESTRICT 
        ON UPDATE CASCADE
);

-- Index to speed up common queries for a specific employee and date
CREATE INDEX idx_presensi_rekap_karyawan_tgl ON public.ot_hrd_presensi_rekap (kodekaryawan, tanggal);
