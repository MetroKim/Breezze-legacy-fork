export interface Env {
  MEDIA_BUCKET: R2Bucket;
  MEDIA_SIGNING_KEY: string;
}

const encoder = new TextEncoder();

function toBase64Url(bytes: ArrayBuffer): string {
  const binary = String.fromCharCode(...new Uint8Array(bytes));
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function fromBase64Url(value: string): Uint8Array {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - normalized.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
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

function constantTimeEqual(left: string, right: string): boolean {
  let mismatch = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i += 1) {
    mismatch |= (left.charCodeAt(i % Math.max(left.length, 1)) || 0)
      ^ (right.charCodeAt(i % Math.max(right.length, 1)) || 0);
  }
  return mismatch === 0;
}

async function validSignature(
  secret: string,
  payload: string,
  supplied: string | null,
  expires: number,
): Promise<boolean> {
  if (!secret || !supplied || !Number.isSafeInteger(expires) || Date.now() >= expires) {
    return false;
  }
  try {
    const expected = await sign(secret, payload);
    // Decode as well so malformed/non-base64url inputs are rejected.
    fromBase64Url(supplied);
    return constantTimeEqual(expected, supplied);
  } catch {
    return false;
  }
}

function error(status: number, message: string): Response {
  return new Response(message, {
    status,
    headers: { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' },
  });
}

async function playback(request: Request, url: URL, env: Env): Promise<Response> {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return error(405, 'METHOD_NOT_ALLOWED');
  }
  const parts = url.pathname.split('/').filter(Boolean);
  if (parts.length !== 3) return error(404, 'NOT_FOUND');
  const [, trackId, variant] = parts;
  if (!/^[a-zA-Z0-9_-]{1,128}$/.test(trackId)
    || !/^[a-zA-Z0-9_-]{1,32}$/.test(variant)) return error(400, 'INVALID_MEDIA_PATH');

  const expires = Number(url.searchParams.get('e'));
  const signature = url.searchParams.get('s');
  const payload = `${trackId}:${variant}:${expires}`;
  if (!await validSignature(env.MEDIA_SIGNING_KEY, payload, signature, expires)) {
    return error(403, 'MEDIA_SIGNATURE_INVALID_OR_EXPIRED');
  }

  const key = `audio/${trackId}/${variant}`;
  let rangeHeader = request.headers.get('range');
  let object: R2ObjectBody | R2Object | null;
  let status = 200;
  let rangeStart: number | null = null;
  let rangeLength: number | null = null;
  let totalSize: number | null = null;
  if (rangeHeader) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(rangeHeader);
    if (!match) return error(416, 'INVALID_RANGE');
    const start = match[1] ? Number(match[1]) : null;
    const end = match[2] ? Number(match[2]) : null;
    const head = await env.MEDIA_BUCKET.head(key);
    if (!head) return error(404, 'MEDIA_NOT_FOUND');
    // HTTP If-Range: a replaced R2 object must never be appended to a
    // different encoded master. A mismatch forces a new full 200 response.
    const ifRange = request.headers.get('if-range');
    if (ifRange != null && ifRange !== head.httpEtag) {
      rangeHeader = null;
      object = request.method === 'HEAD'
        ? head : await env.MEDIA_BUCKET.get(key);
    } else {
    if (
      (start === null && (end === null || end <= 0)) ||
      (start !== null && (!Number.isSafeInteger(start) || start < 0)) ||
      (end !== null && (!Number.isSafeInteger(end) || end < 0)) ||
      (start !== null && end !== null && end < start)
    ) {
      return new Response(null, {
        status: 416,
        headers: { 'Content-Range': `bytes */${head.size}`, 'Cache-Control': 'no-store' },
      });
    }
    // RFC 9110 byte-range semantics: suffix N means exactly the final N
    // bytes (not N+1), and an explicit end beyond EOF is clamped to EOF.
    const offset = start !== null
      ? start
      : Math.max(0, head.size - (end ?? 0));
    const rangeEnd = start !== null
      ? Math.min(end ?? (head.size - 1), head.size - 1)
      : head.size - 1;
    const length = start === null
      ? Math.min(end ?? 0, head.size)
      : rangeEnd - start + 1;
    if (offset < 0 || length < 1 || offset >= head.size || offset + length > head.size) {
      return new Response(null, {
        status: 416,
        headers: { 'Content-Range': `bytes */${head.size}`, 'Cache-Control': 'no-store' },
      });
    }
    rangeStart = offset;
    rangeLength = length;
    totalSize = head.size;
    object = await env.MEDIA_BUCKET.get(key, { range: { offset, length } });
    status = 206;
    }
  } else {
    object = request.method === 'HEAD'
      ? await env.MEDIA_BUCKET.head(key)
      : await env.MEDIA_BUCKET.get(key);
  }
  if (!object) return error(404, 'MEDIA_NOT_FOUND');

  const contentType = object.httpMetadata?.contentType
    || (variant.toUpperCase().includes('LOSSLESS') || variant.toUpperCase().includes('FLAC') || variant.toUpperCase().includes('HI_RES')
      ? 'audio/flac' : 'audio/mp4');
  const headers = new Headers({
    'Accept-Ranges': 'bytes',
    // Signed URLs must not be retained by browsers or intermediary caches: a cached
    // response could remain playable after the signature's expiry. Add edge caching
    // only with a cache key that includes the signature and a TTL capped by `expires`.
    'Cache-Control': 'private, no-store',
    'Content-Type': contentType,
    'ETag': object.httpEtag,
    'X-Content-Type-Options': 'nosniff',
  });
  if (rangeHeader && rangeStart !== null && rangeLength !== null && totalSize !== null) {
    headers.set('Content-Range', `bytes ${rangeStart}-${rangeStart + rangeLength - 1}/${totalSize}`);
    headers.set('Content-Length', String(rangeLength));
  } else {
    headers.set('Content-Length', String(object.size));
  }
  if (request.method === 'HEAD') return new Response(null, { status, headers });
  if (!('body' in object)) return error(500, 'MEDIA_BODY_UNAVAILABLE');
  return new Response(object.body, { status, headers });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!env.MEDIA_SIGNING_KEY || !env.MEDIA_BUCKET) return error(503, 'MEDIA_STORAGE_NOT_CONFIGURED');
    const url = new URL(request.url);
    if (url.pathname.startsWith('/audio/')) return playback(request, url, env);
    return error(404, 'NOT_FOUND');
  },
};
