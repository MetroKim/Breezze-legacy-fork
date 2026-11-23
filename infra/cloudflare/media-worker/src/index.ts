/**
 * Breezze private music edge backed by Supabase Storage (not Cloudflare R2).
 * This worker never accepts uploads or makes a copyright/territory decision.
 * NestJS checks rights and produces short-lived HMAC grants first.
 */
export interface Env {
  MEDIA_SIGNING_KEY: string;
  SUPABASE_URL: string;
  SUPABASE_SECRET_KEY: string;
  SUPABASE_MEDIA_BUCKET?: string;
  // Only for isolated CI with a synthetic key and loopback storage server.
  SUPABASE_TEST_ALLOW_LOCAL_HTTP?: string;
}

const encoder = new TextEncoder();

function toBase64Url(bytes: ArrayBuffer): string {
  const binary = String.fromCharCode(...new Uint8Array(bytes));
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function constantTimeEqual(left: string, right: string): boolean {
  let mismatch = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i += 1) {
    mismatch |= (left.charCodeAt(i % Math.max(left.length, 1)) || 0)
      ^ (right.charCodeAt(i % Math.max(right.length, 1)) || 0);
  }
  return mismatch === 0;
}

async function sign(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return toBase64Url(await crypto.subtle.sign('HMAC', key, encoder.encode(payload)));
}

async function validSignature(
  secret: string,
  payload: string,
  signature: string | null,
  expires: number,
): Promise<boolean> {
  if (!signature || !/^[A-Za-z0-9_-]{43}$/.test(signature) ||
      !Number.isSafeInteger(expires) || expires <= Date.now()) {
    return false;
  }
  // Do not accept arbitrarily long-lived signed grants.
  if (expires > Date.now() + 6 * 3600 * 1000 + 30_000) return false;
  const expected = await sign(secret, payload);
  return constantTimeEqual(expected, signature);
}

function error(status: number, code: string): Response {
  return new Response(code, {
    status,
    headers: {
      'Cache-Control': 'private, no-store',
      'Content-Type': 'text/plain; charset=utf-8',
      'X-Content-Type-Options': 'nosniff',
    },
  });
}

function storageOrigin(env: Env): URL | null {
  try {
    const value = new URL(env.SUPABASE_URL);
    const isolatedCI =
      env.SUPABASE_TEST_ALLOW_LOCAL_HTTP === 'true' &&
      env.SUPABASE_SECRET_KEY.startsWith('test-only-') &&
      value.protocol === 'http:' && value.hostname === '127.0.0.1';
    if ((value.protocol !== 'https:' && !isolatedCI) || !value.hostname ||
        value.username || value.password || value.search || value.hash ||
        value.pathname !== '/') return null;
    return value;
  } catch {
    return null;
  }
}

function trustedBucket(env: Env): string | null {
  const value = env.SUPABASE_MEDIA_BUCKET || 'breezze-media';
  return /^[a-z0-9][a-z0-9_-]{0,62}$/.test(value) ? value : null;
}

async function playback(request: Request, url: URL, env: Env): Promise<Response> {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return error(405, 'METHOD_NOT_ALLOWED');
  }
  const parts = url.pathname.split('/').filter(Boolean);
  if (parts.length !== 3 || parts[0] !== 'audio') return error(404, 'NOT_FOUND');
  const [, trackId, variant] = parts;
  if (!/^[a-zA-Z0-9_-]{1,128}$/.test(trackId) ||
      !/^[a-zA-Z0-9_-]{1,32}$/.test(variant)) {
    return error(400, 'INVALID_MEDIA_PATH');
  }

  const expires = Number(url.searchParams.get('e'));
  const payload = `${trackId}:${variant}:${expires}`;
  if (!await validSignature(env.MEDIA_SIGNING_KEY, payload, url.searchParams.get('s'), expires)) {
    return error(403, 'MEDIA_SIGNATURE_INVALID_OR_EXPIRED');
  }

  const origin = storageOrigin(env);
  const bucket = trustedBucket(env);
  if (!origin || !bucket) return error(503, 'SUPABASE_STORAGE_INVALID');

  const range = request.headers.get('Range');
  if (range && (!/^bytes=(?:\d+-\d*|\d*-\d+)$/.test(range))) {
    return error(416, 'INVALID_RANGE');
  }

  // Storage bucket is private: privileged JWT stays at the edge. No client
  // receives the service role key or can alter the object key.
  const objectPath = `/storage/v1/object/authenticated/${bucket}/audio/${trackId}/${variant}`;
  const upstreamUrl = new URL(objectPath, origin);
  const headers = new Headers({
    apikey: env.SUPABASE_SECRET_KEY,
  });
  if (range) headers.set('Range', range);
  const ifRange = request.headers.get('If-Range');
  if (ifRange) headers.set('If-Range', ifRange);

  let upstream: Response;
  try {
    upstream = await fetch(upstreamUrl.toString(), {
      method: request.method,
      headers,
      redirect: 'manual',
    });
  } catch {
    return error(502, 'SUPABASE_STORAGE_UNAVAILABLE');
  }
  if (upstream.status === 404) return error(404, 'MEDIA_NOT_FOUND');
  if (upstream.status === 416) {
    const partialHeaders = new Headers({
      'Cache-Control': 'private, no-store',
      'Accept-Ranges': 'bytes',
    });
    const contentRange = upstream.headers.get('Content-Range');
    if (contentRange) partialHeaders.set('Content-Range', contentRange);
    return new Response(null, { status: 416, headers: partialHeaders });
  }
  // Do not follow redirects to an untrusted host or return upstream
  // credential errors to the client.
  if (upstream.status !== 200 && upstream.status !== 206) {
    return error(502, 'SUPABASE_STORAGE_BAD_RESPONSE');
  }
  if (range && upstream.status !== 206 && !ifRange) {
    return error(502, 'MEDIA_RANGE_NOT_SUPPORTED');
  }

  const replyHeaders = new Headers({
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
    'Accept-Ranges': upstream.headers.get('Accept-Ranges') ?? 'bytes',
    'Content-Type': upstream.headers.get('Content-Type') ??
      (variant.includes('LOSSLESS') ? 'audio/flac' : 'audio/mp4'),
  });
  for (const key of ['Content-Length', 'Content-Range', 'ETag', 'Last-Modified']) {
    const value = upstream.headers.get(key);
    if (value != null) replyHeaders.set(key, value);
  }
  return new Response(request.method === 'HEAD' ? null : upstream.body, {
    status: upstream.status,
    headers: replyHeaders,
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!env.MEDIA_SIGNING_KEY || !env.SUPABASE_URL ||
        !env.SUPABASE_SECRET_KEY) {
      return error(503, 'SUPABASE_STORAGE_NOT_CONFIGURED');
    }
    const url = new URL(request.url);
    if (url.pathname.startsWith('/audio/')) {
      return playback(request, url, env);
    }
    return error(404, 'NOT_FOUND');
  },
};
