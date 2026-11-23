# Breezze Product Experience Plan

> **Current release scope:** The audio-first execution plan supersedes older
> aspirational sections below. The live client has **four** destinations:
> **Home, Browse, Library, Search**. Radio, an artist portal, billing,
> subscriptions and social features are not release requirements.
> Catalog metadata is not a music license. See
> [the verification register](audit/RELEASE_EXECUTION_STATUS.md) for
> independently verified functionality and outstanding blockers.

This specification applies the supplied music-app feature inventory to Breezze's independent product identity and the existing Flutter-first architecture. It describes target behavior; a listed capability is not considered shipped until its real data source, persistence, permissions, and tests exist.

## Product principles

- Breezze has its own monochrome visual identity. Use the existing design-system tokens, brand SVGs, glass/Atmosphere components, and restrained motion. Do not copy Apple's assets, labels, proprietary APIs, or trade dress.
- Music content leads the hierarchy: artwork, track/artist metadata, duration, availability, and playback actions.
- The global Riverpod PlayerController remains the only playback authority. Navigation must not recreate or reset playback.
- Use real provider/catalog results. Never fabricate tracks, radio stations, listening history, charts, or recommendations.
- Keep Breezze free. Do not introduce subscriptions, billing, paywalls, or premium-only controls.
- Keep the consumer journey inside Breezze: search, detail pages, playback, video viewing, library, playlists, account and support must use Breezze-owned screens and controls. Providers may supply authorized data or media behind the scenes, but core flows must not hand users to an external app or browser. Do not extract or re-host media without authorization.
- Provide loading, empty, offline, error, and populated states. A blank screen is not an acceptable failure state.

## Information architecture

| Area | Target capabilities |
|---|---|
| Home / Listen Now | Recently Played, Favorites, Made For You, New Releases, Replay, stations, editorial rails |
| Search | Songs, artists, albums, playlists, videos, stations; recent searches; clear and remove history |
| Library | Favorites, playlists, artists, albums, songs, genres, compilations, downloads |
| Browse | New releases, charts, genres, moods, music videos, concerts, editorial collections |
| Radio | Featured stations, station directory, live status, show schedules, on-demand episodes |
| Player | Mini-player, Now Playing, queue, lyrics, shuffle/repeat, seek, audio output, volume |
| Artist/album/playlist detail | Artwork hero, metadata, primary play actions, track lists, related content, contextual actions |
| Settings | Audio quality, playback preferences, downloads, account, privacy, accessibility |

## Screen behavior

### Home / Listen Now
- Personal rails are sourced from persisted listening history, favorites, and backend recommendations.
- First-run state directs users to Search/Browse. Hide empty rails rather than showing invented cards.
- Each rail card opens its entity; play starts a queue with the correct origin/context.

### Search
- Search connected catalog sources and display real track metadata/artwork. Open results in Breezze-owned detail routes; provider links are provenance, not the primary navigation action.
- Keep recent searches on-device, newest first, deduplicated case-insensitively, capped at ten, individually removable, and clearable.
- Handle overlapping requests safely: stale responses must not replace newer results.
- Distinguish no-results from provider/network failures.
- Catalog integration must support typed album, artist, playlist, video, and station result groups. Video results open a Breezze-owned video detail/player route; if no authorized in-app video source exists, show a clear unavailable state rather than an external-player handoff.

### Library
- Favorites and downloads remain distinct. Favorites are saved catalog references; downloads are local media files with provider/rights constraints.
- Show real saved items from local storage and sync when authenticated.
- Playlist ownership and membership are enforced by the backend; a user must never read or mutate another user's library.

### Browse and Radio
- Only show editorial rails, charts, concerts, or radio streams when a verified provider/backend returns them.
- Live badges require a real live-state signal. Schedule times must include a timezone.
- Station and collection detail routes need real descriptions, artwork, playback state, and save/share actions. Station playback must use an authorized source rendered by Breezze's global player; schedules alone never imply playability.

### Player
- Mini-player displays current track artwork/title/artist and playback progress, and opens the full Now Playing screen.
- Now Playing exposes transport, seek, shuffle/repeat, queue, lyrics, output route, and volume only where the engine supports them. No core playback action may launch a provider app or browser.
- Queue operations use the global PlayerController/QueueManager.
- Lyrics are shown only when a licensed/authorized lyrics provider returns a matching track.

## Visual system and reusable components

- Source colors, type, spacing, radii, and motion from the existing design system.
- Use original Breezze SVG marks and iconography; no emoji icons.
- Use square, consistently cropped artwork with semantic fallback states.
- Use glass/blur only for floating controls, mini-player, and overlays; keep content surfaces readable.
- Keep tap targets at least 48 logical pixels, provide semantic labels, and respect reduced-motion settings.
- Reusable component targets: artwork, track row, entity card, content rail, section header, empty/error state, contextual menu, mini-player, playback controls, quality badge.

## Data and integration contracts

