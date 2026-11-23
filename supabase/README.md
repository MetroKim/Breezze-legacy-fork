# Breezze — Supabase + Cloudflare R2 hybrid

## Architecture decision

**Supabase:** hosted PostgreSQL database for Breezze operational data, plus an optional **private avatar bucket**. **Auth0:** new hosted account and Universal Login identity provider; it is separate from Supabase Postgres.  
**Cloudflare:** private R2 `breezze-media` bucket for Breezze-owned/rights-cleared audio, `breezze-media` Worker for HMAC-signed ranged reads, and `breezze-api-edge` Worker for HTTPS/CORS/authenticated API routing.  
**Railway:** existing NestJS app, Redis and metadata services continue while the separate Supabase database migration and Auth0 identity cutover are validated.  
**Flutter:** connects to the NestJS API and approved providers; no database admin key, R2 credential or service-role key is ever embedded in an app binary.

```text
Flutter --HTTPS--> Cloudflare API Worker --> Railway NestJS API
                                              | Prisma
                                              v
                                Supabase Postgres (after verified data migration)
                                              |
                               Auth0 Universal Login (after identity migration)

Flutter --time-limited signed URL--> Cloudflare Media Worker --> private R2
Flutter --provider-approved HTTPS------> Authorized streaming partners
```

## Proven and not-yet-live

- Cloudflare R2 activation now works; the private `breezze-media` bucket was created on November 23, 2026 in EEUR with Standard storage.
- R2 media Worker binding is `MEDIA_BUCKET`; its HMAC signing secret name is `MEDIA_SIGNING_KEY`. Objects are `audio/{canonicalTrackId}/{variant}`; every URL has an expiry and HMAC validated before any R2 read.
- **Dedicated Supabase Breezze project created and verified** on November 23, 2026: project ref `djwvyjtebmsavhcrmhxf`, organization **Allen's Org**, region `eu-west-2` (London), PostgreSQL 17.12, initial project cost quote **$0/month**, project `ACTIVE_HEALTHY`. Dashboard: https://supabase.com/dashboard/project/djwvyjtebmsavhcrmhxf. Existing unrelated project `metro bot` was intentionally not modified.
- Applied SQL migration `20261123180645_create_breezze_private_schema` to this new project. Its empty `breezze` schema is unexposed; verified `anon` and `authenticated` roles have **no USAGE** on the schema and the Supabase security advisor reported no findings. No application tables, user records, or production data have been imported.
- Current Railway Postgres is authoritative until backups, migrations, count/key reconciliation, encrypted data compatibility, rollback and new service credentials have been tested.
- Existing NestJS Argon2id/JWT user sessions cannot be blindly replaced by Auth0: migrate IDs/password-based logins, verified emails, OAuth identities, MFA, session revocation and account deletion semantics as a coordinated operation. Until migration, Breezze issues its own revocable app sessions after validating Auth0's signed identity.

## Database integration with the existing code

The NestJS backend already uses PostgreSQL through Prisma. The new dedicated Supabase project can host those tables without rewriting business services. `infra/supabase/schema_guard.sql` is already applied to project `djwvyjtebmsavhcrmhxf` as migration `20261123180645_create_breezze_private_schema`; keep `breezze` an **unexposed private schema**. Configure the destination Prisma connection string with `?schema=breezze` (and SSL as required), respecting Supabase's connection-pooler and migration guidance. Run migrations using an appropriate direct or session connection; do **not** overwrite production `DATABASE_URL` until the migrated copy is verified.

A separate `supabase/migrations/20261123000000_breezze_buckets.sql` defines only private profile-avatar storage (not media audio). Do not grant anonymous or authenticated access to backend data tables before implementing owner-scoped RLS policies. An R2 bucket is not the same as a Supabase Storage bucket.

## Supabase Auth identity bridge (legacy experimental code; Auth0 supersedes it)

A staged NestJS bridge is implemented at `POST /api/v1/auth/supabase/exchange` for *verified Supabase access JWTs* and `POST /api/v1/auth/supabase/link` for explicit linking from a currently authenticated Breezze session. The API contacts the configured Supabase `/auth/v1/user` endpoint using a **publishable** API key, then issues Breezze's existing revocable session-family JWT. It does **not** trust editable Supabase user metadata or merge by matching email. The bridge is disabled/fails closed until `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` are both configured on the NestJS service.

Prisma adds a unique `SupabaseAuthIdentity` mapping with a cascade foreign key to `User`. Supabase-managed new users have an invalid sentinel for Breezze's password hash and therefore cannot sign in using the legacy password endpoint. Existing users must link identities via a Breezze-authenticated request; an email collision returns `SUPABASE_ACCOUNT_LINK_REQUIRED` rather than taking over the account. Test coverage includes valid users, unverified email, token rejection, unrelated identity, account linking, and safe provider failures.

**Do not enable a Supabase-first login screen. Auth0 is now the selected authentication provider; keep this optional experimental bridge disabled and do not migrate live sessions until the Auth0 cutover passes all user-flow tests.** The Flutter API transport supports token exchange/link, but the existing UI intentionally retains its current sign-in behavior until migration. Supabase's publishable key is not a privileged secret and may be used in clients after configured; never ship `sb_secret_...` in Flutter.

## Flutter Supabase Auth feature gate (not selected for production)

The Flutter account controller also supports Supabase Auth email/password when explicitly enabled at build time:

- `BREEZZE_AUTH_PROVIDER=supabase`
- `BREEZZE_SUPABASE_URL=https://<dedicated-project>.supabase.co`
- `BREEZZE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...`

The Flutter client calls Supabase Auth directly using **only** the publishable key. A temporary Supabase user access token is exchanged through Breezze's `/auth/supabase/exchange` endpoint for a normal revocable Breezze device session, and the Supabase token is not stored locally. A signup requiring email verification shows a verification message instead of logging in.

**Keep this gate OFF** in production because Auth0 is the selected auth service. The relevant release gate is `BREEZZE_AUTH_PROVIDER=auth0` and backend Auth0 configuration documented at `infra/auth0/README.md`. The current production Flutter build retains its proven Breezze login, so users do not lose their libraries.

## Edge media configuration

- Cloudflare R2 bucket: `breezze-media` (private, no publicly exposed R2.dev endpoint).
- Cloudflare media Worker: `breezze-media`, `MEDIA_BUCKET` R2 binding.
- Worker secret: `MEDIA_SIGNING_KEY` (minimum 32 random bytes).
- NestJS API: `MEDIA_SIGNING_KEY` **must match** Worker secret; `CDN_BASE_URL` is exactly the HTTPS media Worker origin.
- Browser API: `WEB_ALLOWED_ORIGINS` Worker environment and `CORS_ALLOWED_ORIGINS` NestJS environment should contain *exact* trusted frontend origins; never use wildcard with credentials.
- All R2 objects remain private; upload only content the app can legally host and deliver. Provider-hosted licensed streams should continue to flow directly to Flutter.
- Never commit any signing, database or service-role credentials to the repository.

The `.github/workflows/deploy-r2-media.yml` workflow can deploy the Worker from the reviewed branch after the required CI environment secrets are configured and corresponding NestJS deployment is prepared. The Worker and API must agree on their HMAC signing key; a premature key rotation would invalidate existing signed URLs.

## Limitations

Supabase is not an unlimited free music-hosting or commercial-label licensing service. This hybrid preserves Cloudflare R2 for privately authorized audio and Supabase for accounts/data. All media still requires track-level rights and territory checks. The resulting app is not production-ready until existing production database migration, Auth0 tenant configuration and live sign-in, and all exact-head platform CI checks pass.
