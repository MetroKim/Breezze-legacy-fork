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
2. In **Google Cloud → Google Auth Platform**, create Android, iOS and Web OAuth client IDs for Breezze. Android needs the app's actual application ID and SHA-1 fingerprints for each signing certificate (debug and production); iOS needs Breezze's bundle ID. Add applicable client IDs and the Web client secret to the Supabase Google provider. Use Supabase's provider callback `https://djwvyjtebmsavhcrmhxf.supabase.co/auth/v1/callback` where the provider requests an OAuth redirect URI. On iOS, enable the provider's Skip nonce check setting for the documented native Google flow.
3. Set **Flutter build-time configuration**: `--dart-define=GOOGLE_WEB_CLIENT_ID=<web OAuth client ID>` and `--dart-define=GOOGLE_IOS_CLIENT_ID=<iOS OAuth client ID>` for iOS. These are client IDs, not secrets. Android also needs a matching Android OAuth client registered for its signing certificate. The Flutter Google Sign-In plugin uses the Web client ID as the server client ID.
4. Before generating native runners, set the shell environment variable `GOOGLE_IOS_REVERSED_CLIENT_ID` to the reversed iOS Google client ID (the URL scheme listed by Google). Run `apps/mobile/tool/generate_platform_targets.sh`; it adds Google and Breezze callback schemes to the generated `ios/Runner/Info.plist`.
5. Set up **Sign in with Apple** under your Apple Developer account for the actual Breezze App ID, bundle ID, and associated capabilities. For native iOS/macOS, run runner generation with `BREEZZE_APPLE_SIGN_IN_ENABLED=1`; configure the app's signing team and entitlements in Xcode. If Apple OAuth is also used on Android, web or desktop, register the Apple Service ID, domain, redirect, and signed client secret in Supabase. Apple's web/OAuth client secret must be renewed on its prescribed rotation schedule. A valid Apple Developer account is required for device provisioning.
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

**Status:** Code prepared in `feat/supabase-auth-breezze`. Provider configuration, backend deployment and end-to-end device tests are separate requirements before production launch.

Official references: https://supabase.com/docs/guides/auth/social-sign-in/auth-google and https://supabase.com/docs/guides/auth/social-sign-in/auth-apple and https://supabase.com/docs/guides/getting-started/quickstarts/flutter.
