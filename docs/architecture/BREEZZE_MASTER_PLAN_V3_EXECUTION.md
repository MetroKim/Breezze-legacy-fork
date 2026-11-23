# BREEZZE MASTER PLAN v3 — execution contract

**Status:** Adopted target architecture. This document complements the original v3 specification without claiming unimplemented work is complete. Preserve Breezze's premium, restrained Apple Music-inspired visual system, black/white brand mark, accessible SVG icons, and exactly four tabs: **Home, Browse, Library, Search**. Global mini-player and Now Playing remain shared. No radio, social graph, ads, subscriptions or billing screens. Android/iOS primary, with Windows/macOS/Linux/web targets evaluated by CI.

## 1. Architecture and migration boundaries

Target:

```text
Breezze Flutter (Supabase-authenticated)
  ├─ Supabase Auth (Google first, Apple once Developer Program active, email/password)
  ├─ Supabase Postgres with per-user RLS: profiles and owned library data
  ├─ Supabase Edge Functions: short-lived gateway/orchestration, auth, prefetch
  └─ Proven media services: metadata/discovery, authorized stream resolution, lyrics
       ├─ YouTube Music metadata/discovery (unofficial ytmusicapi adapter)
       ├─ rights-compliant Deezer / SoundCloud playback adapter when permitted
       └─ LRCLIB with attribution
```

**Migration rule:** Current NestJS + Prisma/Cloudflare services remain operational until parity tests and a reversible cutover demonstrate that each Supabase successor works. Do not destroy Prisma-owned favorites, playlist records or catalog during the migration. No dual writes without idempotency, conflict resolution, per-user tenancy tests and a defined owner of each entity. Provider metadata is not a license to stream, download, or cache copyrighted audio; ARL tokens likewise do not grant universal playback rights.

Domain ownership:
- **Identity:** Supabase Auth is the sole identity/session authority; do not resurrect legacy NestJS JWT issuing or Auth0.
- **User profile:** `public.profiles` (Supabase, user ID = `auth.users.id`), owned by user RLS; profile updates should eventually write directly to Supabase instead of NestJS. During transition, preserve any NestJS onboarding and territory rules.
- **Personal library:** `public.user_library` and `public.pinned_playlists` are created as *additive migration targets*; legacy Prisma library/playlists remain live until synchronized and tested. Canonical IDs must map unambiguously across both databases.
- **Catalog and rights:** existing metadata/canonical IDs and territory/rights records remain in current backend until provider resolution is replaced.
- **Provider credentials:** **never** store third-party provider credentials in user-selectable `public.connected_providers` rows. Use server-only secret storage for service-level keys, or a private schema/service-controlled vault for explicitly authorized per-user secrets. Do not expose credentials to RLS-filtered client reads.
- **Cache:** hot TTL cache (Redis/Upstash as supported), source-specific TTL, invalidation and provider rate limits. Keep audio bytes off Supabase functions.
- **Observability:** structured latency, auth failure, playback-rights and resolution errors without logging tokens, private user data or stream URLs.

## 2. Auth UX and lifecycle

The custom Breezze Flutter authentication screen stays native to the app, with direct `supabase_flutter` calls; no branded hosted authentication screen. Native Google/Apple *provider authorization sheets* are still OS-owned. Keep the existing sign-in/register styling and accessible focus states; add Forgot Password, email-reset handling, first-run avatar/personal details and account deletion only when each backend path exists.

Use Supabase `onAuthStateChange` for `initialSession`, `signedIn`, `signedOut`, `tokenRefreshed`, `userUpdated`, and `userDeleted`; always provide an `onError` listener, dispose subscriptions, and clear owner-specific in-memory caches on a user switch. Let the SDK manage refresh and persistence; **never log or mirror refresh tokens to Hive/Isar**. Native Google `signInWithIdToken` uses both the Google ID token and Google access token, per Supabase's current Flutter integration guidance. `google_sign_in` 7 exposes the access token through the account's `authorizationClient` (not the old `authentication.accessToken` API); limit authorization scopes to basic identity information. Apple ID-token sign-in should use secure nonce generation and hashing; **Apple stays pending** until Developer Program membership and native entitlements can be configured.