- Canonical catalog IDs are Breezze-owned. Provider IDs are mapped to canonical IDs and never used as database primary keys.
- User data (favorites, playlists, listening history, downloads, search preferences) is scoped by authenticated user on the server; local-only search history stays on-device.
- Backend modules already present include Catalog, Rights, Playback, Library, Search, Playlists, Downloads, Home, Lyrics, Radio, Recommendations, Replay, Social, Classical, Providers, Notifications, Moderation, Artist Portal, Distributor, and Media.
- Client repositories/adapters should isolate transport and provider behavior from widgets. Do not put credentials or signing secrets in the app.
- Every provider result must preserve source attribution and rights/territory restrictions.

## Delivery phases

1. **Product shell and navigation:** stable destinations, persistent state, responsive navigation, mini-player and Now Playing.
2. **Catalog discovery:** search history, search result groups, entity detail pages, catalog metadata/artwork, charts and editorial feeds.
3. **Personal library:** favorites, playlists, downloads, offline state, authenticated sync and conflict handling.
4. **Listening depth:** queue editing, lyrics, radio schedules, Replay, recommendations, output routing and playback preferences.
5. **Platform polish:** desktop/tablet layouts, accessibility, deep links, localization, performance and analytics/privacy controls.

## Acceptance criteria

- Every visible enabled control performs a real action; unsupported capabilities are disabled or clearly unavailable.
- Search history survives app restarts, is capped at ten, and supports deduplication/removal/clear.
- A slow older search cannot overwrite a newer search.
- No fabricated content is presented as real.
- All user-owned server records are protected by authenticated user scoping and ownership checks.
- Playback survives tab navigation and is controlled by one global PlayerController.
- UI states cover loading, empty, offline, provider error, and populated results.
- Product feature status is updated only with implementation and test evidence.

---

## Appendix A — Frontend Architecture & Content Blueprint (Flutter binding)

The frontend architecture contract for this plan. Every section maps to a
design token and (where applicable) a backend API so product, design, and
engineering work from one source of truth. Where the original blueprint
names a web stack (Next.js, TanStack Query, Zustand), the equivalent
Flutter mechanism is noted.

### A.1 Architectural principles

| # | Principle | Consequence |
|---|---|---|
| 1 | Content is the interface; chrome floats above it | Glass material reserved for nav, overlays, and floating controls only. Never on content cards. |
| 2 | Playback state is the single source of truth | The global PlayerController owns audio; every screen reads from it, none writes directly. |
| 3 | Optimistic UI for every user mutation | Save, follow, reorder, add-to-playlist reflect instantly, then reconcile. |
| 4 | Offline-first | Downloaded tracks, artwork, and metadata render with zero network. |
| 5 | 60 fps or it ships broken | Glass blur, scroll rails, spring animations must hold 60 fps on mid-tier devices. |

### A.2 Tech stack mapping

| Blueprint layer | This repo |
|---|---|
| Server state (TanStack Query) | Riverpod providers + repositories (`core/api`, `packages/api_client`) |
| Client state (Zustand) | Riverpod state (player: `player_controller.dart`) |
| Design tokens as JSON → CSS vars | `packages/design_system/lib/src/tokens.dart` → `BzThemeColors` extension |
| Framer Motion springs | Flutter springs + `Cubic(0.22, 1, 0.36, 1)`; reduced-motion respected |
| Web Audio / AVPlayer / ExoPlayer | JustAudio adapter + audio_service background bridge (`core/audio`) |
| Service Worker + IndexedDB | Drift database + downloads controller (`core/database`) |
| TanStack Virtual | `ListView.builder` / `SliverGrid`; horizontal `ListView.separated` rails |

### A.3 App shell & navigation contract

The player surface is never unmounted on navigation: the shell uses an
`IndexedStack` so screens swap while the player pill and audio engine
persist; Now Playing is a full-screen dialog pushed above the shell, so
audio never stops on navigation.

Responsive: ≥1200px full 260px glass sidebar + floating centered player
pill (bottom: 20); 810–1199px icon rail; <810px bottom tab bar (glass
capsule) with docked player, 16px margins. Tokens: `BzBreakpoints.medium
= 810`, `expanded = 1200`.

### A.4 Screen content order

- **Home**: greeting → shortcut tiles (max 6) → shelves (Made for You,
  Recently Played, New Releases, Jump Back In, Recommended). Skeletons at
  opacity 0.6, no spinner.
- **Search**: idle = search pill (PRT-01) → browse grid → recent searches;
  active = autocomplete (250 ms debounce, cancel in-flight) → top result →
  songs → artists → albums → playlists.
- **Library**: capsule filter tabs → sort control → virtualized list.
  Context menu: Play, Add to Queue, Download, Remove.
- **Playlist detail**: hero header → action row → virtualized track list →
  recommended additions. Optimistic reorder with versioned reconciliation.
- **Album detail**: hero header → action row → track list in album order
  (gapless) → "More by this artist" rail.
- **Artist profile**: hero → top 5 tracks → albums rail → singles/EPs →
  "Fans also like".
