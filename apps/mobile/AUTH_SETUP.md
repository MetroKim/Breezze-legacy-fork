# Breezze authentication — Supabase

Breezze uses **one identity provider: Supabase Auth**. Its embedded Flutter sign-in screen follows the Breezze design system. Users can continue with Google or Apple, or create an email/password account, without an Auth0-hosted login form. Google/Apple's secure native consent sheet is still provided by the operating system.

## Connected Supabase project

- Project: Breezze (`djwvyjtebmsavhcrmhxf`)
- URL: `https://djwvyjtebmsavhcrmhxf.supabase.co`
- Public publishable key: `sb_publishable_ZloCmmQPo86OqHbH3Yqgsw_xZGPqSi3`
- Dashboard: https://supabase.com/dashboard/project/djwvyjtebmsavhcrmhxf/auth/providers
- Redirect allow list: https://supabase.com/dashboard/project/djwvyjtebmsavhcrmhxf/auth/url-configuration

The URL and publishable key are **public client configuration**, not secrets. Never commit a Supabase secret or service-role key, Google client secret, or Apple private key.

## Configuration to finish

1. In **Supabase → Authentication → Providers**, enable Email, Google, and Apple. Email confirmation is recommended.
2. **Google Cloud: web + iOS clients created.** The web client `990493102909-6pj8hj2nkthcrb2a807mjnhhrgf5pqo7.apps.googleusercontent.com` and iOS client `990493102909-pg9d31ongdv2aghv53vb3uttgha9jnn3.apps.googleusercontent.com` (bundle `com.breezze.breezze`) are saved in the Supabase Google provider, with Google enabled and Skip nonce checks enabled for Flutter iOS per Supabase's native integration guidance. **Still needed: enter the web client secret in the Supabase Google provider; do not add it to source control.** Android requires an additional Android OAuth client matching the app's package ID and debug/release SHA-1 fingerprints. Supabase's Google callback is `https://djwvyjtebmsavhcrmhxf.supabase.co/auth/v1/callback`.
3. Both public Google client IDs above are now defaults in `auth_session.dart`; overriding with `--dart-define=GOOGLE_WEB_CLIENT_ID=...` and `--dart-define=GOOGLE_IOS_CLIENT_ID=...` remains optional. **Never** put a Google client secret in a Flutter binary. Android still needs an Android OAuth client registered for the app signing certificate. The Flutter Google Sign-In plugin uses the Web client ID as its server client ID.
4. The platform generator now includes the correct default Google iOS reversed URL scheme `com.googleusercontent.apps.990493102909-pg9d31ongdv2aghv53vb3uttgha9jnn3` and Breezze callback scheme in the generated `ios/Runner/Info.plist`. `GOOGLE_IOS_REVERSED_CLIENT_ID` remains available as an override.
5. **Apple Developer Program membership is not active (verified)**, so Apple's required App ID / Service ID / Sign in with Apple keys cannot yet be issued for Breezze. Do not claim Apple login active or start paid enrollment without user approval. Once membership is active, set up **Sign in with Apple** for the actual Breezze App ID (`com.breezze.breezze`), bundle ID, and capabilities. For native iOS/macOS, run runner generation with `BREEZZE_APPLE_SIGN_IN_ENABLED=1`; configure the app's signing team and entitlements in Xcode. If Apple OAuth is also used on Android, web or desktop, register the Apple Service ID, domain, redirect, and signed client secret in Supabase. Apple's web/OAuth client secret must be renewed on its prescribed rotation schedule. A valid Apple Developer account is required for device provisioning.
6. Add `io.breezze.app://login-callback/` to **Supabase → Auth → URL Configuration → Redirect URLs**. Configure an appropriate HTTPS Site URL and any real Breezze web callback origins, especially for web testing.
7. Deploy the NestJS API backend **with the same Supabase URL and publishable key** (optional env overrides: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`). The API verifies Supabase access tokens via the Supabase user endpoint on authenticated requests. Keep `DATABASE_URL` pointing at Breezze's existing Prisma catalog/user database, not the new Supabase Auth database.

### Design and identity boundaries

- No Auth0, melody-auth, or legacy Breezze OAuth pairing endpoint is used by the active login UI. The old controllers are not registered in NestJS.
- The Flutter client sends the **Supabase access token** to the Breezze API, which verifies the user and maps the Supabase user ID to the app's Prisma user row.
- An existing Breezze account using the same email but a different user UUID is **not silently merged**, to avoid account takeovers. Migration requires a separate verified account-linking flow.
- Backend admin MFA actions are fail-closed until a verified Supabase AAL2-to-admin authorization design is implemented.
- Old password confirmation for account deletion is not applicable to Google/Apple accounts. The account screen directs users to Support pending a secure identity-verified deletion path.
- Breezze's API, playlists, favorites, and playback permissions remain on the NestJS side. The Supabase `public` schema does not need to duplicate the Prisma tables merely to enable Auth.

## Verification checklist

- Email registration creates an identity in Supabase Auth, shows an email-confirmation state when required, and returns to Breezze after confirmation.
- Email sign-in/sign-out and persisted session restore work on a fresh Android emulator and iOS simulator.
- Android Google native credential sheet returns a valid Google ID token, then a Supabase session; iOS Google uses the correct URL scheme and client IDs.
- Native Apple Sign-In returns an ID token and Supabase session, including a nonce challenge; the first available full name is saved in profile metadata.
- An invalid/tampered/expired token is rejected by NestJS. Two users cannot see one another's account-owned library/playlist data.
- A signed-out client receives 401 for account endpoints. A valid Supabase bearer token passes the NestJS guard and creates/loads a matching Breezze Prisma user.
- Signing out of all devices invalidates Supabase refresh tokens; servers should never treat a cached token as proof of a current session.
- CI builds Android, iOS, web, macOS, Linux and Windows where supported. Manual provider checks require real OAuth credentials and signed app targets.

**Status:** Code and public Google client defaults prepared in `feat/supabase-auth-breezze`. Google provider is enabled with the Web + iOS client IDs but its web client secret is still unset. Google OAuth and Android native login are not fully verified; Apple requires developer membership; auth PR is not yet merged or deployed. Backend deployment and end-to-end device tests remain before launch.

Official references: https://supabase.com/docs/guides/auth/social-sign-in/auth-google and https://supabase.com/docs/guides/auth/social-sign-in/auth-apple and https://supabase.com/docs/guides/getting-started/quickstarts/flutter.
