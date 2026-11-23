-- Breezze private Supabase Storage buckets.
-- Execute in the destination Supabase project through controlled migrations.
-- No third-party provider recordings may be uploaded without hosting rights.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'breezze-media', 'breezze-media', false, 52428800,
  ARRAY['audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/flac', 'audio/ogg']
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'breezze-avatars', 'breezze-avatars', false, 5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Restrictive policies prevent browser/mobile users from reading or writing
-- either bucket directly even if another permissive storage.objects policy
-- has been created for unrelated buckets. Only the privileged backend
-- service role (which bypasses RLS) may access these objects for now.
CREATE POLICY breezze_storage_no_direct_client_access
ON storage.objects AS RESTRICTIVE
FOR ALL TO anon, authenticated
USING (bucket_id NOT IN ('breezze-media', 'breezze-avatars'))
WITH CHECK (bucket_id NOT IN ('breezze-media', 'breezze-avatars'));

-- No public bucket, no public URL, and no auth.uid()-based user write
-- until Breezze's existing sessions are migrated to Supabase Auth.
