# Breezze — Supabase Auth only

## Authentication decision

Supabase Auth is Breezze's sole external identity authority. Native Google and Apple sign-in are the primary buttons on the existing Flutter Breezze AuthScreen. Email/password signup, verification and recovery are secondary. No Auth0, Melody Auth, or independently managed social OAuth login remains in the active app.

Dedicated project: Breezze in Allen's Org, London (eu-west-2), reference djwvyjtebmsavhcrmhxf. Dashboard: https://supabase.com/dashboard/project/djwvyjtebmsavhcrmhxf . Initial project cost quote: $0/month. Free tier currently lists 50,000 monthly active users, with other usage caps. The project is ACTIVE_HEALTHY. Its private breezze database schema exists, with anon/authenticated roles denied USAGE. Railway Postgres is still the existing app data source until a separately verified migration.

Supabase Auth origin: https://djwvyjtebmsavhcrmhxf.supabase.co
Flutter public publishable key: sb_publishable_ZloCmmQPo86OqHbH3Yqgsw_xZGPqSi3
Server Railway values required: SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY, matching the project above. Never put a service-role or secret key in Flutter, a repository, or a URL.

## Native Google and Apple

The Flutter implementation uses native Google and Apple SDKs to obtain provider ID tokens, then exchanges them with Supabase Auth using the ID-token grant. NestJS verifies the new Supabase user access token through Supabase Auth /auth/v1/user and issues Breezze's existing short-lived revocable session. App account IDs and ownership remain in Breezze.

Google Android/iOS: configure OAuth Android SHA fingerprints, iOS bundle identifier and required URL scheme, and a Google Cloud Web OAuth Client ID within Supabase Authentication > Providers > Google. Supply BREEZZE_GOOGLE_WEB_CLIENT_ID to Flutter, and BREEZZE_GOOGLE_IOS_CLIENT_ID for iOS if needed. Review Supabase's native Google nonce configuration before live sign-in.

Apple iOS/macOS: configure the Apple Developer account, bundle ID, Sign in with Apple capability and provisioning, plus Supabase Authentication > Providers > Apple. Only enable Flutter BREEZZE_APPLE_SIGN_IN_ENABLED=true after live configuration and native testing. Apple Developer membership may cost money even while Supabase Auth is on Free. Apple uses a random nonce; send its SHA-256 hash to Apple and the raw nonce to Supabase.

Other operating systems require a separately reviewed OAuth redirect/deep-link implementation for social sign-in; the unsupported native buttons are disabled instead of opening an untested browser flow. Email/password remains usable in Breezze's existing Flutter layout. Social providers are not live simply because buttons compile.

## Secure legacy library migration

The historical Railway account owns an existing User ID, favorites, saved albums, and playlists. SupabaseAuthIdentity maps verified Supabase subjects to Breezze User IDs; matching email alone never proves ownership. POST /api/v1/auth/supabase/exchange is the only new sign-in exchange route. Temporary POST /api/v1/auth/supabase/claim requires both Supabase verified identity and the legacy Breezze Argon2id password and is gated by SUPABASE_LEGACY_CLAIM_ENABLED=true. Once migrated, the listener keeps their old Breezze account ID and library.

Internal Breezze access and refresh JWTs remain in the app service for backwards-compatible revocation and authorization. They are not a second login provider. Historical account rows, inactive social tables and previous schema migrations must be retained for a non-destructive migration and rollback; they are not active app login routes.

Password recovery uses Supabase Auth. Until full third-party identity deletion is implemented, the account deletion UI routes to Help & Support rather than incorrectly asking a Supabase user for a legacy Breezze password.

## Release gates

1. Enable Google and Apple provider configuration in the real Supabase project and verify native sign-in on iOS and Android emulators.
2. Configure matching public Supabase URL/key in Railway, apply the Prisma SupabaseAuthIdentity migration to the currently authoritative application database, verify NestJS token exchange.
3. Verify both fresh accounts and existing-account claims; ensure user A cannot see user B's library. Check email confirmation/reset, revoke sessions, and logout.
4. Pass exact-head CI typechecks, tests, Android/iOS and desktop builds. Keep the integration PR in draft until verified.
5. Back up and reconcile production data before any switch to Supabase PostgreSQL.

Cloudflare API edge and private R2 music delivery remain unrelated to identity. No media playback licensing or downloader permissions change as part of this authentication migration.

Status: integration code staged; Google/Apple provider client credentials are NOT configured or live-verified and no production auth cutover has occurred.