- **Now Playing**: artwork-derived ambient background; chrome recedes to
  0.15 after 3 s idle, restores on input; centered breathing artwork;
  scrubber; transport (56–64pt play, 44pt hit minimum); word-synced
  depth-of-field lyrics + queue toggles. Audio never interrupts on collapse.
- **Queue panel**: Now Playing → Next Up (drag-reorderable) → Next from
  context. Glass sheet.
- **Downloads**: storage bar → quality selector → downloaded lists →
  "Downloaded only" toggle.

### A.5 Component contracts

| Component | Behavior |
|---|---|
| Rail (`_Rail`) | Horizontal scroll; pressed-scale artwork cards |
| Artwork card | Pressed scale 0.96 spring; lazy image; error fallback |
| Track row | Active row highlighted; ⋯ menu via popup |
| Mini player pill | Reads `playerControllerProvider`; glass capsule, blur 24 |
| Tab bar | Glass capsule, blur 16 |
| Search pill | Capsule field, accent focus ring (PRT-01) |
| Selection pills (Library/Browse/Search) | Capsule, solid text1 fill active |
| Glass container | PRT-09 material contract; solid fallback on high contrast |

### A.6 State management

Strict separation — never copy server data into client state:

| Concern | Owner |
|---|---|
| Catalog, playlists, library, search, feed | Repositories + Riverpod providers |
| Playback (position, queue, volume, repeat/shuffle) | `playerControllerProvider` state machine |
| UI (panels, theme) | Local widget state / simple providers |
| Downloads, offline cache | Drift + downloads controller |
| Auth/session | `authSessionProvider` + secure storage |

**Playback state machine:** `idle | buffering | playing | paused | seeking |
ended | error` (`packages/audio_contracts`). Only the audio engine
dispatches transitions; UI calls store actions (`playTrack`,
`togglePlayPause`, `next`, `previous`, `seekTo`, `playNext`, `playLast`).
Exactly one current track at any time.

### A.7 Data layer

Cache policy: home feed 5 min (refetch on focus, throttled) · search 2 min
(new query only) · playlist/album 1 min (mutation invalidation) · library
30 s (optimistic + invalidate) · recommendations 15 min (weekly
regeneration) · user profile 5 min (on focus).

Optimistic mutations on every write: instant local reflection, reconcile on
settle, roll back on error; generation counters guard stale async
responses (`_searchGeneration`, `_lyricsRequestGeneration`, `_requestId`).

Delta sync on resume: local sync token → changed rows only → merge
(additions union, reorder LWW) → persist token; stale token (>30 days)
triggers full sync with progress (`core/database/outbox_sync_service.dart`).

### A.8 Audio engine contract

Gapless (pre-buffer next track) · prefetch next stream URL during playback
(cache 5 min) · quality switch server-side at track start only ·
background playback via audio_service Media Session with lock-screen
controls · errors: CDN 403 → re-request once; network drop → pause +
exponential backoff (1s/2s/4s/8s); decode error → skip + analytics;
offline undownloaded → "Not available offline" toast.

### A.9 Offline & downloads

Encrypted file cache in app sandbox; LRU eviction at 90% quota; pinned
items never evicted. **Constraint:** "Downloaded only" mode renders the
full library, player, and queue with zero network calls.

### A.10 Performance budgets

| Metric | Budget |
|---|---|
| Glass blur | ≤ 2 blurred surfaces per viewport region (PRT-09; CI fails on violations) |
| Scroll FPS | 60 on artwork rails |
| Player pill appear | < 100 ms after tap |
| Long lists | Virtualized |

### A.11 Accessibility

Semantics labels on every interactive control; tooltips on all icon
buttons; accent focus ring never removed; `MediaQuery.disableAnimationsOf`
disables springs, keeps fades; AA contrast on text over glass; 44×44 pt
minimum targets; layout usable at 300% text.

### A.12 Motion system

| Interaction | Curve | Duration |
|---|---|---|
| Pill → full-screen | Spring | physics |
| Card press | Spring scale 0.96 | 160 ms |
| Top bar scroll adapt | background-color + opacity only | 200 ms |
| Sheet | easeInOut slide | 240–320 ms |
| Skeleton shimmer | easeInOut loop | 1.25 s |

Never animate size, radius, or padding on a blurred surface during
scroll — it forces a re-blur every frame.

### A.13 Non-negotiable frontend constraints

1. The player is never unmounted on navigation.
2. One source of truth for playback.
3. Glass blur ≤ 2 surfaces per viewport region.
4. Every write is optimistic.
5. Offline is a first-class mode, not a fallback.
6. Animate only opacity/background on scroll-adaptive glass bars.
7. Accent color is reserved for action and state — never a background wash.

### A.14 Build roadmap

- F0 Shell + tokens — done
- F1 Player engine + pill + Now Playing — done
- F2 Home feed + shelves + skeletons — done
- F3 Search idle/active — done (autocomplete = backend follow-up)
- F4 Album/Playlist/Artist detail — done
- F5 Library + optimistic saves + delta sync — done
- F6 Queue + Media Session — done
- F7 Downloads + offline mode — done
- F8 Perf hardening (virtualization, blur budget) — continuous
