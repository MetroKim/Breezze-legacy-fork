export interface Env {
  API_ORIGIN?: string;
  EDGE_SHARED_SECRET: string;
  // Exact HTTPS/loopback browser origins, configured per deployment.
  WEB_ALLOWED_ORIGINS?: string;
}

const PUBLIC_CATALOG_PATH =
  /^\/api\/v1\/catalog\/(?:songs|albums|artists)\/[A-Za-z0-9_-]{1,128}$/;

const EDGE_TTL_SECONDS = 90;
const STALE_TTL_SECONDS = 30;

function jsonError(status: number, code: string): Response {
  return Response.json(
    { statusCode: status, error: code },
    { status, headers: { 'Cache-Control': 'no-store' } },
  );
}


// Browser origin allowlisting is distinct from server-to-server edge auth.
// Never use '*' with credentialed requests or trust a client-supplied origin.
function browserOrigin(request: Request, env: Env): string | null {
  const origin = request.headers.get('Origin');
  if (!origin) return null;
  const allowed = (env.WEB_ALLOWED_ORIGINS ?? '')
    .split(',').map((entry) => entry.trim()).filter(Boolean);
  return allowed.includes(origin) ? origin : null;
}

function withBrowserCors(response: Response, request: Request, env: Env): Response {
  const headers = new Headers(response.headers);
  const vary = headers.get('Vary');
  if (request.headers.has('Origin')) {
    const varyParts = (vary ?? '').split(',').map((item) => item.trim()).filter(Boolean);
    if (!varyParts.some((item) => item.toLowerCase() === 'origin')) {
      headers.set('Vary', [...varyParts, 'Origin'].join(', '));
    }
  }
  const origin = browserOrigin(request, env);
  if (origin) {
    headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Credentials', 'true');
    headers.set('Access-Control-Expose-Headers', 'x-request-id, x-breezze-edge-cache, etag, content-range');
  } else {
    headers.delete('Access-Control-Allow-Origin');
    headers.delete('Access-Control-Allow-Credentials');
    headers.delete('Access-Control-Expose-Headers');
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function corsPreflight(request: Request, env: Env): Response | null {
  if (request.method !== 'OPTIONS' || !request.headers.has('Access-Control-Request-Method')) {
    return null;
  }
  const origin = browserOrigin(request, env);
  const method = request.headers.get('Access-Control-Request-Method')?.toUpperCase();
  if (!origin || !method || !['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].includes(method)) {
    return jsonError(403, 'CORS_ORIGIN_OR_METHOD_DENIED');
  }
  const response = withBrowserCors(new Response(null, { status: 204 }), request, env);
  response.headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE');
  response.headers.set('Access-Control-Allow-Headers', 'authorization, content-type');
  response.headers.set('Access-Control-Max-Age', '600');
  response.headers.set('Cache-Control', 'private, no-store');
  return response;
}

function isPublicCatalogRequest(request: Request, url: URL): boolean {
  return request.method === 'GET'
    && PUBLIC_CATALOG_PATH.test(url.pathname)
    && !request.headers.has('authorization')
    && !request.headers.has('cookie')
    && !request.headers.has('range')
    && url.search.length === 0
    && (request.headers.get('accept-language') ?? 'und').length <= 256;
}

function buildCacheKey(request: Request, url: URL): Request {
  const country = request.headers.get('cf-ipcountry') ?? 'XX';
  const language = (request.headers.get('accept-language') ?? 'und').slice(0, 256);
  const key = new URL(url.toString());
  key.searchParams.set('__edge_country', country);
  key.searchParams.set('__edge_language', language);
  return new Request(key.toString(), { method: 'GET' });
}

function makeOriginRequest(url: string, request: Request, edgeSecret: string): Request {
  const headers = new Headers(request.headers);
  headers.delete('host');
  headers.delete('x-breezze-edge-secret');
  headers.set('x-breezze-edge-secret', edgeSecret);

  // Cloudflare overwrites cf-ipcountry at the edge. Never trust a client-
  // supplied Breezze country header; derive the origin value only here.
  headers.delete('x-breezze-country');
  const edgeCountry = request.headers.get('cf-ipcountry')?.trim().toUpperCase();
  if (edgeCountry && /^[A-Z]{2}$/.test(edgeCountry)) {
    headers.set('x-breezze-country', edgeCountry);
  }
  const init: RequestInit = {
    method: request.method,
    headers,
    redirect: request.redirect,
  };
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    init.body = request.body;
  }
  return new Request(url, init);
}

async function handle(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const configuredOrigin = env.API_ORIGIN?.trim();
  if (!configuredOrigin) return jsonError(503, 'API_ORIGIN_NOT_CONFIGURED');
  if (!env.EDGE_SHARED_SECRET || env.EDGE_SHARED_SECRET.length < 32) {
    return jsonError(503, 'EDGE_SHARED_SECRET_NOT_CONFIGURED');
  }

  const incoming = new URL(request.url);
  let origin: URL;
  try {
    origin = new URL(configuredOrigin);
  } catch {
    return jsonError(503, 'API_ORIGIN_INVALID');
  }
  if (origin.username || origin.password || origin.search || origin.hash
    || (origin.pathname !== '/' && origin.pathname !== '')) {
    return jsonError(503, 'API_ORIGIN_MUST_BE_ORIGIN_ONLY');
  }
  const path = incoming.pathname;
  const target = new URL(path + incoming.search, origin);

  if (target.protocol !== 'https:' && target.hostname !== 'localhost') {
    return jsonError(500, 'API_ORIGIN_MUST_USE_HTTPS');
  }

  const cacheable = isPublicCatalogRequest(request, incoming);
  if (cacheable) {
    const cache = caches.default;
    const cacheKey = buildCacheKey(request, incoming);
    const cached = await cache.match(cacheKey);
    if (cached) {
      const hit = new Response(cached.body, cached);
      hit.headers.set('X-Breezze-Edge-Cache', 'HIT');
      hit.headers.set('X-Request-Id', crypto.randomUUID());
      return hit;
    }

    const originRequest = makeOriginRequest(target.toString(), request, env.EDGE_SHARED_SECRET);
    let upstream: Response;
    try {
      upstream = await fetch(originRequest);
    } catch {
      return jsonError(502, 'API_ORIGIN_UNAVAILABLE');
    }
    const vary = (upstream.headers.get('vary') ?? '').toLowerCase();
    const unsafeVary = vary === '*' || vary.split(',').map((name) => name.trim())
      .some((name) => name !== '' && name !== 'accept-language');
    if (upstream.status !== 200
      || upstream.headers.has('set-cookie')
      || unsafeVary
      || /private|no-store|no-cache/i.test(upstream.headers.get('cache-control') ?? '')) {
      const passthrough = new Response(upstream.body, upstream);
      passthrough.headers.delete('x-breezze-edge-secret');
      passthrough.headers.set('Cache-Control', 'private, no-store');
      passthrough.headers.set('X-Breezze-Edge-Cache', 'BYPASS');
      return passthrough;
    }

    const headers = new Headers(upstream.headers);
    headers.delete('set-cookie');
    headers.delete('x-breezze-edge-secret');
    headers.set(
      'Cache-Control',
      `public, max-age=0, s-maxage=${EDGE_TTL_SECONDS}, stale-while-revalidate=${STALE_TTL_SECONDS}`,
    );
    headers.set('X-Breezze-Edge-Cache', 'MISS');
    const response = new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers,
    });
    const cacheHeaders = new Headers(response.headers);
    cacheHeaders.delete('x-request-id');
    const cacheBody = response.clone();
    const cacheResponse = new Response(cacheBody.body, {
      status: cacheBody.status,
      statusText: cacheBody.statusText,
      headers: cacheHeaders,
    });
    ctx.waitUntil(cache.put(cacheKey, cacheResponse));
    return response;
  }

  const upstreamRequest = makeOriginRequest(target.toString(), request, env.EDGE_SHARED_SECRET);
  let upstream: Response;
  try {
    upstream = await fetch(upstreamRequest);
  } catch {
    return jsonError(502, 'API_ORIGIN_UNAVAILABLE');
  }
  const response = new Response(upstream.body, upstream);
  response.headers.delete('x-breezze-edge-secret');
  response.headers.set('X-Breezze-Edge-Cache', 'BYPASS');
  response.headers.set('Cache-Control', 'private, no-store');
  return response;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const preflight = corsPreflight(request, env);
    if (preflight) return preflight;
    return withBrowserCors(await handle(request, env, ctx), request, env);
  },
};
