-- Migration: Ensure non-STO / test / blank / laundry outlets have can_sto = false in master_outlet
UPDATE public.master_outlet
SET can_sto = false
WHERE kode_outlet IN ('102', '104', '108', '109', '111', '113', '114', '218', '902');