For signed-out browsing, a local owner ID may isolate queue/favorites on a device, but is **not** an authenticated Supabase ID; offline-to-account merge requires an explicit choice, conflict handling and per-user isolation. Do not set up Supabase anonymous users merely to browse as a guest. Password-reset callbacks and OAuth redirect allowlist must be configured before release.

**Current auth status:** Supabase project `djwvyjtebmsavhcrmhxf`. Google web+iOS OAuth client IDs and web secret configured in Supabase, Google provider enabled; Android signing SHA-1/client remains outstanding; an actual end-to-end provider login still needs test. Apple Developer membership inactive and Apple native login is blocked. The supabase Flutter code lives in draft PR #7; the deployed API/client has **not** been switched to the PR.

## 3. Supabase RLS foundation

Existing: `public.profiles`, `id uuid` FK to `auth.users(id)` and owner-only `TO authenticated` SELECT/INSERT/UPDATE policies. Additional implemented migration: `breezze_v3_user_library_and_pins_rls` creates:

- `public.user_library(id, user_id, track_id, added_at)` with FK, uniqueness on `(user_id, track_id)`, owner+timestamp index and owner-scoped SELECT/INSERT/UPDATE/DELETE.
- `public.pinned_playlists(id, user_id, playlist_id, position)` with FK, uniqueness on `(user_id, playlist_id)`, owner+position index and owner-scoped SELECT/INSERT/UPDATE/DELETE.

Every policy checks `(select auth.uid()) = user_id` (or `id`) and excludes `auth.jwt()->>'is_anonymous' = 'true'`. INSERT uses `WITH CHECK`; UPDATE uses both `USING` and `WITH CHECK`. RLS is enabled, public/anon table grants revoked, and access is limited to authenticated. Supabase Security Advisor reported **zero security lints** after schema creation; the initial RLS JWT initplan performance warnings were resolved by migration `breezze_v3_owner_rls_jwt_initplan` (only expected unused-index informational notices remain while tables are empty). **Not yet verified:** authenticated two-user CRUD negative tests with real sessions, frontend CRUD wiring, guest-to-user data migration, or exposed Data API configuration.

Keep RLS verification in CI: one real user can read/write only own rows; unauthenticated users see none; user A cannot select/insert/update/delete user B's rows; ownership fields cannot be reassigned. Include actual PostgREST tests or pgTAP tests when available. Database isolation never substitutes for checking authorization in provider resolver endpoints.

## 4. Backend / Edge Functions

Incrementally implement only low-latency, authorized orchestration as Supabase Edge Functions (Deno/TypeScript):
- `POST /resolve`: Supabase caller identity, territory, catalogue source match, provider capabilities and rights grant, rate limiting, caching. A non-playable metadata hit must never be reported as a playable stream.
- `POST /prefetch`: bounded list of next track IDs (max 3), identity/territory checks, no uncontrolled fan-out.
- catalogue discovery aggregation and lyrics proxy as independent functions if benchmarks justify.
- audit logs without bearer tokens or ARL secrets.

Do not execute blocking Python ytmusicapi, native codecs, DSP or large media conversion *inside* Edge Functions; delegate to bounded services and respect Supabase hosted CPU/memory/wall-clock limits. `EdgeRuntime.waitUntil` is only for bounded background work, not guaranteed durable jobs; use queues/jobs with retries, idempotency and dead-letter handling for exports/recommendation batches. Cron is for safe metadata/cache maintenance, never automatic secret/session deletion without understanding the auth platform. Preserve existing Cloudflare and Railway deployments until new endpoint contracts are validated.

## 5. Media and offline contract

Baseline: `just_audio + audio_service + audio_session`, one consistent queue, lock-screen/Bluetooth controls, global Now Playing; physical/emulated device tests for interruption/recovery. Playback rights must be checked server-side per track, action and territory. Downloads must be disabled where licenses do not grant offline rights; never bypass provider DRM. Do not promise high-resolution/lossless when the source, hardware or output path cannot support it.

