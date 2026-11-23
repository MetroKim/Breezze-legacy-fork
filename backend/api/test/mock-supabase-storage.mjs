// Synthetic private Supabase Storage API for isolated CI only.
// Never connect this fixture to a real user account or Supabase project.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';

const file = await readFile(new URL(
  '../../../apps/mobile/integration_test/fixtures/tone.m4a', import.meta.url,
));
const allowedKey = 'test-only-supabase-service-key';
const prefix = '/storage/v1/object/authenticated/breezze-media/audio/';
const trackId = '24ead000-7bce-498c-806c-d6084a0ed108';
const etag = '"breezze-ci-fixture-v1"';

function send(req, res, status, headers, body) {
  res.writeHead(status, { 'Cache-Control': 'private, no-store', ...headers });
  res.end(req.method === 'HEAD' ? undefined : body);
}

createServer((req, res) => {
  if (req.url === '/health' && req.method === 'GET') {
    return send(req, res, 200, { 'Content-Type': 'text/plain' }, 'ok');
  }
  const allowedPath = prefix + trackId + '/';
  if (!req.url?.startsWith(allowedPath) ||
      !['AAC_256', 'download'].includes(req.url.slice(allowedPath.length)) ||
      !['GET', 'HEAD'].includes(req.method)) {
    return send(req, res, 404, {}, 'not found');
  }
  if (req.headers.apikey !== allowedKey || req.headers.authorization) {
    return send(req, res, 403, {}, 'private');
  }
  const common = {
    'Content-Type': 'audio/mp4',
    'Accept-Ranges': 'bytes',
    ETag: etag,
  };
  let range = req.headers.range;
  if (range && req.headers['if-range'] &&
      req.headers['if-range'] !== etag) range = undefined;
  if (!range) {
    return send(req, res, 200, {
      ...common, 'Content-Length': file.length,
    }, file);
  }
  const match = /^bytes=(\d*)-(\d*)$/.exec(range);
  if (!match || (match[1] === '' && match[2] === '')) {
    return send(req, res, 416, { 'Content-Range': `bytes */${file.length}` });
  }
  const start = match[1] !== '' ? Number(match[1]) :
    Math.max(0, file.length - Number(match[2]));
  const end = match[1] !== '' ? Math.min(
    match[2] !== '' ? Number(match[2]) : file.length - 1, file.length - 1,
  ) : file.length - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
      start < 0 || start >= file.length || end < start) {
    return send(req, res, 416, { 'Content-Range': `bytes */${file.length}` });
  }
  const chunk = file.subarray(start, end + 1);
  send(req, res, 206, {
    ...common,
    'Content-Range': `bytes ${start}-${end}/${file.length}`,
    'Content-Length': chunk.length,
  }, chunk);
}).listen(8788, '127.0.0.1', () => {
  console.log('Synthetic Supabase Storage fixture listening on 127.0.0.1:8788');
});
