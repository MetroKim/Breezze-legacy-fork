import assert from 'node:assert/strict';
import test from 'node:test';
import worker from '../src/index.ts';

const knownOrigin = 'https://breezze.example';
const env = {
  EDGE_SHARED_SECRET: 'test-only-secret-not-deployed-0123456789',
  WEB_ALLOWED_ORIGINS: knownOrigin + ',http://127.0.0.1:8080',
};
const ctx = { waitUntil() {} };

function preflight(origin, method = 'GET') {
  return new Request('https://edge.example/api/v1/auth/social/providers', {
    method: 'OPTIONS',
    headers: {
      Origin: origin,
      'Access-Control-Request-Method': method,
      'Access-Control-Request-Headers': 'content-type',
    },
  });
}

test('trusted web origin receives credentialed 204 preflight', async () => {
  const response = await worker.fetch(preflight(knownOrigin, 'POST'), env, ctx);
  assert.equal(response.status, 204);
  assert.equal(response.headers.get('access-control-allow-origin'), knownOrigin);
  assert.equal(response.headers.get('access-control-allow-credentials'), 'true');
  assert.match(response.headers.get('access-control-allow-headers'), /content-type/);
  assert.match(response.headers.get('vary'), /Origin/i);
  assert.equal(response.headers.get('cache-control'), 'private, no-store');
});

test('unlisted origin is never reflected', async () => {
  const response = await worker.fetch(preflight('https://attacker.example'), env, ctx);
  assert.equal(response.status, 403);
  assert.equal(response.headers.get('access-control-allow-origin'), null);
});

test('unsafe method is denied even for a listed origin', async () => {
  const response = await worker.fetch(preflight(knownOrigin, 'TRACE'), env, ctx);
  assert.equal(response.status, 403);
});

test('allowed origin receives CORS headers even on missing backend configuration', async () => {
  const request = new Request('https://edge.example/api/v1/auth/social/providers', {
    headers: { Origin: knownOrigin },
  });
  const response = await worker.fetch(request, env, ctx);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('access-control-allow-origin'), knownOrigin);
  assert.equal(response.headers.get('cache-control'), 'no-store');
});

test('unspecified browser origin does not accidentally enable CORS', async () => {
  const response = await worker.fetch(
    new Request('https://edge.example/api/v1/auth/social/providers'),
    env,
    ctx,
  );
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('access-control-allow-origin'), null);
});

test('development loopback origin requires exact spelling', async () => {
  const good = await worker.fetch(preflight('http://127.0.0.1:8080'), env, ctx);
  const different = await worker.fetch(preflight('http://localhost:8080'), env, ctx);
  assert.equal(good.status, 204);
  assert.equal(different.status, 403);
});
