# Breezze — Auth0 identity service

**Architecture:** Auth0 Universal Login handles new user credentials, email verification, external connections (Google/Apple when activated in Auth0), password reset, and hosted MFA. Supabase stays the **database** provider; Cloudflare R2 and Workers remain media and API edge. Breezze's existing NestJS session family and ACL/rights ownership logic remain the **resource authority** during migration.

## Selected: embedded Breezze-designed Auth0 database login (in-app)

The listener-facing experience uses the **existing Flutter Breezze AuthScreen**:
Breezze ribbon logo, `bzBackground`/`bzSurface1`/`bzSeparator` theme
tokens, restrained typography and spacing, monochrome action buttons,
accessible fields, SVG eye/eye-off icons, native registration, email
verification prompts and password-reset initiation. It is **not** an Auth0
WebView, an Auth0-hosted page or a new visual theme. Account linking uses
a Breezze-themed Flutter dialog. Flutter never contains an Auth0 client
secret, Auth0 ID token or Auth0 database access key.

Provision an **Auth0 Native Application** for the Breezze **database
email/password** flow. Enable the *Password* and *Password Realm* grants for
that app and the intended database connection (commonly
`Username-Password-Authentication`), subject to a security review of
Auth0's limitations and plan. Configure **server-only Railway API** variables:

| Setting | Purpose |
|---|---|
| `AUTH0_DOMAIN` | Verified tenant hostname, no protocol, e.g. `example.us.auth0.com` |
| `AUTH0_NATIVE_CLIENT_ID` | Native/public Auth0 application client ID |
| `AUTH0_DB_CONNECTION` | Exact Auth0 database connection name |
| `AUTH0_EMBEDDED_ENABLED` | Explicit `true` gate **only after** live identity tests |

Then build Flutter with `BREEZZE_AUTH_PROVIDER=auth0_embedded`
**only after** the API and Auth0 Native app have passed an end-to-end test.
The default build remains Breezze's existing authentication. No callback URL
is used for email/password-realm requests.

The Flutter UI sends the entered email/password over HTTPS to Breezze's
protected NestJS API. NestJS sends a server-to-server password-realm token
request to the pinned Auth0 origin; validates the Auth0-signed ID token with
strict audience, issuer, expiry, signature, and verified-email checks; maps
the immutable Auth0 subject to the correct Breezze user; and issues Breezze's
existing revocable session. Existing users must explicitly authenticate
to link their old Breezze account; matching emails never auto-merge records.

The following API contracts are *feature-gated*:
- `POST /api/v1/auth/auth0/login` — inline email/password.
- `POST /api/v1/auth/auth0/register` — database signup, returns
  `verificationRequired: true`; no session before verified login.
- `POST /api/v1/auth/auth0/password/reset` — request email reset; generic
  response does not reveal whether an account exists.
- `POST /api/v1/auth/auth0/link` — requires an authenticated Breezze JWT
  **and** verified Auth0 account password, matching email and unbound subject.

**Security limitations, not hidden:** Resource Owner Password Credentials
(ROPG)/Password Realm is discouraged by OAuth best practices, and the
credentials necessarily traverse Breezze's server instead of going only
to Auth0. This flow cannot automatically handle Auth0 MFA, passkeys,
enterprise federation or all social-provider flows. When Auth0 requires
MFA, Breezze explicitly refuses embedded sign-in rather than bypassing it.
Google/Apple sign-in may require system authentication UI. This option
must be re-reviewed before production release. Never enable password
grants for unwanted connections, never log submitted passwords, and keep
attack-protection/rate limits on both Breezze and Auth0.


## Why Breezze uses the existing cross-platform OAuth pairing flow

Breezze runs on Flutter Android, iOS, macOS, Windows, Linux, and web. Its preexisting NestJS provider pairing code supports all of these platforms via an external browser and a short-lived one-time encrypted device result, without browser redirects back into Flutter or embedding OAuth client secrets in the client.

For Auth0, the backend now implements the **OpenID Connect authorization code + PKCE S256 flow** against a trusted Auth0 tenant with unique state, unique nonce, code-verifier, RS256 JWKS signature validation, exact audience, issuer, expiry, and verified email. The ID token, Auth0 client secret, and Breezze session never travel through browser URL parameters; the new Breezze session is retrieved only by the initiating Flutter app with a one-time random pairing secret. A trusted server-side confidential Auth0 Regular Web Application is required; do **not** configure this as a Native client with a client secret in Flutter.

