-- ============================================================================
-- Migration 1: Add 'RETURNED' value to public.po_status enum
-- Date: 2026-11-25
-- Note: Must be in its own migration transaction before referencing 'RETURNED'
--       in views or PL/pgSQL functions (avoids PostgreSQL SQLSTATE 55P04).
-- ============================================================================

ALTER TYPE public.po_status ADD VALUE IF NOT EXISTS 'RETURNED';
