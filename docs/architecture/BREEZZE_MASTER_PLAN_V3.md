# Breezze Master Plan v3 — implementation baseline

**Status:** Adopted as the target architecture, not a claim that all eleven phases are complete. The existing Flutter + NestJS + Prisma deployment remains supported until each replacement passes its acceptance gate. Never remove the old data source or deploy incompatible clients/backend independently.

## 1. Product contract

- Listener-first, free to use, no subscriptions, billing, ads, radio tab, or social graph.
- Primary navigation: **Home · Browse · Library · Search**, persistent global mini-player and Now Playing.
- Custom, on-brand Flutter authentication UI, styled with Breezze's existing design tokens and SVG icons; OS-managed Google/Apple consent remains native.
- Supported build targets: Android, iOS, web, Windows, macOS, Linux (verify runtime behavior per platform; platform packaging and background audio are not uniform).
- Metadata discovery is not permission to stream, cache, rip, or download third-party recordings. All playback, DRM, region restrictions, provider authentication and offline rights are validated server-side.

## 2. Target topology and migration seam

```text
 Flutter (Riverpod + custom Supabase Auth UI + shared player)
   |  \-- Supabase Auth (GoTrue) / Postgres, with RLS for personal data
   |  \-- Supabase Edge Functions (thin, user-JWT-verified orchestration)
   |        |-- YouTube Music discovery: metadata only (Python)
   |        |-- Deezer: rights-authorized playback only (Node)
   |        |-- Lyrics (LRCLIB, subject to its terms)
   |        \-- cache with authenticated tenant-aware keys + expiry
   \----- Current NestJS / Prisma API (migration compatibility and rights guard)
                 \-- existing user libraries/catalog/queue endpoints
```

The **Flutter client must never receive provider account credentials**, server-side ARL tokens, Supabase service-role/secret keys, or decrypted credential records. Authentication and authorization are separate: a valid session does not imply entitlement to a stream.

**Rollout rule:** Supabase is the source of identity now, and `public.profiles` becomes the source of user profile display data. Existing canonical tracks, favorites, playlists and listening history remain in Prisma until data migrations, parallel-run comparisons, signed-off access tests and reversible cutover. No automatic UUID/email merging of pre-existing accounts.

**Supabase Edge Functions:** initially limited to stateless, low-latency orchestration; do not move every NestJS route immediately. Resolve per-request user access tokens and rights on the server, never proxy unlicensed streams. The function can call specialist services through authenticated, private service APIs. `EdgeRuntime.waitUntil` is bounded background execution, **not an unlimited long-running job runner**; heavy exports belong in a dedicated worker or queue. Cron (pg_cron/pg_net) is an optional scheduled trigger, with limits and idempotency.

## 3. Auth — one Supabase identity authority

- Flutter: `supabase_flutter`; Google with `google_sign_in` 7.x; Apple with `sign_in_with_apple`.
- Google: obtain the Google ID token and, via `GoogleSignInAccount.authorizationClient`, the access token for basic identity scopes, then call `signInWithIdToken(provider: google, idToken:, accessToken:)`. Native Android needs a matching OAuth signing SHA-1. Current Breezze web and iOS clients are configured in Google Cloud/Supabase; client secret is configured in Supabase.
- Apple: native `signInWithIdToken(provider: apple, idToken:, nonce: rawNonce)` with a SHA-256-hashed nonce sent to Apple. Apple Developer Program membership **not active**; keep integration code but leave the Apple provider unlaunched until app identifiers, entitlements and credentials can be created. Web/other platforms use configured Apple OAuth only after its Service ID and signing key are active. Apple private .p8 keys should be protected; it is the **signed client-secret JWT** that expires and needs renewal (typically no more than six months), not an automatic six-month rotation of the private .p8 file.
- Email/password: fully custom Breezze widgets; email verification, password reset + deep-link callback and deletion are acceptance requirements.
- Signed-out guest browsing: local device-scoped state, no pretend server authority or `auth.uid()`. Guest data is not synced as another user's account. Upgrade to an account via explicit migration of locally-owned data.
- Subscribe to `onAuthStateChange` **with `onError`**. Supabase owns refresh and sessions. Native sessions use an explicit `flutter_secure_storage` `LocalStorage` adapter; web uses the SDK's browser persistence. Avoid persisting raw tokens in extra stores or logs.
- Apply strict per-user access checks in every Prisma endpoint during migration. Never trust client-supplied `user_id` or user-editable `user_metadata` as authorization proof.
- Preserve BREEZZE styling, not a hosted Supabase login UI.
- Apple pending activation **must not block Google or email tests**.

## 4. First deployed Supabase data layer: profiles

`public.profiles` now exists in the connected Breezze Supabase project. It is keyed by `auth.users.id`, has own-row-only `SELECT/INSERT/UPDATE` policies, enables RLS, blocks Supabase anonymous identities, and contains `display_name, handle, avatar_url, country, created_at, updated_at`. An isolated private trigger creates profiles on new Auth signups; there is a backfill for existing Auth users. The SQL in `docs/database/BREEZZE_V3_PROFILES_RLS.sql` is the reproducible baseline.

**Verified:** table and FK exist; RLS on; Supabase security advisor: 0 findings; performance advisor: 0 findings. No Supabase Auth users were present at the time of the check, so a real signed-in profile insert/read/write isolation test is still a gate.

