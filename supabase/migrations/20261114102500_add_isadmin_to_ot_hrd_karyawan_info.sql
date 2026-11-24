-- Migration: Add isadmin column to ot_hrd_karyawan_info
-- Description: Stores admin capability flag ('Y'/'N') synced from ZenSystem Desktop ben_hrd_karyawan_info.isadmin for future WHM user capability management.

ALTER TABLE public.ot_hrd_karyawan_info
ADD COLUMN IF NOT EXISTS isadmin TEXT;
