import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.ts';

const baseEnv = {
  MEDIA_SIGNING_KEY: 'breezze-test-key-that-is-long-enough',
  SUPABASE_URL: 'https://breezze-test.supabase.co',
  SUPABASE_SECRET_KEY: 'test-service-role-key-keep-private',
  SUPABASE_MEDIA_BUCKET: 'breezze-media',
};

function signedRequest({
  trackId = 'track-1',
  variant = 'AAC_256',
  expires = Date.now() + 60_000,
  method = 'GET',
  headers,
} = {}) {
  const payload = `${trackId}:${variant}:${expires}`;
  const sig = createHmac('sha256', baseEnv.MEDIA_SIGNING_KEY)
    .update(payload).digest('base64url');
  return new Request(
    `https://breezze-media.example/audio/${trackId}/${variant}?e=${expires}&s=${sig}`,
    { method, headers },
  );
}

async function withUpstream(response, work) {
  const prior = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return response;
  };
  try {
    return await work(calls);
  } finally {
    globalThis.fetch = prior;
  }
}

test('missing Supabase configuration fails closed', async () => {
  const response = await worker.fetch(signedRequest(), {
    ...baseEnv,
    SUPABASE_SECRET_KEY: '',
  });
  assert.equal(response.status, 503);
});

test('forged and expired grants never reach Supabase', async () =>
  withUpstream(new Response('should-not-serve'), async (calls) => {
    const forged = new Request(
      signedRequest().url.replace(/s=[A-Za-z0-9_-]+/, 's=' + 'a'.repeat(43)),
    );
    assert.equal((await worker.fetch(forged, baseEnv)).status, 403);
    assert.equal((await worker.fetch(signedRequest({ expires: Date.now() - 1000 }), baseEnv)).status, 403);
    assert.equal(calls.length, 0);
  }));

test('authorized audio is read from a private Supabase bucket; no secret leaks', async () =>
  withUpstream(new Response('private audio bytes', {
    status: 200,
    headers: {
      'content-type': 'audio/mp4',
      'content-length': '19',
      etag: '"version-1"',
    },
  }), async (calls) => {
    const response = await worker.fetch(signedRequest(), baseEnv);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), 'private audio bytes');
    assert.equal(response.headers.get('cache-control'), 'private, no-store');
    assert.equal(response.headers.get('etag'), '"version-1"');
    assert.equal(response.headers.get('authorization'), null);
    assert.equal(response.headers.get('set-cookie'), null);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url,
      'https://breezze-test.supabase.co/storage/v1/object/authenticated/breezze-media/audio/track-1/AAC_256');
    assert.equal(calls[0].options.headers.get('apikey'), baseEnv.SUPABASE_SECRET_KEY);
    assert.equal(calls[0].options.redirect, 'manual');
  }));

test('valid byte ranges are forwarded and returned with 206', async () =>
  withUpstream(new Response('part', {
    status: 206,
    headers: {
      'content-type': 'audio/mp4',
      'content-range': 'bytes 2-5/10',
      'content-length': '4',
    },
  }), async (calls) => {
    const response = await worker.fetch(signedRequest({
      headers: { Range: 'bytes=2-5' },
    }), baseEnv);
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('content-range'), 'bytes 2-5/10');
    assert.equal(calls[0].options.headers.get('Range'), 'bytes=2-5');
  }));

test('range fallback to 200 without If-Range is rejected', async () =>
  withUpstream(new Response('all bytes', { status: 200 }), async () => {
    const response = await worker.fetch(signedRequest({
      headers: { Range: 'bytes=1-2' },
    }), baseEnv);
    assert.equal(response.status, 502);
  }));

test('HEAD returns metadata but no body', async () =>
  withUpstream(new Response(null, {
    status: 200,
    headers: { etag: '"v1"', 'content-length': '42' },
  }), async (calls) => {
    const response = await worker.fetch(signedRequest({ method: 'HEAD' }), baseEnv);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), '');
    assert.equal(response.headers.get('content-length'), '42');
    assert.equal(calls[0].options.method, 'HEAD');
  }));

test('untrusted upstream redirect is not followed', async () =>
  withUpstream(new Response(null, {
    status: 302, headers: { Location: 'https://untrusted.example/audio.mp4' },
  }), async () => {
    assert.equal((await worker.fetch(signedRequest(), baseEnv)).status, 502);
  }));

test('invalid range and storage configuration fail without fetching audio', async () =>
  withUpstream(new Response('not-reached'), async (calls) => {
    const request = signedRequest({ headers: { Range: 'bytes=0-2,5-9' } });
    assert.equal((await worker.fetch(request, baseEnv)).status, 416);
    assert.equal((await worker.fetch(signedRequest(), {
      ...baseEnv, SUPABASE_URL: 'http://insecure.example',
    })).status, 503);
    assert.equal(calls.length, 0);
  }));
