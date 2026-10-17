-- Supabase Migration: Add Foreign Key Constraints to master_outlet
SET ROLE postgres;
-- Description: Links kode_outlet on all sync tables to master_outlet(kode_outlet)

ALTER TABLE public.ot_hrd_absen_harian 
ADD CONSTRAINT ot_hrd_absen_harian_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.ot_hrd_karyawan_details 
ADD CONSTRAINT ot_hrd_karyawan_details_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.ot_hrd_karyawan_info 
ADD CONSTRAINT ot_hrd_karyawan_info_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.ot_hrd_karyawan_payroll_details 
ADD CONSTRAINT ot_hrd_karyawan_payroll_details_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.ot_hrd_presensi_rekap 
ADD CONSTRAINT ot_hrd_presensi_rekap_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.ot_pos_trans_detail 
ADD CONSTRAINT ot_pos_trans_detail_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.ot_pos_trans_master 
ADD CONSTRAINT ot_pos_trans_master_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.ot_pos_trans_payment 
ADD CONSTRAINT ot_pos_trans_payment_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.ot_pos_trans_payment_details 
ADD CONSTRAINT ot_pos_trans_payment_details_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.ot_pos_trans_reject 
ADD CONSTRAINT ot_pos_trans_reject_outlet_fkey 
FOREIGN KEY (kode_outlet) REFERENCES public.master_outlet (kode_outlet) 
ON DELETE RESTRICT ON UPDATE CASCADE;
