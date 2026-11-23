-- Optional private listener-avatar storage in the dedicated Breezze Supabase project.
-- Full-track audio lives exclusively in Cloudflare R2, NOT Supabase Storage.
-- Do not apply this to the unrelated 'metro bot' project.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'breezze-avatars', 'breezze-avatars', false, 5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- There is no direct client upload policy yet because Breezze's existing
-- session IDs have not been migrated to Supabase Auth. Once that migration
-- succeeds, add explicit auth.uid()-ownership policies for user folders.
-- Until then, the backend service role alone may access profile avatars.
-- Restrictive policy protects this bucket even if the project later has
-- a permissive policy for unrelated Storage resources.
CREATE POLICY breezze_avatar_no_direct_client_access
ON storage.objects AS RESTRICTIVE
FOR ALL TO anon, authenticated
USING (bucket_id <> 'breezze-avatars')
WITH CHECK (bucket_id <> 'breezze-avatars');
