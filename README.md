# Breezze

**A free, listener-first music platform built with Flutter and NestJS.**

Breezze is an independent product. It is not affiliated with or endorsed by YouTube, Google, Spotify, Apple, or another streaming service.

## Repository layout

The Flutter app in `apps/mobile`, NestJS API in `backend/api`, and Python discovery service in `backend/ytmusicapi` are the production project. The previous Kotlin client, its license and its notices are preserved in `legacy/kotlin-client/`. Run Flutter builds from `apps/mobile`.

## Product boundaries

- Four primary destinations: Home, Browse, Library and Search.
- One global player and queue shared by every screen.
- No artist portal, artist upload workflow, subscriptions, billing, memberships or paywalls in this release.
- Artist and album pages are listener-facing catalog experiences only.
- Search metadata is not a playback licence. Playback requires a backend-authorized source with applicable rights.
- YouTube Music through `ytmusicapi` is metadata/discovery only. Audius is an in-app playback source for eligible public, ungated, API-accessible tracks. Breezze owns the playback UI and queue; provider sources never require opening another app.
- Breezze does not extract YouTube audio, bypass provider access controls, or re-host third-party recordings.

## Repository layout

```
apps/mobile/               Flutter client and platform adapters
packages/design_system/    Breezze tokens, themes, components and SVG icons
packages/audio_contracts/  Playback state, queue and engine contracts
packages/api_client/       Typed Breezze API client
backend/api/               NestJS API, Prisma/PostgreSQL, Redis and BullMQ
infra/cloudflare/          API edge, WAF, rate limits and public metadata cache
docs/                      Product, design, architecture, legal and release records
```

## Quick start

### Flutter client

From the repository root:

```bash
cd apps/mobile
bash tool/generate_platform_targets.sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test --reporter expanded
flutter run --dart-define=BREEZZE_API_URL=http://localhost:3000
```

The platform generator creates the native runner folders and applies the required Android foreground-media and iOS background-audio declarations. It does not install platform SDKs, configure signing, or certify physical-device playback.

### Backend

```bash
cd backend/api
npm install
docker compose up -d
npx prisma generate
npx prisma migrate dev
npm run typecheck
npm test -- --runInBand
```

The local API defaults to `http://localhost:3000`; Swagger is exposed at `/api/docs`. For a physical phone, `localhost` is the phone itself: pass the computer's LAN API address during local development (for example, `--dart-define=BREEZZE_API_URL=http://192.168.x.x:3000`) or use the public HTTPS Cloudflare API URL. Release builds refuse API calls without a configured HTTPS `BREEZZE_API_URL`, preventing production from silently targeting localhost. Configure provider credentials only in backend environment/secrets. Never place provider secrets in Flutter or commit them.

## Audio and provider architecture

- Flutter uses one global `PlayerController` backed by the shared audio-engine adapter.
- The NestJS backend owns canonical track identity, provider selection, rights checks and playback resolution.
- Audius public ungated tracks may be resolved through its official API; gated or API-restricted tracks are rejected.
- YouTube Music metadata is never passed to the native audio engine as a playable source.
- Audio is streamed directly from an approved provider to the device by default. Cloudflare Workers and NestJS do not proxy audio segments.
- Local files remain user-controlled. Offline downloads require explicit download rights and backend authorization.

## Platform targets

The Flutter codebase targets Android, iOS, Web, Linux, macOS and Windows. Build each target on its supported host and validate the actual media-session behavior there. CI compilation is not a substitute for real-device playback, background-audio, Bluetooth-route and lock-screen testing.

## Documentation index

- [Product experience](docs/PRODUCT_EXPERIENCE.md)
- [Interface contract](docs/design/BREEZZE_INTERFACE_CONTRACT.md)
- [Integrated design and engineering architecture](docs/architecture/BREEZZE_INTEGRATED_DESIGN_ENGINEERING_ARCHITECTURE.md)
- [Audio-first execution and acceptance](docs/architecture/BREEZZE_AUDIO_FIRST_EXECUTION_AND_ACCEPTANCE.md)
- [Multi-source provider architecture](docs/architecture/BREEZZE_MULTISOURCE_PROVIDER_ARCHITECTURE.md)
- [Provider integration decision](docs/architecture/BREEZZE_PROVIDER_INTEGRATION_DECISION.md)
- [Discovery provider setup](docs/architecture/DISCOVERY_PROVIDER_SETUP.md)
- [Cloudflare and caching architecture](infra/cloudflare/README.md)
- [One-million-active-listener scaling plan](docs/architecture/BREEZZE_ONE_MILLION_SCALING_PLAN.md)
- [Security and production checklist](docs/PRODUCTION_SECURITY_AND_CACHING_CHECKLIST.md)
- [Current implementation gap register](docs/audit/gap-register.md)
- [Engineering backlog](docs/ROADMAP_AND_BUG_BACKLOG.md)
- [Third-party code and provider policy](docs/legal/BREEZZE_THIRD_PARTY_CODE_POLICY.md)

## Current verification and canonical development

The **only active application target** is [MetroKim/Breezze](https://github.com/MetroKim/Breezze). [MetroKim/MetroMusic](https://github.com/MetroKim/MetroMusic) remains a legacy history/reference repository with a README redirect; do not push new product changes there. Breezze already contains the shared MetroMusic application history.

The latest verified **draft** change set is [Breezze PR #3](https://github.com/MetroKim/Breezze/pull/3), commit `391dcd296fe995c3f3499337947747485294b317`. Its [CI](https://github.com/MetroKim/Breezze/actions/runs/45144191636), [Android/iOS listener-runtime tests](https://github.com/MetroKim/Breezze/actions/runs/45144191610), and [CodeQL checks](https://github.com/MetroKim/Breezze/actions/runs/45144191623) passed on that exact commit. This evidence does not automatically apply to new commits, production deployments, or real-device Bluetooth/lock-screen tests.

The ten-phase [audio-first acceptance contract](docs/architecture/BREEZZE_AUDIO_FIRST_EXECUTION_AND_ACCEPTANCE.md) defines the remaining implementation and release gates. Do not mark full-track catalog licensing, native DSP, true gapless playback, physical-device certification or production deployment complete based on mock fixtures or preview streams.

### Production connectivity and deployment

- The API exposes `GET /health` for origin/container health checks.
- Production container template: `backend/docker-compose.production.yml`. Copy `backend/.env.production.example` to `.env.production`, generate unique secrets, then run `docker compose --env-file .env.production -f docker-compose.production.yml up -d --build` from `backend/`.
- Deploy the NestJS origin first on a host with a public HTTPS origin (or a Cloudflare Tunnel). Then configure `BREEZZE_API_ORIGIN`, `EDGE_SHARED_SECRET`, `CLOUDFLARE_API_TOKEN`, and `CLOUDFLARE_ACCOUNT_ID` as GitHub Actions secrets and run the **Deploy Breezze API edge** workflow. Set `BREEZZE_API_PUBLIC_URL` to the public Worker/custom-domain URL for its post-deploy smoke check.
- Build release clients with `--dart-define=BREEZZE_API_URL=https://YOUR-API-HOST`; never ship a release build with a localhost URL.
- Deployment credentials and a real hosting origin are not stored in this repository. Green CI proves compilation/tests, not that a production origin is deployed or reachable.
