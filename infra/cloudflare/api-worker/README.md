# Breezze API Edge Worker

This Worker is the Cloudflare edge entry point for the NestJS API. It is deliberately separate from `media-worker`, which handles private R2 uploads and media objects.

## Responsibilities

- Forward API requests to the configured HTTPS NestJS origin.
- Cache only public catalog detail GET routes:
  - `/api/v1/catalog/songs/{id}`
  - `/api/v1/catalog/albums/{id}`
  - `/api/v1/catalog/artists/{id}`
- Bypass cache for all other routes, all requests with Authorization/Cookie headers, range requests, and non-GET methods.
- Vary public cache entries by full URL/query, visitor country and first accepted language.
- Never cache playback resolution, signed media URLs, auth, user libraries, playlists, favorites, listening history, or writes.

The Worker does not implement domain authorization, rights decisions, provider selection, or authentication. Those remain in NestJS.

## Configure

1. Set the Worker variable `API_ORIGIN` to the real HTTPS origin hosting NestJS. It must be the origin only (scheme + hostname + optional port), with no path/query, and must not point back at the Worker hostname. An unset value returns `503 API_ORIGIN_NOT_CONFIGURED`; no fake origin is committed.
2. Generate one shared secret of at least 32 random bytes: `openssl rand -hex 32`.
3. Set that exact value in the API deployment as `EDGE_SHARED_SECRET`.
4. From this directory, run `npx wrangler secret put EDGE_SHARED_SECRET` and enter the same value. Never commit it or put it in `wrangler.toml`.
5. Deploy this Worker with Wrangler. The repository workflow `.github/workflows/deploy-api-edge.yml` can deploy it after the required GitHub secrets are configured.
6. Attach the public API hostname/route to this Worker.
7. Restrict the origin firewall/network to Cloudflare egress where practical. The API also rejects requests without the shared edge secret when `NODE_ENV=production`; use network restrictions as a second layer.
8. Configure Cloudflare WAF managed rules and rate-limiting rules in the dashboard for auth, search, playback resolution and write endpoints. Use route-specific limits; do not rely on one global IP-only threshold because mobile carrier NAT can group many listeners behind one address.
9. Verify with `curl -i` that private routes return `Cache-Control: private, no-store` and `X-Breezze-Edge-Cache: BYPASS`.

## Cache behavior

The initial edge TTL is 90 seconds, with a 30-second stale-while-revalidate window. This is intentionally conservative. The Worker only stores a 200 response when the origin has not marked it private/no-store/no-cache and has not emitted a Set-Cookie header. Tune TTL after freshness and origin-load measurements.

Cloudflare Cache API storage is data-center-local; this is an edge optimization, not a globally consistent database. Redis remains the shared backend hot cache, PostgreSQL remains canonical truth, and client cache remains bounded and disposable.

## Deployment

```sh
npm install
npx wrangler deploy
```

Set `API_ORIGIN` as a Wrangler variable through the Cloudflare dashboard or deployment workflow. It must point to the actual NestJS HTTPS origin. Do not commit a fake/example production origin. Set `EDGE_SHARED_SECRET` with `wrangler secret put`; never put it in `wrangler.toml`.

The NestJS API requires the same `EDGE_SHARED_SECRET` in production, so direct requests to the origin are rejected. The Worker overwrites any client-supplied `x-breezze-edge-secret` header before forwarding and removes the header from responses.

The deployment workflow deploys the Worker only. The NestJS origin must already be deployed and reachable over HTTPS, and DNS/custom-domain routing plus WAF/rate-limit rules still require Cloudflare account configuration. This does not prove one-million-user capacity; staged load tests are required.

## Browser/Codespaces CORS policy

Configure `WEB_ALLOWED_ORIGINS` in the **Cloudflare Worker** as a
comma-separated list of **exact** trusted frontend origins, for example a
specific deployed web host and the specific Codespaces forwarded URL. Set the
same origins in NestJS `CORS_ALLOWED_ORIGINS`, since the API has an independent
origin allowlist. A development browser running at `http://127.0.0.1:8080`
requires that exact origin in each allowlist; `http://localhost:8080` is a
different origin. Never use a wildcard or reflect arbitrary origins with
credentials enabled. Production defaults to no browser origins until explicitly
configured. Both layers must be deployed for their configuration to take effect.

The Worker now answers allowed preflight requests with narrowly limited
methods and headers before the origin-secret check, and decorates successful
**and error** API responses with CORS headers for allowed origins, so upstream
outages do not masquerade as missing browser CORS. The backend remains the
authority for authentication and resource authorization.
