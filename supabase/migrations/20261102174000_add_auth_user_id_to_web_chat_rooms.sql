-- Migration: Add auth_user_id to web_chat_rooms
-- Date: 2026-11-02 17:40:00

ALTER TABLE public.web_chat_rooms
    ADD COLUMN IF NOT EXISTS auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_web_chat_rooms_auth_user
    ON public.web_chat_rooms(auth_user_id);

