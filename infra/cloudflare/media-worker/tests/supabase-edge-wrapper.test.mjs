import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';

test('Supabase native Edge Function preserves the signed audio path and private key', async () => {
  const key = 'breezze-audio-hmac-secret-with-strong-length';
  const apiSecret = 'sb_secret_test_only';
  const environment = {
    MEDIA_SIGNING_KEY: key,
    SUPABASE_URL: 'https://breezze-test.supabase.co',
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: apiSecret }),
  };
  let handler;
  globalThis.Deno = {
    env: { get: (name) => environment[name] },
    serve: (value) => { handler = value; },
  };
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url, init) => {
    requests.push({ url, init });
    return new Response('audio-ok', {
      status: 200,
      headers: { 'Content-Type': 'audio/mp4' },
    });
  };
  try {
    await import('../../../../supabase/functions/media/index.ts');
    assert.equal(typeof handler, 'function');

    const expires = Date.now() + 30_000;
    const signature = createHmac('sha256', key)
      .update(`track-1:AAC_256:${expires}`).digest('base64url');
    const request = new Request(
      `https://breezze-test.supabase.co/functions/v1/media/audio/track-1/AAC_256?e=${expires}&s=${signature}`,
    );
    const response = await handler(request);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), 'audio-ok');
    assert.equal(requests.length, 1);
    assert.equal(requests[0].url,
      'https://breezze-test.supabase.co/storage/v1/object/authenticated/breezze-media/audio/track-1/AAC_256');
    assert.equal(requests[0].init.headers.get('apikey'), apiSecret);
    assert.equal(requests[0].init.headers.get('Authorization'), null);
    assert.equal((await handler(new Request(
      'https://breezze-test.supabase.co/functions/v1/media/admin',
    ))).status, 404);
  } finally {
    globalThis.fetch = originalFetch;
    delete globalThis.Deno;
  }
});
