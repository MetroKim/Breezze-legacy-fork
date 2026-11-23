# Breezze Cloudflare R2 media Worker

This Worker retrieves **Breezze-owned or explicitly rights-cleared** private audio from the Cloudflare R2 bucket `breezze-media`. The connected bucket is provisioned in EEUR Standard storage and has no public R2 URL.

The `MEDIA_BUCKET` binding is declared in `wrangler.toml`. Configure the `MEDIA_SIGNING_KEY` Worker secret to match the NestJS backend's `MEDIA_SIGNING_KEY`. Set NestJS `CDN_BASE_URL` to the HTTPS origin of the deployed `breezze-media` Worker after verification.

Authorization remains in NestJS's rights/territory service. The Worker only accepts time-limited HMAC-signed `GET` and `HEAD` for `/audio/{trackId}/{variant}`, supporting byte-range seeking and cache-safe responses. An unsigned link cannot read objects. Never expose an R2.dev public bucket URL or R2 credentials in Flutter.

The worker does not ingest Deezer/YouTube/Audius audio, accept uploads or grant music rights. Supabase is reserved for account identity, private application data and optional avatars; it is **not** the full-track media store.

To deploy, use the reviewed workflow in `.github/workflows/deploy-r2-media.yml` after the shared signing key, Cloudflare API token and account ID have been securely configured and smoke-tested. Keep the current Railway API and its database in place until migration acceptance.
