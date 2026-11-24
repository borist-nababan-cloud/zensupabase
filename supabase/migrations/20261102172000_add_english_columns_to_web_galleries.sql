-- Migration: Add English columns to web_galleries
-- Date: 2026-11-02 17:20:00

ALTER TABLE public.web_galleries 
    ADD COLUMN IF NOT EXISTS title_en TEXT,
    ADD COLUMN IF NOT EXISTS description_en TEXT,
    ADD COLUMN IF NOT EXISTS category_en TEXT;

