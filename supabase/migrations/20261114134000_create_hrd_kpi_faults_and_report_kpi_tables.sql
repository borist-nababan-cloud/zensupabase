-- ==============================================================================
-- MIGRATION: 20261114134000_create_hrd_kpi_faults_and_report_kpi_tables.sql
-- Description:
-- Creates Transaction tables and view for Departmental KPI (non-TR/TB):
-- 1. public.hrd_kpi_faults (Employee faults transaction table)
-- 2. public.view_hrd_kpi_faults (Joined view with outlet, employee, and user names)
-- 3. public.hrd_report_kpi (Employee KPI evaluation header)
-- 4. public.hrd_report_kpi_detail (Employee KPI evaluation variable scores)
-- ==============================================================================

-- 1. Employee Faults Transaction Table (hrd_kpi_faults)
CREATE TABLE IF NOT EXISTS public.hrd_kpi_faults (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tanggal DATE NOT NULL DEFAULT CURRENT_DATE,
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON UPDATE CASCADE,
    kodekaryawan TEXT NOT NULL REFERENCES public.ot_hrd_karyawan_info(kodekaryawan) ON UPDATE CASCADE,
    idkaryawan INTEGER NOT NULL DEFAULT 0,
    fault_id UUID REFERENCES public.hrd_kpi_master_faults(uid) ON DELETE SET NULL,
    nama_faults TEXT NOT NULL,
    kategori TEXT NOT NULL CHECK (kategori IN ('Ringan', 'Sedang', 'Berat')),
    pengurang INTEGER NOT NULL CHECK (pengurang > 0),
    keterangan TEXT,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hrd_kpi_faults_tanggal_outlet ON public.hrd_kpi_faults(tanggal, kode_outlet);
CREATE INDEX IF NOT EXISTS idx_hrd_kpi_faults_karyawan ON public.hrd_kpi_faults(kodekaryawan);
CREATE INDEX IF NOT EXISTS idx_hrd_kpi_faults_fault_id ON public.hrd_kpi_faults(fault_id);

-- 2. View for Reporting & Easy Frontend Querying
CREATE OR REPLACE VIEW public.view_hrd_kpi_faults AS
SELECT
    f.uid,
    f.tanggal,
    f.kode_outlet,
    o.name_outlet,
    o.city,
    f.kodekaryawan,
    f.idkaryawan,
    k.namakaryawan,
    k.departemen,
    k.isadmin,
    f.fault_id,
    f.nama_faults,
    f.kategori,
    f.pengurang,
    f.keterangan,
    f.created_by,
    f.created_at,
    f.update_by,
    f.update_at,
    COALESCE(u_upd.full_name, u_upd.email, 'Petugas') AS update_by_name,
    COALESCE(u_crt.full_name, u_crt.email, 'Petugas') AS created_by_name
FROM public.hrd_kpi_faults f
LEFT JOIN public.master_outlet o ON f.kode_outlet = o.kode_outlet
LEFT JOIN public.ot_hrd_karyawan_info k ON f.kodekaryawan = k.kodekaryawan
LEFT JOIN public.users_profile u_upd ON f.update_by = u_upd.uid
LEFT JOIN public.users_profile u_crt ON f.created_by = u_crt.uid;

ALTER VIEW public.view_hrd_kpi_faults SET (security_invoker = true);

-- 3. Employee KPI Evaluation Header (hrd_report_kpi)
CREATE TABLE IF NOT EXISTS public.hrd_report_kpi (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_report TEXT NOT NULL UNIQUE,
    tanggal_report DATE NOT NULL DEFAULT CURRENT_DATE,
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON UPDATE CASCADE,
    kodekaryawan TEXT NOT NULL REFERENCES public.ot_hrd_karyawan_info(kodekaryawan) ON UPDATE CASCADE,
    departemen TEXT,
    payrollperiode TEXT,
    total_pengurang NUMERIC(5,2) NOT NULL DEFAULT 0,
    nilai_total NUMERIC(5,2) NOT NULL DEFAULT 0,
    kesimpulan TEXT,
    nilai_guest INTEGER DEFAULT 0,
    catatan_auto TEXT,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hrd_report_kpi_kodekaryawan ON public.hrd_report_kpi(kodekaryawan);
CREATE INDEX IF NOT EXISTS idx_hrd_report_kpi_kode_outlet ON public.hrd_report_kpi(kode_outlet);
CREATE INDEX IF NOT EXISTS idx_hrd_report_kpi_departemen ON public.hrd_report_kpi(departemen);
CREATE INDEX IF NOT EXISTS idx_hrd_report_kpi_tanggal ON public.hrd_report_kpi(tanggal_report DESC);
CREATE INDEX IF NOT EXISTS idx_hrd_report_kpi_created_at ON public.hrd_report_kpi(created_at DESC);

-- 4. Employee KPI Evaluation Detail (hrd_report_kpi_detail)
CREATE TABLE IF NOT EXISTS public.hrd_report_kpi_detail (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL REFERENCES public.hrd_report_kpi(uid) ON DELETE CASCADE,
    variable_id UUID REFERENCES public.hrd_kpi_variable(uid) ON DELETE SET NULL,
    nama_variable TEXT NOT NULL,
    nama_kategori TEXT,
    nilai_variable INTEGER NOT NULL DEFAULT 5 CHECK (nilai_variable >= 0 AND nilai_variable <= 10),
    catatan_variable TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hrd_report_kpi_detail_report_id ON public.hrd_report_kpi_detail(report_id);

-- 5. Enable RLS & Grants
ALTER TABLE public.hrd_kpi_faults ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hrd_report_kpi ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hrd_report_kpi_detail ENABLE ROW LEVEL SECURITY;

GRANT ALL ON TABLE public.hrd_kpi_faults TO authenticated, service_role;
GRANT SELECT ON TABLE public.view_hrd_kpi_faults TO authenticated, service_role;
GRANT ALL ON TABLE public.hrd_report_kpi TO authenticated, service_role;
GRANT ALL ON TABLE public.hrd_report_kpi_detail TO authenticated, service_role;

-- 6. RLS Policies
DO $$
BEGIN
    -- hrd_kpi_faults
    DROP POLICY IF EXISTS "Allow authenticated read hrd_kpi_faults" ON public.hrd_kpi_faults;
    CREATE POLICY "Allow authenticated read hrd_kpi_faults"
        ON public.hrd_kpi_faults FOR SELECT
        TO authenticated, service_role
        USING (true);

    DROP POLICY IF EXISTS "Allow authenticated insert hrd_kpi_faults" ON public.hrd_kpi_faults;
    CREATE POLICY "Allow authenticated insert hrd_kpi_faults"
        ON public.hrd_kpi_faults FOR INSERT
        TO authenticated, service_role
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated update hrd_kpi_faults" ON public.hrd_kpi_faults;
    CREATE POLICY "Allow authenticated update hrd_kpi_faults"
        ON public.hrd_kpi_faults FOR UPDATE
        TO authenticated, service_role
        USING (true)
        WITH CHECK (true);

    DROP POLICY IF EXISTS "Allow authenticated delete hrd_kpi_faults" ON public.hrd_kpi_faults;
    CREATE POLICY "Allow authenticated delete hrd_kpi_faults"
        ON public.hrd_kpi_faults FOR DELETE
        TO authenticated, service_role
        USING (true);

    -- hrd_report_kpi
    DROP POLICY IF EXISTS "Allow authenticated read hrd_report_kpi" ON public.hrd_report_kpi;
    CREATE POLICY "Allow authenticated read hrd_report_kpi"
        ON public.hrd_report_kpi FOR SELECT
        TO authenticated, service_role
        USING (true);

    DROP POLICY IF EXISTS "Allow authenticated write hrd_report_kpi" ON public.hrd_report_kpi;
    CREATE POLICY "Allow authenticated write hrd_report_kpi"
        ON public.hrd_report_kpi FOR ALL
        TO authenticated, service_role
        USING (true)
        WITH CHECK (true);

    -- hrd_report_kpi_detail
    DROP POLICY IF EXISTS "Allow authenticated read hrd_report_kpi_detail" ON public.hrd_report_kpi_detail;
    CREATE POLICY "Allow authenticated read hrd_report_kpi_detail"
        ON public.hrd_report_kpi_detail FOR SELECT
        TO authenticated, service_role
        USING (true);

    DROP POLICY IF EXISTS "Allow authenticated write hrd_report_kpi_detail" ON public.hrd_report_kpi_detail;
    CREATE POLICY "Allow authenticated write hrd_report_kpi_detail"
        ON public.hrd_report_kpi_detail FOR ALL
        TO authenticated, service_role
        USING (true)
        WITH CHECK (true);
END $$;

NOTIFY pgrst, 'reload schema';
