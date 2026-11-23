# Breezze — Supabase-first infrastructure

**Decision:** Use Supabase for the hosted PostgreSQL database, email/password Auth, and private Storage; retain Flutter, the NestJS business API, Redis for transient queues/cache, and provider-hosted authorized audio streaming. Supabase replaces the **R2 storage dependency**, not the need for a backend process.

## Already prepared in this repository

- `infra/cloudflare/media-worker` now reads approved private audio from Supabase Storage rather than an R2 bucket.
- `supabase/migrations/20261123000000_breezze_buckets.sql` creates locked-down `breezze-media` and `breezze-avatars` buckets.
- Existing Prisma models use PostgreSQL, so the NestJS API can be migrated to Supabase's Postgres after a verified data export/import and suitable connection-pool settings.
- Breezze's current account sessions and passwords remain on the existing database until a tested, explicitly scheduled Auth migration takes place.

## Secure, staged cutover

1. **Create/connect the Supabase project.** Check Free plan quotas and pause behaviour before launch. Do not enable a paid subscription just for this migration.
2. **Private media:** apply the Storage migration, add secret API key only to the Worker, match the NestJS signing key, and test GET, HEAD, Range, 404, expiry and 403. Do not embed the secret in Flutter.
3. **PostgreSQL:** take a verified restore-capable backup of the Railway database; apply Prisma migrations to a separate Supabase development database; migrate and reconcile every table, foreign key, count and sensitive encrypted record. Update `DATABASE_URL` only in a guarded release with rollback available. In Supabase use a correctly scoped transaction/session pooler URL compatible with Prisma; use direct DB access for migrations when possible.
4. **Authentication:** Supabase Auth and Breezze's existing custom JWT accounts are *different identity systems*. Do not replace login endpoints until user IDs, Argon2id password handling, provider identities, app sessions, refresh-token theft handling, MFA and account deletion semantics are migrated and verified together. Use a short compatibility transition with a server-side identity mapping; never copy raw passwords or downgrade hash security. Do not issue Supabase service-role credentials to a client.
5. **User data security:** preserve current NestJS owner checks; enable RLS and auth.uid()-scoped policies for all new public tables that will be queried directly by `supabase_flutter` after Auth migration. Until that verification, do **not** grant broad `anon` or `authenticated` access.
6. **CORS:** the API edge and NestJS both already support an exact-origin allowlist. Configure the actual deployed web origin; no billing product is needed for CORS.

## Configuration map (names only; never commit secret values)

| Runtime | Name | Purpose |
|---|---|---|
| Cloudflare media Worker | `SUPABASE_URL` | Supabase project HTTPS origin |
| Cloudflare media Worker | `SUPABASE_SECRET_KEY` | Private server-only Storage access |
| Cloudflare media Worker | `SUPABASE_MEDIA_BUCKET` | `breezze-media` |
| Cloudflare media Worker | `MEDIA_SIGNING_KEY` | Shared HMAC key used only after rights authorization |
| NestJS API | `CDN_BASE_URL` | HTTPS origin of deployed media Worker |
| NestJS API | `MEDIA_SIGNING_KEY` | Same HMAC key as Worker |
| NestJS API | `DATABASE_URL` | Supabase PostgreSQL connection after migration |
| NestJS API / edge | `CORS_ALLOWED_ORIGINS` / `WEB_ALLOWED_ORIGINS` | Explicitly approved frontend origins |
| Flutter (only after Auth migration) | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | Public project URL and publishable client key; **never** secret API key |

## Limitations

A free Supabase project is not an unlimited audio host; media traffic and user growth may exceed the storage/egress allowance. Supabase provides no commercial full-track rights. Deezer/YouTube Music discovery or cookies do not grant Breezze rights to download or redistribute audio. OAuth provider registration may still require the provider's own configuration or developer membership.

**Deploy status:** integration code is on a draft branch; no Supabase project URL or secret has been supplied/connected yet. The production API still uses the old DB and code until an explicit, verified cutover.


## Supabase-native media path (preferred)

A Supabase Edge Function at `supabase/functions/media/index.ts` now handles short-lived media grants. It uses the **same HMAC and private Storage handler** as the Cloudflare fallback. Configure `MEDIA_BACKEND=supabase` and `CDN_BASE_URL=https://<project-ref>.supabase.co/functions/v1/media` only after the destination Supabase project exists, the Storage migration has been applied, the function is deployed, and its signed/ranged requests have been verified. No Cloudflare R2 billing is required. The API's **existing JWT auth and Prisma database have not been migrated**; they cannot be safely switched merely by inserting a project URL.

For Supabase's newer server secret keys (`sb_secret_...`), send the key as the `apikey` header, not a JWT bearer token. Supabase Edge Functions receive these server-only keys in the `SUPABASE_SECRET_KEYS` JSON variable. Never ship it to Flutter. <https://supabase.com/docs/guides/getting-started/migrating-to-new-api-keys>

The connected Supabase account currently exposes an *inactive, unrelated* project named **metro bot**; no Breezze project has been selected or created, so **no live Supabase data or production secrets have been changed**. Avoid running migration SQL against that unrelated project.
