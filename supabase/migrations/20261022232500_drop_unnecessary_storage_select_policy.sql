-- Migration: Remove broad SELECT policy on public storage bucket 'zen-releases'
-- Resolves Supabase Security Advisor warning: "Clients can list all files in this bucket"
-- Since 'zen-releases' is a public bucket (public = true), public downloads via CDN 
-- do NOT require an RLS SELECT policy. Dropping this policy prevents unauthorized 
-- enumeration/listing while keeping public file downloads 100% operational.

DROP POLICY IF EXISTS "Public Read Access on zen-releases" ON storage.objects;
