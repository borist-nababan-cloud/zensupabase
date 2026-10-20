-- Migration: Seed master role_user records
-- Description: Seeds the authoritative 10 system roles from backup for Warehouse Management & RBAC.

SET ROLE postgres;

INSERT INTO public.role_user (id, role_name, created_at) VALUES
    (1, 'admin_holding', '2025-12-28 10:46:22.541486+00'),
    (2, 'gudang_holding', '2025-12-28 10:46:22.541486+00'),
    (3, 'laundry_admin', '2025-12-28 10:46:22.541486+00'),
    (4, 'gudang_laundry', '2025-12-28 10:46:22.541486+00'),
    (5, 'finance', '2025-12-28 10:46:22.541486+00'),
    (6, 'outlet_admin', '2025-12-28 10:46:22.541486+00'),
    (7, 'gudang_outlet', '2025-12-28 10:46:22.541486+00'),
    (8, 'SUPERUSER', '2025-12-28 10:46:22.541486+00'),
    (9, 'UNASSIGNED', '2025-12-28 10:46:22.541486+00'),
    (10, 'finance_outlet', '2026-01-12 13:42:59.227567+00')
ON CONFLICT (id) DO UPDATE SET
    role_name = EXCLUDED.role_name;
