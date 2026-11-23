-- Apply only in a NEW Breezze Supabase project, before Prisma migrations.
-- Keep Breezze private operational tables out of the Supabase Data API.
CREATE SCHEMA IF NOT EXISTS breezze;
REVOKE ALL ON SCHEMA breezze FROM PUBLIC, anon, authenticated;
-- Then configure Prisma DATABASE_URL with ?schema=breezze and
-- run all Prisma migrations on the dedicated Supabase PostgreSQL database.
-- Do not expose the 'breezze' schema in the Supabase Data API settings.
