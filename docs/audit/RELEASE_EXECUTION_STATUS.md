# Breezze — Fullstack Release Execution Status

This is the **current evidence-based acceptance board**, replacing assumptions
from older plans and archived MetroMusic documentation.

## Source of truth

- Canonical product repository: `MetroKim/Breezze`, not `MetroKim/MetroMusic`.
- Current release: free, listener-first, **audio-first**, with Home, Browse,
  Library and Search as the four destinations; settings and Now Playing are
  secondary destinations.
- One `PlayerController` and shared queue. No second catalog player per tab.
- Radio, artist portal, subscriptions, paywalls, billing, and social features
  are explicitly deferred; related legacy modules do not imply shipping UI.
- YouTube Music metadata is not a playback entitlement. Deezer API previews
  are limited previews, not full commercial-catalog grants. Only user-owned
  local media or rights-authorized provider/catalog assets may play or download.

## Verified in source and automated checks

| Workstream | Evidence | Release status |
| --- | --- | --- |
| Flutter application structure | `apps/mobile/pubspec.yaml`, `lib/`, Linux runner, `run.sh` | Present; end-to-end UI journeys still need testing |
| Four-tab UI and global mini-player | `apps/mobile/lib/widgets/bz_shell.dart` | Implemented; device accessibility audit remains |
| Search, Browse and Library | Feature screens + backend catalog adapters | Implemented for supported sources; provider/data completeness not certified |
| Accessible filters and player seek | `bz_filter_pill.dart`, `bz_playback_scrubber.dart` and widget tests | Changed; acceptance requires green CI at exact commit |
| Authentication/account isolation | Auth guards, scoped local data tests, backend integration specs | Automated foundations present; cross-tenant release audit incomplete |
| Shared playback & OS focus | PlayerController, engine adapter, background audio bridge | Automated tests; device/route and lock-screen hardware gates open |
| Authenticated backend | `backend/api` NestJS + Prisma, unit/integration tests | CI testable; live production environment not certified |
| Storage and CDN signing | `infra/cloudflare` workers and licensed-media fixture | CI testable; external licensing/deployment required |
| Offline download lease/version rules | PR #4, `feat/audio-first-video-handoff` | Draft; must merge and pass tests before declaring shipped |
| Linux/Android/Web/Windows/macOS/iOS | `.github/workflows/breezze-quality.yml` | Compilation jobs exist; physical-device acceptance open |
| Browser launch | `.github/workflows/web-preview-smoke.yml` | HTTP server/bootstrap smoke passed; full interactive browser coverage open |

## Audit results and active remediation

1. Mainline playback UI: tapping the mini-player progress strip previously
   updated only a transient drag state without seeking. The shared scrubber
   now commits taps and drags and exposes screen-reader increment/decrement
   actions.
2. Filter controls: Browse, Library and Search each duplicated a 36dp
   gesture-only pill. They now share `BzFilterPill` with a minimum 48dp
   touch target, keyboard interaction via `InkWell`, proper selection
   semantics, and reduced-motion behavior.
3. Tab long-press navigation: selection previously used the entire screen's
   width and hardcoded horizontal offsets. It now computes the hit location
   in the actual tab-bar render box.
4. Search: provider failures now expose a visible in-app retry action;
   empty results show a clear-search recovery action.
5. PR #4 API client failure: unnecessary Dart null assertion in
   `packages/api_client/lib/src/downloads_library.dart` corrected.
6. Android CodeQL build failure: Maven Central returned HTTP 429 while
   downloading a Kotlin Gradle plugin. This was an infrastructure dependency
   error, not evidence of passing or failing security analysis. Re-run
   required before certifying the job.

## Evidence links

- Base mobile launch: [web startup test](https://github.com/MetroKim/Breezze/actions/runs/45160901451).
- Mainline UX changes: [UI patch](https://github.com/MetroKim/Breezze/commit/1f0610c303613f62d96e86aa2403f1b20e2aaab3).
- Flutter accessibility correction: [follow-up patch](https://github.com/MetroKim/Breezze/commit/fc4481fa2855bfd5037e5ae7f7084f8763e5ade3).
- Audio-first changes awaiting integration: [PR #4](https://github.com/MetroKim/Breezze/pull/4).

## Release blockers — do not silently mark complete

- **P0:** Green Flutter analyzer, unit/widget, backend, edge worker and platform
  build workflows on the same final commit; emulator playback and interruption
  journeys; recoverable auth/search/playback flows.
- **P0:** Legally approved full-track playback and offline download rights for
  each provider, territory and recording; rights enforcement in the backend.
  A free Deezer API does not grant whole-catalog streaming licenses.
- **P1:** Account-isolation E2E tests for library/favorites/playlists/downloads,
  logout/revocation, offline lease expiry, network recovery and background audio.
- **P1:** Verify loading, empty, offline, error and success states for every
  screen; screen-reader labels, dynamic type, 48dp touch targets, and
  reduced-motion behavior on supported platforms.
- **P1:** Resolve draft audio-first PR #4 and CI issues before declaring its
  gapless, video handoff, dynamic theme or download changes shipped.
- **P2:** Live production API/edge health, secrets, backups, operational alerts,
  physical-device lock-screen and Bluetooth validation, capacity testing,
  app-store signing/distribution and incident rollback.

## Interface direction

Breezze is a **restrained, premium, functional music application**—not a
futuristic mockup. Retain the existing black/white Breezze identity, original
SVG interface icons, semantic light/dark tokens, real album artwork,
readable typography, consistent 8dp spacing, native input feedback and
focused primary controls. Artwork-derived color may enrich Now Playing
subtly, but must not reduce foreground contrast or replace opaque fallbacks.
No decorative emoji, fake tracks, fabricated charts or broken CTA actions.

**Completion policy:** A screen or endpoint is not finished merely because its
widget, route, API stub or architecture file exists. Production-ready claims
require verified action, authorized backend data, explicit failure/empty
states, and automated/device evidence at the final commit.

## Current UX and rendered-browser acceptance extension

- Empty Now Playing state includes an accessible Close and Back to music
  action, instead of leaving a listener in an undismissable full-screen shell.
- The full-screen progress slider stages drag values locally and commits one
  seek when released; unavailable duration disables seeking.
- The navigation selection transition honors the OS reduce-motion preference,
  and onboarding back navigation clamps to the first step.
- The Flutter web preview workflow launches actual headless Chromium at a
  390px mobile viewport, checks for a rendered Flutter scene, records uncaught
  JavaScript exceptions, and publishes a screenshot artifact. This extends
  but does not replace manual screen-reader/physical-device verification.

## Additional runtime audit

- Home and Library now finish initial loads even when local persistence fails,
  displaying in-app retry actions instead of indefinite skeleton screens.
- Concurrent Library refreshes reject stale account/generation results, and
  switching users clears in-memory library content before asynchronous reload.
- Malformed/empty stored section preferences fall back to known valid filters.
- The API Worker handles preflight requests and adds CORS headers only for
  explicitly configured trusted browser origins. The deployed origin/Worker
  still require matching environment configuration and authorized deployment.
- Browser UI verification checks the Flutter painter inside shadow DOM, not
  only top-level canvas elements. The edge CORS failure in CI is tracked
  separately and must be tested against the deployed allowed origin.

- Added Node-based edge CORS regression coverage (exact origin, denied origin,
  unsafe method, error responses), executed in the API Worker CI job.
- The guarded API deployment workflow now passes the configured browser
  allowlist to Cloudflare and verifies the preflight on the deployed endpoint.
