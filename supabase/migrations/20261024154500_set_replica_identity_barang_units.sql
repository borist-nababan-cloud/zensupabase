-- Ensure barang_units has REPLICA IDENTITY FULL for real-time publications and updates
ALTER TABLE public.barang_units REPLICA IDENTITY FULL;

-- Synchronize base_uom and purchase_uom so both always have identical values
UPDATE public.barang_units
SET base_uom = purchase_uom
WHERE purchase_uom IS NOT NULL AND (base_uom IS NULL OR base_uom <> purchase_uom);
