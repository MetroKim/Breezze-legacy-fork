# Breezze — audio-first execution and acceptance contract

**Canonical repository:** [MetroKim/Breezze](https://github.com/MetroKim/Breezze)  
**Legacy repository:** [MetroKim/MetroMusic](https://github.com/MetroKim/MetroMusic)  
**Status:** staged implementation plan and verified baseline, **not** a production-release certificate.  
**Reconciled:** 2026-11-23.

This contract translates the product's ten-phase audio-first plan into actions compatible with the code that actually exists. Do not replace functioning infrastructure merely because another package was listed in an exploratory proposal.

## Repository consolidation and change control

- The Breezze main branch already includes the MetroMusic application history, including shared commit `a13d3f29d26f68527de6bd45f5c7bc2d05cf3fe3`, plus later Flutter audio/video integration. `MetroMusic/main` adds only a README redirect after that shared commit; it is **not** another active application to copy.
- All new application work targets `MetroKim/Breezze`. Keep MetroMusic read-only as a legacy reference until GitHub's repository administrator archives it; archival or deletion is **not** implied by this document.
- Old feature branches in MetroMusic may diverge and must be evaluated file-by-file; never mass-merge historical branches, duplicate native apps, or overwrite generated runners.
- Preserve `apps/mobile` as the shipping Flutter project, `backend/api` as the NestJS API, `backend/ytmusicapi` as a discovery service, and `packages/*` as the shared implementation.
- The existing draft [playback verification PR #3](https://github.com/MetroKim/Breezze/pull/3) has a green regression baseline at `391dcd296fe995c3f3499337947747485294b317`. Its code is not yet on `main`. Any later change needs CI against its **new exact commit**.

## Product contract

Four top-level destinations: **Home, Browse, Library, Search**. One application-owned queue and mini/full player shared between routes. No Radio destination, ads, subscriptions, paid tier, artist portal or paywall. Listener-facing artist, album, playlist and account pages are allowed.

### One audio engine; video is opt-in

```text
Flutter UI (Home / Browse / Library / Search / Now Playing)
   -> Riverpod PlayerController (one queue, one source of truth)
       -> backend playback authorization + source resolver
       -> just_audio adapter (ExoPlayer / AVFoundation)
       -> audio_service (system controls) + audio_session (focus/interruption)

Video action (separate, explicit UI)
   -> pause current player/entry
   -> single video_player decoder OR official in-app video embed
   -> wait for decoder route disposal
   -> resume only the same paused entry, same recording, app foreground
```

Keep the existing `just_audio`, `audio_service`, `audio_session` and `video_player` stack. The app already has a global `PlayerController`, a platform bridge and a video handoff flow. `just_audio_background` is not required alongside the custom `audio_service` handler. A generic media-kit video pool is not a prerequisite for one opt-in video surface. Desktop audio plugins do not imply a second independent global player.

**Audio handoff invariants:** do not reopen a video's decoder while an unrelated track was selected during the asynchronous pause; do not auto-resume a replaced queue entry, a different recording, a user-paused player or a backgrounded app. These behaviors are covered by `video_handoff_policy_test.dart` and by emulator runtime integration tests for the baseline flow.

## Playback sources: rights boundary, not just network reachability

| Source | Discovery | Native full recording | Preview | Offline |
|---|---|---|---|---|
| YouTube Music metadata via `ytmusicapi` | Best effort | No grant from metadata alone | Only separately authorized source | No |
| Deezer public API | Metadata | No automatic full-catalog entitlement; backend may use a separately documented authorized recording | Provider-issued short preview, labelled as such | No preview download |
| Audius official API | Public/eligible tracks | Eligible public, ungated API-accessible recordings only | Where permitted | Only if separately authorized |
| Breezze-owned or explicitly licensed master | Yes | Rights + territory + expiring stream grant required | If allowed | Signed download + bounded offline lease |
| User-chosen local file | Local | Yes | N/A | Already local |

An ARL cookie, YouTube watch URL, extraction tool or third-party preview is **not** proof of a full-stream/download licence. Do not implement cookie-based access-control circumvention or silently substitute a different master. Failover must verify the *same recording*, territory, allowed action, session and expiry. Prefer ISRC plus edition/artist/duration verification; ambiguous candidates produce an unavailable state.

## Ten implementation phases with real acceptance gates

### 1. Foundation and canonical repo — largely in place

- [x] Central Flutter monorepo, shared packages, NestJS API, generated platform targets and cross-platform CI.
- [x] One canonical Breezze repository with the previous project history.
- [ ] Administratively archive old MetroMusic after checking all active integrations/remotes; keep redirect and history.
- [ ] Audit app store metadata, app icon, splash, package identifiers and hosted deployment references for remaining MetroMusic names.

### 2. Brand and adaptive theme — partial

- [x] Shared design-system tokens and Breezze-specific branded UI foundations exist.
- [x] Wire the bundled launcher icon to palette extraction and use the contrast-checked seeded accent; preserve monochrome for achromatic artwork. Added adaptive theme unit coverage.
- [ ] Audit high-contrast/reduced-motion themes and asset variants on physical supported devices; per-album accent remains separate from the global launcher palette.
- [ ] Test dark/light/system/high-contrast themes, dynamic type, accessible focus and reduced motion on supported platforms.

### 3. Listener shell — partial

- [x] Four-destination Flutter navigation and shared player foundation.
- [ ] Review every screen in device-width and desktop layouts: Home, Browse, Library, Search, mini-player, Now Playing, queue, album/artist/playlist pages. Verify pressed/hero/blur behavior and empty/error/offline states.
- [ ] Confirm a single player survives route changes, sign-out, account switching and lifecycle events.

### 4. Backend and provider integration — partial

- [x] NestJS, Prisma/PostgreSQL, caching foundations, authenticated session resolution, metadata providers and permission checks exist.
- [ ] Map each visible catalog CTA to a tested backend route. Preserve provider attribution and distinguish metadata-only, full-stream and preview outcomes.
- [ ] Add provider budget, timeout, outage, source-identity and rights-denial tests. Validate production configuration separately from local mocks.
- [ ] Use independently authorized licensed sources instead of assuming a Deezer ARL can supply every full recording.

### 5. Playback and offline — emulator baseline verified

- [x] Android and iOS emulators verified local download, offline audio decode, pause/seek/resume, video handoff and native Deezer **preview** decode at PR #3 head; Android also exercised OS media pause/play.
- [x] Test backend with disposable licensed fixture: byte-range full stream, session controls, download grant, lease revalidation and revocation.
- [x] Implement local-only native gapless playlists (Android/iOS/macOS) with one just_audio decoder, native index updates and safe queue-edit fallback; unit and simulator tests added, **new-commit CI pending**.
- [ ] Measure actual audible silence at two adjacent local-track boundaries and validate long playlist/battery behavior on real devices.
- [ ] For full remote tracks, implement queue grants with individually validated licensing/session lifecycle before enabling native gapless; keep current per-track backend resolution until proven safe.
- [ ] Verify skip/repeat/shuffle transitions, failed source retry, network changes and grant-expiry recovery.
- [ ] Test physical lock-screen, headset/Bluetooth, phone call, and audio-focus behavior. Emulators cannot certify these.
- [ ] Do not claim gapless merely because `just_audio` has playlist APIs; time the end-to-start output gap with independently granted sources.

### 6. Optional native DSP — not enabled

- [ ] Benchmark output EQ/crossfade/spatial needs before installing native FFI libraries.
- [ ] Pick one native PCM/output owner and a well-defined integration path. A second FFI player cannot simply be attached to `just_audio` output; uncoordinated engines cause double playback.
- [ ] Real-time callback contract: no allocation, locks, I/O or Dart VM entry. Measure latency, CPU, battery and ten minutes of glitch-free audio on low-end physical Android.

### 7. Cache and offline hierarchy — partial

- [x] Local downloads with rights/owner metadata and backend lease checks have automated coverage.
- [x] Fail closed on invalid, expired or preview-only download grants; require HTTPS and a bounded offline lease, and reject downloads after account switches.
- [x] Prevent cache corruption by resuming partial bytes only with a matching server-issued encoded-asset version; invalidate completed bytes on version mismatch. Without a stable version, restart the transfer safely.
- [ ] Add **authorized** metadata/source prefetch for up to three queue entries; key by listener, territory, recording edition, quality and rights expiry. Implement an asset-version response from the licensed backend media catalog so versioned byte-range resumption can be used reliably in production.
- [ ] Never persist unauthorized provider audio or share signed user-specific URLs in edge caches. Validate range resumption, evictions, corrupted assets, revocations, airplane-mode behavior and account isolation.
- [ ] Do not claim arbitrary streamed audio is offline-playable after half its bytes arrive: codec/container boundaries, explicit caching rights and verified chunk indexes are prerequisites.

### 8. Optional video — single native controller in place

- [x] `video_player` supports an explicit local MP4 video surface; the official embedded player handles compatible provider videos separately.
- [ ] Keep at most one active native video decoder for the current app. Add a bounded LRU pool **only if** a multi-video feed becomes an approved product requirement and hardware profiling justifies it.
- [ ] Test 20-video scroll and decoder budgets on budget hardware only if a feed is actually shipped.

### 9. Audio/video coordination — guarded regression work

- [x] Audio pauses for video and resumes after the video route completes and releases its decoder; Android/iOS emulator smoke tests pass on baseline.
- [x] Add race guard for a new audio selection while handoff pause is pending, with unit coverage for queue/recording/lifecycle mismatch.
- [ ] Add 50-switch stress test with memory/decoder/focus instrumentation; include app background/foreground, video error, OS interruption and explicit user pause cases.
- [ ] Never transfer timestamps between different recordings or mismatched video edits without a verified timeline mapping.

### 10. Lyrics, operations and release — partial

- [x] Lyrics route and seeking foundations exist in the app.
- [ ] Choose a tested parser for ordinary/timed/word-synced lyrics; only claim word-level highlighting when licensed provider timestamps are available.
- [ ] Add accessibility, localization, reduced motion, privacy-safe telemetry, crash monitoring, deployment smoke tests and reproducible backup/restore.
- [ ] Release only after real-device testing, source rights approval, deployment checks and signing. CI green does not imply production readiness.

## Baseline evidence and repeatable checks

The prior baseline on PR #3 passed:
- [CI run 45144191636](https://github.com/MetroKim/Breezze/actions/runs/45144191636): Flutter tests/analyzer, NestJS/Prisma/Postgres tests, Cloudflare Worker checks, Android/iOS/Linux/macOS/Windows/Web builds.
- [Listener runtime 45144191610](https://github.com/MetroKim/Breezze/actions/runs/45144191610): Android emulator, iPhone simulator and local Postgres/R2 licensed-media fixture.
- [CodeQL 45144191623](https://github.com/MetroKim/Breezze/actions/runs/45144191623): JS/TS, Actions, Python, Java/Kotlin.

Each new commit should run `flutter analyze`, Flutter app/package tests, backend tests and applicable platform builds in GitHub Actions; run native decoder tests on Android/iOS simulators for handoff changes. Report failing, skipped and pending jobs explicitly. This document records an **execution plan**, not ten completed phases.
