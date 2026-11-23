import assert from 'node:assert/strict';
import test from 'node:test';
import { createHmac } from 'node:crypto';
import worker from '../src/index.ts';

const key = 'this-test-signing-key-is-long-and-private';
const trackId = 'test-track';
const variant = 'AAC_256';
const bytes = new TextEncoder().encode('0123456789');
const calls = [];

const head = {
  size: bytes.length,
  httpEtag: '"asset-v1"',
  httpMetadata: { contentType: 'audio/mp4' },
};
function body(start, end) {
  const sliced = bytes.slice(start, end);
  return {
    ...head,
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(sliced);
        controller.close();
      },
    }),
  };
}
const bucket = {
  async head(objectKey) {
    calls.push({ method: 'head', objectKey });
    return objectKey === 'audio/test-track/AAC_256' ? head : null;
  },
  async get(objectKey, options) {
    calls.push({ method: 'get', objectKey, options });
    if (objectKey !== 'audio/test-track/AAC_256') return null;
    const start = options?.range?.offset ?? 0;
    const end = start + (options?.range?.length ?? bytes.length - start);
    return body(start, end);
  },
};
const env = { MEDIA_BUCKET: bucket, MEDIA_SIGNING_KEY: key };

function url(expires = Date.now() + 45_000, sig) {
  const signingPayload = `${trackId}:${variant}:${expires}`;
  const signature = sig ?? createHmac('sha256', key).update(signingPayload).digest('base64url');
  return `https://breezze-media.example/audio/${trackId}/${variant}?e=${expires}&s=${signature}`;
}

test('private media worker fails closed without R2 or signer', async () => {
  const req = new Request(url());
  assert.equal((await worker.fetch(req, { MEDIA_BUCKET: bucket })).status, 503);
  assert.equal((await worker.fetch(req, { MEDIA_SIGNING_KEY: key })).status, 503);
});

test('bad and expired signatures never read storage', async () => {
  calls.length = 0;
  assert.equal((await worker.fetch(new Request(url(Date.now()+45000,'x'.repeat(43))),env)).status,403);
  assert.equal((await worker.fetch(new Request(url(Date.now()-45000)),env)).status,403);
  assert.equal(calls.length, 0);
});

test('valid, authorized URL streams private audio with no-store', async () => {
  calls.length = 0;
  const response = await worker.fetch(new Request(url()),env);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), '0123456789');
  assert.equal(response.headers.get('Cache-Control'), 'private, no-store');
  assert.equal(response.headers.get('Content-Length'), '10');
  assert.equal(response.headers.get('ETag'), '"asset-v1"');
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), null);
  assert.deepEqual(calls.map(x=>x.objectKey), ['audio/test-track/AAC_256']);
});

test('GET Range returns exact bytes and proper 206 headers', async () => {
  calls.length = 0;
  const response = await worker.fetch(new Request(url(), {
    headers: { Range: 'bytes=2-5' },
  }),env);
  assert.equal(response.status, 206);
  assert.equal(await response.text(), '2345');
  assert.equal(response.headers.get('Content-Range'), 'bytes 2-5/10');
  assert.equal(response.headers.get('Content-Length'), '4');
  assert.equal(calls.at(-1)?.options?.range?.offset, 2);
  assert.equal(calls.at(-1)?.options?.range?.length, 4);
});

test('suffix byte range returns the final requested length', async () => {
  const response = await worker.fetch(new Request(url(), {
    headers: { Range: 'bytes=-3' },
  }),env);
  assert.equal(response.status,206);
  assert.equal(await response.text(),'789');
  assert.equal(response.headers.get('Content-Range'),'bytes 7-9/10');
});

test('out of bounds multi-range fails closed', async () => {
  const response = await worker.fetch(new Request(url(), {
    headers: { Range: 'bytes=2-4,7-9' },
  }),env);
  assert.equal(response.status, 416);
});

test('HEAD serves metadata without a body', async () => {
  const response = await worker.fetch(new Request(url(), {method:'HEAD'}),env);
  assert.equal(response.status,200);
  assert.equal(response.headers.get('Content-Length'),'10');
  assert.equal(await response.text(),'');
});

test('If-Range mismatch returns full 200 to prevent mixed audio assets', async () => {
  const response = await worker.fetch(new Request(url(), {
    headers: {Range:'bytes=2-4', 'If-Range':'"old-version"'},
  }),env);
  assert.equal(response.status,200);
  assert.equal(await response.text(),'0123456789');
});

test('invalid path and methods cannot read files', async () => {
  calls.length=0;
  const invalid = new Request('https://breezze-media.example/audio/../AAC_256');
  assert.equal((await worker.fetch(invalid,env)).status,404);
  assert.equal((await worker.fetch(new Request(url(), {method:'POST'}),env)).status,405);
  assert.equal(calls.length,0);
});

test('browser preflight permits only explicitly listed origins and range headers', async () => {
  const browserEnv = { ...env, WEB_ALLOWED_ORIGINS: 'https://breezze.example' };
  const preflight = new Request(url(), {
    method: 'OPTIONS',
    headers: {
      Origin: 'https://breezze.example',
      'Access-Control-Request-Method': 'GET',
      'Access-Control-Request-Headers': 'range',
    },
  });
  const response = await worker.fetch(preflight, browserEnv);
  assert.equal(response.status,204);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'),'https://breezze.example');
  assert.equal(response.headers.get('Vary'),'Origin');
  assert.equal(response.headers.get('Access-Control-Allow-Headers'),'Range, If-Range');
  assert.equal((await worker.fetch(new Request(url(), {
    method:'OPTIONS',
    headers:{
      Origin:'https://attacker.example',
      'Access-Control-Request-Method':'GET',
    },
  }),browserEnv)).status,403);
});

test('untrusted browser origin cannot read even a signed media URL', async () => {
  calls.length = 0;
  const response = await worker.fetch(new Request(url(),{
    headers: { Origin:'https://attacker.example' },
  }),{...env,WEB_ALLOWED_ORIGINS:'https://breezze.example'});
  assert.equal(response.status,403);
  assert.equal(calls.length,0);
});

test('authorized browser gets exposed seek metadata but no wildcard CORS', async () => {
  const response = await worker.fetch(new Request(url(), {
    headers:{ Origin:'https://breezze.example',Range:'bytes=0-1'},
  }),{...env,WEB_ALLOWED_ORIGINS:'https://breezze.example'});
  assert.equal(response.status,206);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'),'https://breezze.example');
  assert.match(response.headers.get('Access-Control-Expose-Headers') ?? '', /Content-Range/);
  assert.equal(response.headers.get('Access-Control-Allow-Credentials'),null);
});