Advanced DSP is **opt-in experimental**: benchmark `flutter_soloud` for custom realtime native filters or `sautiflow` for integrated high-fidelity crossfade/EQ. These engines overlap with `just_audio`; define exactly one playback owner rather than double-rendering audio. Native audio-thread code must be deterministic and nonblocking, avoid locks, allocation, I/O and Dart VM calls; communication uses bounded lock-free queues. Test low-end device CPU, thermal load, glitches, battery, and background audio before promotion.

Video: validate `media_kit` using a bounded lazy player pool and LRU disposal; **3–5 is a benchmark target, not a proven universally safe decoder count**. Limits vary by hardware/codec. Scroll-test 20 videos with memory/decoder telemetry and foreground/background transitions.

Lyrics: use attribution, licensing constraints and synced/unsynced fallbacks; avoid presenting a missing lyric as a failed playback.

## 6. On-device semantic search

Google's EmbeddingGemma 2 model is real: modular 270M text-only, 440M text+vision, 570M text+audio, 740M full multimodal, up to 768-dimensional embeddings. Treat integration via `flutter_edge_ai` or `semantic_search_codespark` as **unproven until an executable compatibility POC** on Flutter Android/iOS. No remote AI keys required for an offline implementation, but model weights, distribution rights, startup/RAM costs and device storage are real constraints. Use text-only semantic library search first, with deterministic keyword fallback and opt-in model download; later test locally available audio embeddings if legal and technically feasible. Benchmark cold start, battery, memory, retrieval quality and airplane mode. Never block basic library search waiting for a 740M model.

## 7. UX and data contracts

Keep the four-tab shell, shared mini-player, player hero transitions, app-wide on-brand color tokens and restrained motion; no duplicate Settings/Account pages or artificial authentication walls. Profile settings keep language, territory, genres and saved artists; one source of truth and a clear migration plan for existing user preferences are required. Every profile mutation must be validated, owner-isolated and retriable; display honest loading/empty/offline states.

The 11 Settings sections should be connected to Riverpod persistence, with switches reflecting actual enabled capabilities—not decorative controls. Guest access is allowed for browsing/searching without claiming cloud synchronization. Existing designs are retained rather than replaced with an unrelated UI kit.

## 8. Rollout / quality gates

1. **Foundation:** Repo name Breezze, platform scaffolding and design-token audits; verify current main builds.
2. **Supabase auth:** Google web and iOS config done; Android signing credentials, first real login, email reset, Apple activation pending, account/identity linking & secure deletion pending.
3. **RLS:** Profiles plus library and pins table skeletons exist. Verify two-user isolation; wire account/profile first, then migrate saved library records with idempotent reconciliation.
4. **Catalog & resolver:** introduce one authenticated Edge Function at a time; benchmark parity, handle provider rate limits and unauthorized/region-blocked tracks; never switch playback until granted streams are verified.
5. **Player/video:** retain `just_audio` reliability; add measured video pool and DSP behind feature flags.
6. **On-device AI:** text-first POC, benchmark, quality gate; keep basic keyword search functioning on unsupported devices.
7. **Polish/release:** accessibility tests, offline tests, device lock screen/Bluetooth/interruption, deep links, deletion, account isolation, legal/rights audit and signed release builds.

**Do not merge the authentication PR or switch production routing while credentials, data ownership, and smoke tests are incomplete.** Each cutover needs rollback, observable metrics, and tests. The goal is a real working listener-first app, not an architecture diagram that implies features exist.

## Verification and references

- Supabase RLS: https://supabase.com/docs/guides/database/postgres/row-level-security
- Supabase security/API grants: https://supabase.com/docs/guides/api/securing-your-api
- Supabase Google sign-in: https://supabase.com/docs/guides/auth/social-sign-in/auth-google
- Supabase Apple sign-in: https://supabase.com/docs/guides/auth/social-sign-in/auth-apple
- Edge Function limits: https://supabase.com/docs/guides/functions/limits
- Edge background tasks: https://supabase.com/docs/guides/functions/background-tasks
- EmbeddingGemma 2: https://ai.google.dev/gemma/docs/embeddinggemma
- Flutter SoLoud: https://pub.dev/packages/flutter_soloud
- Sautiflow: https://pub.dev/packages/sautiflow
