# Breezze private media edge — Supabase Storage

Breezze uses **Supabase Storage**, not Cloudflare R2, for Breezze-owned or separately rights-cleared audio. This Cloudflare Worker retains the existing signed `/audio/{trackId}/{variant}?e=...&s=...` contract used by the NestJS API and Flutter player. It never accepts user uploads or ingests third-party streams.

## Setup

1. Create a Supabase project and apply `supabase/migrations/20261123000000_breezze_buckets.sql`. It creates a *private* `breezze-media` bucket with a restrictive policy denying direct anon/authenticated access. The Worker is the only intended privileged reader.
2. Add Worker secrets `MEDIA_SIGNING_KEY` (same strong secret used by the NestJS MediaSigner) and `SUPABASE_SERVICE_ROLE_KEY` (Supabase's backend-only service-role JWT).
3. Set `SUPABASE_URL` to the HTTPS project origin (e.g. `https://project-ref.supabase.co`) and optionally `SUPABASE_MEDIA_BUCKET` to `breezze-media`. Keep the service-role secret out of the Flutter app, commits, logs, and public environment variables.
4. Deploy the Worker using Wrangler after the account and secrets are ready; configure the NestJS `CDN_BASE_URL` to its HTTPS origin and `MEDIA_SIGNING_KEY` to the matching key.
5. Import only recordings that Breezze is **licensed to host and deliver**, at paths `audio/{canonicalTrackId}/{variant}`. Test a signed, short-lived GET, HEAD and byte-range stream, then confirm an expired signature is rejected.

The Worker verifies HMAC signature and expiry **before** accessing Supabase. It forwards only validated HTTP range requests, handles missing objects, refuses redirects, and strips privileged upstream headers. Responses are `private, no-store`, so signed audio cannot accidentally enter shared CDN caches.

Supabase's Free tier has only **1 GB file storage** and limited egress. Do not use it as an unlimited music-CDN or rehost YouTube Music/Deezer recordings. Keep approved external provider playback direct-to-provider.

**Important:** this migration does not move Breezze's current Railway PostgreSQL data or change existing login sessions. See `supabase/README.md` for the staged database + Auth migration. Do not cut over the live production DB without a verified backup, a schema migration, a data reconciliation plan and a rollback point.