This does not yet imply that Breezze's own JWTs have become Auth0-issued access JWTs. Auth0 is the **authentication authority**; NestJS retains its revocable 15-minute access JWT and refresh-token family so its existing authorization, admin MFA and offline-logout safety remain compatible while the active account population migrates.

## Optional legacy hosted pairing setup (not the selected Breezze login)

The older hosted pairing implementation optionally uses an **Auth0 Regular Web Application** for the Breezze backend. It is not required for the selected embedded email/password experience. Set an exact allowed callback URL:

```
https://breezze-api-edge.ykw8vmq7ph.workers.dev/api/v1/auth/social/callback/auth0
```

Ensure the app has the Authorization Code grant enabled and the database/Universal Login connection enabled. Use Auth0's email verification and attack protection as appropriate. Set the following **server-only** Railway Breezze API environment values (never put the client secret in Flutter, the repository, or CI logs):

| Variable | Value |
|---|---|
| `AUTH0_DOMAIN` | Tenant hostname only, e.g. `your-tenant.us.auth0.com` (no `https://`, path or trailing slash) |
| `AUTH0_CLIENT_ID` | Auth0 confidential Regular Web Application Client ID |
| `AUTH0_CLIENT_SECRET` | Secret from Auth0, server only |
| `AUTH0_REDIRECT_URI` | The exact callback URL above |

Tenant hostname is intentionally constrained to `*.auth0.com` to prevent sending client secrets to untrusted/custom endpoints. Custom domains require a separately reviewed trust policy.

After deploying the backend build containing Auth0 support, `GET /api/v1/auth/social/providers` should advertise `auth0: true`. Set Flutter build-time `BREEZZE_AUTH_PROVIDER=auth0` **only then**. Until Auth0 tenant config, backend build deployment, and successful live tests, the default remains `breezze` so existing listeners can sign in.

The hosted Auth0 login opens from the Breezze account screen; only Auth0 sees password/signup/MFA input. Users who already have a Breezze email/password account may choose the migration sign-in, then open **Account → Link Auth0 sign-in**. That flow requires both a valid existing Breezze JWT and an independently verified Auth0 sign-in with the **same verified email**. It binds the Auth0 immutable `sub` to the existing Breezze user ID; matching email alone never signs into or links a preexisting account.

## API contracts

- `GET /api/v1/auth/social/providers`: `auth0` availability flag.
- `POST /api/v1/auth/social/auth0/start`: new Auth0 sign-in flow (returns state-bound authorization URL and one-time poll pairing secret).
- `GET /api/v1/auth/social/callback/auth0`: Auth0 code callback, server-only token exchange and verification; renders a browser completion page **without app tokens**.
- `POST /api/v1/auth/social/poll`: returns the Breezze user session once and clears the encrypted result; never gives a session to an invalid poll secret.
- `POST /api/v1/auth/social/auth0/link/start`: requires **Breezze JWT**, begins Auth0 linking to the existing user ID. On completed callback the poll returns `{status:'linked',linked:true}` without minting another Breezze session.

## Release / migration gates

1. Configure a dedicated Auth0 tenant/app and correct callback; never expose a confidential client secret.
2. Apply the Prisma migration `20261123210000_auth0_link_flow` to a backed-up, tested database before promoting the Auth0-enabled backend. It extends `SocialLoginFlow` with `linkUserId` (optional) and does not delete or re-key user records.
3. Deploy backend, smoke-test provider availability, unknown/invalid callback states, invalid nonce and forged Auth0 ID token, verified identity from Auth0, login, existing account link, logout and session revocation.
4. Enable `BREEZZE_AUTH_PROVIDER=auth0` for Flutter builds only after the API and Auth0 tenant pass real end-to-end tests.
5. Test external-browser pairing on Android/iOS emulators plus Chromium, Windows, Linux and macOS. Platform-specific browser restrictions need device acceptance.
6. For eventual retirement of legacy passwords, use Auth0's documented user import/lazy migration with a user-consent/verification plan. Do not silently auto-link by email, copy plaintext passwords, revoke every user session without a cutover plan or remove Breezze admins' MFA safeguards.

**Deployment status:** The embedded integration is staged and gated; no live Auth0 tenant, Native client ID, or enabled production configuration has been verified. Backend and Flutter implementation is staged on the draft GitHub integration branch, not in the deployed `main` application. No Auth0 tenant/client credentials have been connected or changed in this conversation; production Auth0 sign-in has NOT been verified. Cloudflare R2 billing and media secret setup are separate and remain unchanged.
