-- ==============================================================================
-- MIGRATION: 20261029221000_harden_sto_inventory_triggers.sql
-- Description:
-- 1. Harden process_sto_rejection_reversal() with a strict state-transition guard
--    (OLD.recipient_status IS DISTINCT FROM 'REJECTED') so repeated row updates
--    on a rejected STO can never double-refund stock to the Sender outlet.
-- 2. Update last_movement_at = NOW() on inventory_balance when stock is returned
--    to the Sender outlet upon STO rejection.
-- 3. Call ensure_outlet_inventory() in both process_sto_rejection_reversal() and
--    process_sto_shipment_deduct() (matching process_sto_receipt_add()) so an
--    inventory_balance slot is guaranteed to exist before stock deduction or reversal.
-- ==============================================================================

-- 1. Harden STO Rejection Reversal Trigger Function
CREATE OR REPLACE FUNCTION public.process_sto_rejection_reversal()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  shipment_rec RECORD;
BEGIN
  -- Strictly run ONLY when recipient_status transitions into 'REJECTED' for a SHIPPED STO
  IF NEW.recipient_status = 'REJECTED'
     AND OLD.recipient_status IS DISTINCT FROM 'REJECTED'
     AND OLD.sender_status = 'SHIPPED' THEN

    -- Loop through all items shipped for this STO
    FOR shipment_rec IN
      SELECT si.barang_id, si.qty_shipped
      FROM public.sto_shipment_items si
      JOIN public.sto_shipments s ON si.shipment_id = s.id
      WHERE s.sto_id = NEW.id
    LOOP
      -- Ensure Inventory Slot Exists for Sender Outlet
      PERFORM public.ensure_outlet_inventory(shipment_rec.barang_id, NEW.from_outlet);

      -- Add Stock BACK to Sender with movement audit timestamp
      UPDATE public.inventory_balance
      SET qty_on_hand = qty_on_hand + shipment_rec.qty_shipped,
          last_movement_at = NOW()
      WHERE barang_id = shipment_rec.barang_id
        AND kode_outlet = NEW.from_outlet;
    END LOOP;

  END IF;
  RETURN NEW;
END;
$function$;

-- 2. Harden STO Shipment Deduction Trigger Function
CREATE OR REPLACE FUNCTION public.process_sto_shipment_deduct()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  sender_outlet TEXT;
BEGIN
  -- Find Sender Outlet from STO
  SELECT from_outlet INTO sender_outlet
  FROM public.sto_orders
  WHERE id = (SELECT sto_id FROM public.sto_shipments WHERE id = NEW.shipment_id);

  -- Ensure Inventory Slot Exists for Sender Outlet before deducting
  IF sender_outlet IS NOT NULL THEN
    PERFORM public.ensure_outlet_inventory(NEW.barang_id, sender_outlet);

    -- Deduct Inventory
    UPDATE public.inventory_balance
    SET qty_on_hand = qty_on_hand - NEW.qty_shipped,
        last_movement_at = NOW()
    WHERE barang_id = NEW.barang_id
      AND kode_outlet = sender_outlet;
  END IF;

  RETURN NEW;
END;
$function$;

NOTIFY pgrst, 'reload schema';