Planned follow-on tables, **not yet deployed**:
- `public.user_library`: user-scoped track keys, saved timestamps, unique `(user_id, track_id)`; RLS on all reads/writes; indexed `user_id`.
- `public.pinned_playlists`: `(user_id, playlist_id, position)`, owner-only RLS, indexed by owner.
- `public.connected_providers`: metadata only (provider name/status). **Never expose provider credentials or decrypted secrets in public tables**, even with RLS. Put server-managed encrypted credentials in an unexposed private schema or secrets manager, with tightly scoped server-only access.
- Canonical catalog / playlists / history: create a specific one-way + backfill + reconciliation + rollback migration contract per table before re-pointing Flutter away from Prisma.

All owner policies must include `TO authenticated`, `USING (auth.uid() = owner)`, and for writes `WITH CHECK`. Ensure `anon` cannot read profiles; server-verified authorization remains mandatory for playback.

## 5. Flutter and media

| Domain | v3 target | Release condition |
| --- | --- | --- |
| UI shell | existing Riverpod + go_router + design system | four tabs, mini-player survives navigation |
| Standard audio | just_audio + audio_service + audio_session | queue, gapless, interruption recovery, lock-screen and route tests |
| Custom DSP | evaluate `flutter_soloud` custom filters | no Dart VM calls, locks, allocation or blocking I/O on real-time native callback |
| Hi-fi crossfade + EQ | **evaluate** `sautiflow` rather than stacking two active engines | compatibility, licensing, measured latency, queue continuity, battery and platform coverage |
| Video | evaluate `media_kit` decoder pooling with 3–5 LRU instances | limit actual concurrently decoding players; benchmark 20-video navigation on low-end Android |
| Local data | existing Drift/SQLite; do not introduce Hive/Isar solely because plan lists them | encrypted secrets never stored as plain rows; offline state survives reinstall only if intended |
| Search intelligence | stage `flutter_edge_ai` / EmbeddingGemma 2 | text-only 270M pilot first; cap RAM/download; user-opt-in model download; switch to 740M multimodal only after mobile benchmark |
| Lyrics | LRCLIB under provider terms | valid synchronized timecodes, fallbacks, accessibility |

Do **not** feed a streaming URL into multiple independent audio players simultaneously: a single authoritative playback state/queue must own controls. Feature-flag DSP engines until crossfade and background media sessions are verified. Spatial DSP is **not Dolby Atmos** certification, and lossless playback is dependent on source format, license and output path.

Semantic search only covers embeddings actually derived for the user's **local authorized library**. Text-based metadata embeddings cannot masquerade as full audio-similarity search. Do not bundle the 740M model with every install; gate it by opt-in, supported devices, disk/battery/network budget and real benchmarks. Cache vectors locally with model version and invalidate on model upgrades.

## 6. Acceptance gates / phase order

1. **Identity foundation:** Google + custom email functional on emulator and web, Supabase session restore + refresh, failed-token paths, RLS tests, no cross-user leaks. Apple held pending enrollment.
2. **Profiles and account:** link profile UI to Supabase `public.profiles`; account reset, support and deletion flows; save/edit/reopen profile.
3. **Backend transition:** staged migration from Prisma to Supabase with checksums and rollback; Edge Function resolver behind a feature flag; provider eligibility tested.
4. **Catalog UI:** real Home, Browse, Library and Search content, no radio; artist/album/playlists; mini-player persists.
5. **Playback:** ten-track queue, focus/interruptions/reconnect, compatible licensed downloads and airplane-mode playback.
6. **Audio DSP:** chosen single DSP integration, ten-minute glitch-free stress test on low-end Android; no advertising of unsupported formats.
7. **Video:** bounded `media_kit` player pool, 20-item scroll, OS decoder and memory test.
8. **AI search:** benchmark 270M on low-tier device, opt-in, local vectors, measurable search relevance and memory cap.
9. **Settings:** all eleven sections bound to Riverpod + persisted preferences; dark/light themes, accessibility.
10. **Operational readiness:** CI all platforms, staging smoke, privacy/security review, logs/metrics, rate limits, account data export/deletion, rollback.
11. **Release readiness:** device/emulator test matrix, licensing checks, support and app-store requirements; independent sign-off for each platform.

**Current status:** Profile schema live and audited. Flutter auth code and custom UI live only in draft PR #7; Google dashboard provider configured but no end-to-end auth device proof or production release; Apple awaiting membership. The advanced engine, video pool, on-device AI and Supabase Edge orchestration are **planned**, not implemented.

## 7. Non-negotiable guardrails

- No copyrighted stream extraction, bypass of Deezer entitlements, unauthorized ARL reuse, or fake offline rights.
- Never merge a Supabase Auth user onto an existing Breezze account solely by email.
- A valid Supabase JWT does not replace RLS, explicit per-owner checks or playback authorization.
- Keep Redis keys user- and rights-context-aware where necessary; provider URLs have short validity and must not be globally reissued.
- Never publish or commit Google OAuth secrets, Apple .p8 keys, Supabase service-role keys or per-user provider credentials.
- Performance claims are measured per supported device and platform; no unverified <200ms playback assertion.
- Coordinate mobile backend changes, staged rollouts, monitoring, support and rollback, then merge PR only after all required checks.
