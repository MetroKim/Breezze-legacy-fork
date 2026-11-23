// Run only against the disposable Postgres and synthetic Supabase Storage on the CI runner.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomBytes, randomUUID } from 'node:crypto';
import { PrismaClient } from '@prisma/client';

assert.equal(new URL(process.env.DATABASE_URL).hostname, '127.0.0.1');
assert.equal(process.env.CDN_BASE_URL, 'http://127.0.0.1:8787');
const db = new PrismaClient();
const id = '24ead000-7bce-498c-806c-d6084a0ed108';
const audio = await readFile(new URL('../../../apps/mobile/integration_test/fixtures/tone.m4a', import.meta.url));
let token;
async function api(path, body) {
  const response = await fetch('http://127.0.0.1:3000/api/v1' + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'content-type': 'application/json', 'x-breezze-country': 'TZ',
      ...(token ? { authorization: 'Bearer ' + token } : {}) },
    body: JSON.stringify(body)
  });
  assert.ok(response.ok, path + ' returned ' + response.status);
  return (await response.json()).data;
}
try {
  await db.track.create({ data: { id, title: 'Runtime recording', duration: 40,
    artist: { create: { name: 'Breezze QA' } }, source: 'breezze_internal',
    territories: { create: { territory: 'TZ' } },
    rights: { create: [{action:'stream.full'}, {action:'download'}] } } });
  const user = await api('/auth/register', { email: randomUUID() + '@example.invalid', password: randomBytes(24).toString('hex') });
  token = user.accessToken;
  assert.ok(token);
  const session = await api('/playback/sessions', {trackId:id});
  assert.equal(session.playback.previewOnly, false);
  const range = await fetch(session.playback.streamUrl, { headers: { Range: 'bytes=0-127' } });
  assert.equal(range.status, 206);
  assert.deepEqual(Buffer.from(await range.arrayBuffer()), audio.subarray(0,128));
  const head = await fetch(session.playback.streamUrl, {method: 'HEAD'});
  assert.equal(head.status, 200);
  const etag = head.headers.get('etag');
  assert.ok(/^"[A-Za-z0-9._:-]{1,120}"$/.test(etag || ''), 'Supabase Storage must expose a strong object version');
  const matchingRange = await fetch(session.playback.streamUrl, {
    headers: { Range: 'bytes=128-255', 'If-Range': etag },
  });
  assert.equal(matchingRange.status, 206);
  assert.deepEqual(Buffer.from(await matchingRange.arrayBuffer()), audio.subarray(128,256));
  const changedMaster = await fetch(session.playback.streamUrl, {
    headers: { Range: 'bytes=128-255', 'If-Range': '"obsolete-supabase-object"' },
  });
  assert.equal(changedMaster.status, 200, 'mismatched If-Range must force a full replacement');
  assert.deepEqual(Buffer.from(await changedMaster.arrayBuffer()), audio);
  const stream = await fetch(session.playback.streamUrl);
  assert.equal(stream.status, 200);
  assert.deepEqual(Buffer.from(await stream.arrayBuffer()), audio);
  await api('/playback/sessions/' + session.id + '/pause', {});
  await api('/playback/sessions/' + session.id + '/resume', {});
  await api('/playback/sessions/' + session.id + '/stop', {});
  const grant = await api('/downloads', {trackId:id});
  assert.equal(grant.allowed,true);
  assert.ok(Date.parse(grant.offlineLeaseExpiresAt) > Date.now());
  const saved = await fetch(grant.url);
  assert.equal(saved.status, 200);
  assert.deepEqual(Buffer.from(await saved.arrayBuffer()),audio);
  assert.equal((await api('/downloads/' + id + '/revalidate', {})).allowed,true);
  await db.rightsUsagePermission.delete({where:{trackId_action:{trackId:id,action:'download'}}});
  assert.equal((await api('/downloads/' + id + '/revalidate', {})).allowed,false);
  console.log('Verified full recording, ETag/If-Range safety, range, pause/resume/stop, download, lease renewal and revocation');
} finally {
  await db.$disconnect();
}
