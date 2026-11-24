-- ==============================================================================
-- MIGRATION: 20261105010000_create_hrd_therapist_evaluation_tables.sql
-- Description:
-- Creates Master-Detail tables for Therapist Performance Evaluations:
-- 1. hrd_report_tr_category (Categories of assessment)
-- 2. hrd_report_tr_variable (Evaluation variables under each category)
-- 3. hrd_report_tr (Evaluation header/document)
-- 4. hrd_report_tr_detail (Individual variable scores and remarks)
-- ==============================================================================

-- 1. Master Category
CREATE TABLE IF NOT EXISTS public.hrd_report_tr_category (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nama_kategori TEXT NOT NULL,
    urutan INTEGER NOT NULL DEFAULT 0,
    active BOOLEAN NOT NULL DEFAULT true,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Master Evaluation Variables
CREATE TABLE IF NOT EXISTS public.hrd_report_tr_variable (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id UUID NOT NULL REFERENCES public.hrd_report_tr_category(uid) ON DELETE RESTRICT,
    nama_variable TEXT NOT NULL,
    deskripsi TEXT,
    urutan INTEGER NOT NULL DEFAULT 0,
    active BOOLEAN NOT NULL DEFAULT true,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Evaluation Header (hrd_report_tr)
CREATE TABLE IF NOT EXISTS public.hrd_report_tr (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kode_report TEXT NOT NULL UNIQUE,
    tanggal_report DATE NOT NULL DEFAULT CURRENT_DATE,
    kode_outlet TEXT NOT NULL REFERENCES public.master_outlet(kode_outlet) ON UPDATE CASCADE,
    kodekaryawan TEXT NOT NULL REFERENCES public.ot_hrd_karyawan_info(kodekaryawan) ON UPDATE CASCADE,
    nilai_total NUMERIC(5,2) NOT NULL DEFAULT 0,
    kesimpulan TEXT,
    nilai_guest INTEGER DEFAULT 0,
    catatan_auto TEXT,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    update_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 4. Evaluation Detail (hrd_report_tr_detail)
CREATE TABLE IF NOT EXISTS public.hrd_report_tr_detail (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL REFERENCES public.hrd_report_tr(uid) ON DELETE CASCADE,
    variable_id UUID REFERENCES public.hrd_report_tr_variable(uid) ON DELETE SET NULL,
    nama_variable TEXT NOT NULL,
    nama_kategori TEXT,
    nilai_variable INTEGER NOT NULL DEFAULT 5 CHECK (nilai_variable >= 0 AND nilai_variable <= 10),
    catatan_variable TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Create Indexes for fast querying
CREATE INDEX IF NOT EXISTS idx_hrd_report_tr_kodekaryawan ON public.hrd_report_tr(kodekaryawan);
CREATE INDEX IF NOT EXISTS idx_hrd_report_tr_kode_outlet ON public.hrd_report_tr(kode_outlet);
CREATE INDEX IF NOT EXISTS idx_hrd_report_tr_tanggal ON public.hrd_report_tr(tanggal_report DESC);
CREATE INDEX IF NOT EXISTS idx_hrd_report_tr_created_at ON public.hrd_report_tr(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_hrd_report_tr_detail_report_id ON public.hrd_report_tr_detail(report_id);
CREATE INDEX IF NOT EXISTS idx_hrd_report_tr_var_category ON public.hrd_report_tr_variable(category_id);

-- Enable RLS on all tables
ALTER TABLE public.hrd_report_tr_category ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hrd_report_tr_variable ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hrd_report_tr ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hrd_report_tr_detail ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if re-running
DROP POLICY IF EXISTS "Allow authenticated read hrd_report_tr_category" ON public.hrd_report_tr_category;
DROP POLICY IF EXISTS "Allow authenticated write hrd_report_tr_category" ON public.hrd_report_tr_category;
DROP POLICY IF EXISTS "Allow authenticated read hrd_report_tr_variable" ON public.hrd_report_tr_variable;
DROP POLICY IF EXISTS "Allow authenticated write hrd_report_tr_variable" ON public.hrd_report_tr_variable;
DROP POLICY IF EXISTS "Allow authenticated read hrd_report_tr" ON public.hrd_report_tr;
DROP POLICY IF EXISTS "Allow authenticated write hrd_report_tr" ON public.hrd_report_tr;
DROP POLICY IF EXISTS "Allow authenticated read hrd_report_tr_detail" ON public.hrd_report_tr_detail;
DROP POLICY IF EXISTS "Allow authenticated write hrd_report_tr_detail" ON public.hrd_report_tr_detail;

-- Category policies: All authenticated can read; Authenticated can write
CREATE POLICY "Allow authenticated read hrd_report_tr_category"
ON public.hrd_report_tr_category FOR SELECT TO authenticated USING (true);

CREATE POLICY "Allow authenticated write hrd_report_tr_category"
ON public.hrd_report_tr_category FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Variable policies: All authenticated can read; Authenticated can write
CREATE POLICY "Allow authenticated read hrd_report_tr_variable"
ON public.hrd_report_tr_variable FOR SELECT TO authenticated USING (true);

CREATE POLICY "Allow authenticated write hrd_report_tr_variable"
ON public.hrd_report_tr_variable FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Evaluation Header policies: Authenticated can read & write
CREATE POLICY "Allow authenticated read hrd_report_tr"
ON public.hrd_report_tr FOR SELECT TO authenticated USING (true);

CREATE POLICY "Allow authenticated write hrd_report_tr"
ON public.hrd_report_tr FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Evaluation Detail policies: Authenticated can read & write
CREATE POLICY "Allow authenticated read hrd_report_tr_detail"
ON public.hrd_report_tr_detail FOR SELECT TO authenticated USING (true);

CREATE POLICY "Allow authenticated write hrd_report_tr_detail"
ON public.hrd_report_tr_detail FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Seed Initial Starter Categories & Variables (if table empty)
DO $$
DECLARE
    cat1_id UUID;
    cat2_id UUID;
    cat3_id UUID;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.hrd_report_tr_category LIMIT 1) THEN
        INSERT INTO public.hrd_report_tr_category (nama_kategori, urutan)
        VALUES ('Sikap & Penampilan (Grooming & Attitude)', 1) RETURNING uid INTO cat1_id;

        INSERT INTO public.hrd_report_tr_category (nama_kategori, urutan)
        VALUES ('SOP Pelayanan & Etika Tamu (Service & Hospitality)', 2) RETURNING uid INTO cat2_id;

        INSERT INTO public.hrd_report_tr_category (nama_kategori, urutan)
        VALUES ('Kualitas Teknik Pijat & Prosedur (Skill & Technique)', 3) RETURNING uid INTO cat3_id;

        -- Variables for Cat 1
        INSERT INTO public.hrd_report_tr_variable (category_id, nama_variable, deskripsi, urutan)
        VALUES 
            (cat1_id, 'Kerapihan Seragam & Higienitas Diri', 'Kerapihan seragam kerja, rambut rapi, kuku bersih, dan aroma tubuh segar', 1),
            (cat1_id, 'Ketepatan Waktu (Punctuality)', 'Disiplin masuk kerja dan ketepatan waktu hadir di ruang treatment', 2);

        -- Variables for Cat 2
        INSERT INTO public.hrd_report_tr_variable (category_id, nama_variable, deskripsi, urutan)
        VALUES 
            (cat2_id, 'Greeting & Keramahan Tamu', 'Menyapa tamu dengan sopan, senyum, dan etika Zen yang santun', 1),
            (cat2_id, 'Komunikasi & Konfirmasi Tekanan Pijat', 'Menanyakan kenyamanan dan tingkat tekanan pijat secara berkala', 2),
            (cat2_id, 'Kerapihan & Kebersihan Ruangan/Alat', 'Menjaga ruang treatment dan linen dalam kondisi bersih dan rapi', 3);

        -- Variables for Cat 3
        INSERT INTO public.hrd_report_tr_variable (category_id, nama_variable, deskripsi, urutan)
        VALUES 
            (cat3_id, 'Teknik & Alur Pijat Sesuai SOP Zen', 'Urutan pijatan, akurasi titik refleksi, dan kelancaran gerakan pijat', 1),
            (cat3_id, 'Ketepatan Durasi Treatment', 'Treatment diselesaikan tepat waktu sesuai paket durasi yang dipesan', 2);
    END IF;
END $$;

NOTIFY pgrst, 'reload schema';

