# Breezze — Supabase + Cloudflare R2 hybrid

## Architecture decision

**Supabase:** hosted PostgreSQL database and future Auth provider for listener identity, plus an optional **private avatar bucket**.  
**Cloudflare:** private R2 `breezze-media` bucket for Breezze-owned/rights-cleared audio, `breezze-media` Worker for HMAC-signed ranged reads, and `breezze-api-edge` Worker for HTTPS/CORS/authenticated API routing.  
**Railway:** existing NestJS app, Redis and metadata services continue while Supabase database/Auth migration is validated.  
**Flutter:** connects to the NestJS API and approved providers; no database admin key, R2 credential or service-role key is ever embedded in an app binary.

```text
Flutter --HTTPS--> Cloudflare API Worker --> Railway NestJS API
                                              | Prisma
                                              v
                                Supabase Postgres (after verified data migration)
                                              |
                               Supabase Auth (after identity migration)

Flutter --time-limited signed URL--> Cloudflare Media Worker --> private R2
Flutter --provider-approved HTTPS------> Authorized streaming partners
```

## Proven and not-yet-live

- Cloudflare R2 activation now works; the private `breezze-media` bucket was created on November 23, 2026 in EEUR with Standard storage.
- R2 media Worker binding is `MEDIA_BUCKET`; its HMAC signing secret name is `MEDIA_SIGNING_KEY`. Objects are `audio/{canonicalTrackId}/{variant}`; every URL has an expiry and HMAC validated before any R2 read.
- Supabase account currently contains **one inactive project, `metro bot`**, which is unrelated; it was intentionally not modified. A dedicated Breezze Supabase project must be chosen or created before applying any schema change, and the user's organization and any applicable billing must be confirmed.
- Current Railway Postgres is authoritative until backups, migrations, count/key reconciliation, encrypted data compatibility, rollback and new service credentials have been tested.
- Existing NestJS Argon2id/JWT user sessions cannot be blindly replaced by Supabase Auth: migrate IDs/password-based logins, verified emails, OAuth identities, MFA, session revocation and 30-day deletion semantics as a coordinated operation.

## Database integration with the existing code

The NestJS backend already uses PostgreSQL through Prisma. A dedicated Supabase project can host those tables without rewriting business services. First apply `infra/supabase/schema_guard.sql` in the destination project; keep `breezze` an **unexposed private schema**. Configure the destination Prisma connection string with `?schema=breezze` (and SSL as required), respecting Supabase's connection-pooler and migration guidance. Run migrations using an appropriate direct or session connection; do **not** overwrite production `DATABASE_URL` until the migrated copy is verified.

A separate `supabase/migrations/20261123000000_breezze_buckets.sql` defines only private profile-avatar storage (not media audio). Do not grant anonymous or authenticated access to backend data tables before implementing owner-scoped RLS policies. An R2 bucket is not the same as a Supabase Storage bucket.

## Supabase Auth identity bridge (code ready, not live)

A staged NestJS bridge is implemented at `POST /api/v1/auth/supabase/exchange` for *verified Supabase access JWTs* and `POST /api/v1/auth/supabase/link` for explicit linking from a currently authenticated Breezze session. The API contacts the configured Supabase `/auth/v1/user` endpoint using a **publishable** API key, then issues Breezze's existing revocable session-family JWT. It does **not** trust editable Supabase user metadata or merge by matching email. The bridge is disabled/fails closed until `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` are both configured on the NestJS service.

Prisma adds a unique `SupabaseAuthIdentity` mapping with a cascade foreign key to `User`. Supabase-managed new users have an invalid sentinel for Breezze's password hash and therefore cannot sign in using the legacy password endpoint. Existing users must link identities via a Breezze-authenticated request; an email collision returns `SUPABASE_ACCOUNT_LINK_REQUIRED` rather than taking over the account. Test coverage includes valid users, unverified email, token rejection, unrelated identity, account linking, and safe provider failures.

**Do not enable a global Supabase-first login screen or migrate live sessions until a dedicated project is selected, this new mapping migration is applied and all user-flow tests pass.** The Flutter API transport supports token exchange/link, but the existing UI intentionally retains its current sign-in behavior until migration. Supabase's publishable key is not a privileged secret and may be used in clients after configured; never ship `sb_secret_...` in Flutter.

## Flutter sign-in feature gate

The Flutter account controller also supports Supabase Auth email/password when explicitly enabled at build time:

- `BREEZZE_AUTH_PROVIDER=supabase`
- `BREEZZE_SUPABASE_URL=https://<dedicated-project>.supabase.co`
- `BREEZZE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...`

The Flutter client calls Supabase Auth directly using **only** the publishable key. A temporary Supabase user access token is exchanged through Breezze's `/auth/supabase/exchange` endpoint for a normal revocable Breezze device session, and the Supabase token is not stored locally. A signup requiring email verification shows a verification message instead of logging in.

**Keep this gate OFF** in production until legacy accounts have been explicitly linked or migrated and Supabase/Auth project configuration, email verification, email delivery, password reset, OAuth, MFA and end-to-end sign-out acceptance are verified. The current production Flutter build retains its proven Breezze login, so users do not lose their libraries.

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

Supabase is not an unlimited free music-hosting or commercial-label licensing service. This hybrid preserves Cloudflare R2 for privately authorized audio and Supabase for accounts/data. All media still requires track-level rights and territory checks. The resulting app is not production-ready until a dedicated Supabase project and data migration are verified and all exact-head platform CI checks pass.
