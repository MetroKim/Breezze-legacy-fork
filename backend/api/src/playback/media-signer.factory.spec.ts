import { MediaSignerFactory } from './media-signer.factory';

describe('MediaSignerFactory', () => {
  const originalNodeEnv = process.env.NODE_ENV;
  const originalKey = process.env.MEDIA_SIGNING_KEY;
  const originalCdn = process.env.CDN_BASE_URL;
  const originalMediaBackend = process.env.MEDIA_BACKEND;

  afterEach(() => {
    if (originalNodeEnv === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = originalNodeEnv;
    if (originalKey === undefined) delete process.env.MEDIA_SIGNING_KEY;
    else process.env.MEDIA_SIGNING_KEY = originalKey;
    if (originalCdn === undefined) delete process.env.CDN_BASE_URL;
    else process.env.CDN_BASE_URL = originalCdn;
    if (originalMediaBackend === undefined) delete process.env.MEDIA_BACKEND;
    else process.env.MEDIA_BACKEND = originalMediaBackend;
  });

  it('rejects a missing production signing key', () => {
    process.env.NODE_ENV = 'production';
    delete process.env.MEDIA_SIGNING_KEY;
    process.env.CDN_BASE_URL = 'https://cdn.example';

    expect(() => new MediaSignerFactory().create()).toThrow(
      'MEDIA_SIGNING_KEY_MUST_BE_AT_LEAST_32_BYTES',
    );
  });

  it('rejects a short production signing key', () => {
    process.env.NODE_ENV = 'production';
    process.env.MEDIA_SIGNING_KEY = 'too-short';
    process.env.CDN_BASE_URL = 'https://cdn.example';

    expect(() => new MediaSignerFactory().create()).toThrow(
      'MEDIA_SIGNING_KEY_MUST_BE_AT_LEAST_32_BYTES',
    );
  });

  it('rejects non-HTTPS production CDN URLs', () => {
    process.env.NODE_ENV = 'production';
    process.env.MEDIA_SIGNING_KEY = 'x'.repeat(40);
    process.env.CDN_BASE_URL = 'http://cdn.example';

    expect(() => new MediaSignerFactory().create()).toThrow(
      'CDN_BASE_URL_MUST_USE_HTTPS',
    );
  });
  it('rejects a production CDN URL with a path prefix', () => {
    process.env.NODE_ENV = 'production';
    process.env.MEDIA_SIGNING_KEY = 'x'.repeat(40);
    process.env.CDN_BASE_URL = 'https://cdn.example/media';

    expect(() => new MediaSignerFactory().create()).toThrow(
      'CDN_BASE_URL_MUST_BE_ORIGIN_ONLY',
    );
  });

  it('permits the exact trusted Supabase media function endpoint', () => {
    process.env.NODE_ENV = 'production';
    process.env.MEDIA_BACKEND = 'supabase';
    process.env.MEDIA_SIGNING_KEY = 'x'.repeat(40);
    process.env.CDN_BASE_URL =
      'https://breezzeref.supabase.co/functions/v1/media';

    const signed = new MediaSignerFactory().create()
      .createPlaybackUrl('track1', 'AAC_256');
    expect(signed.url).toContain(
      'https://breezzeref.supabase.co/functions/v1/media/audio/track1/AAC_256?');
  });

  it('rejects untrusted Supabase media hostnames and path prefixes', () => {
    process.env.NODE_ENV = 'production';
    process.env.MEDIA_BACKEND = 'supabase';
    process.env.MEDIA_SIGNING_KEY = 'x'.repeat(40);
    for (const cdn of [
      'https://example.com/functions/v1/media',
      'https://breezzeref.supabase.co/functions/v1/other',
      'https://breezzeref.supabase.co/functions/v1/media/extra',
      'https://breezzeref.supabase.co/functions/v1/media?secret=leak',
    ]) {
      process.env.CDN_BASE_URL = cdn;
      expect(() => new MediaSignerFactory().create()).toThrow(
        'SUPABASE_MEDIA_ENDPOINT_INVALID');
    }
  });

  it('uses the media Worker origin as the development fallback', () => {
    process.env.NODE_ENV = 'development';
    delete process.env.MEDIA_SIGNING_KEY;
    delete process.env.CDN_BASE_URL;

    const signer = new MediaSignerFactory().create();
    expect(signer.createPlaybackUrl('track-1', 'AAC_256').url)
      .toContain('http://localhost:8787/audio/track-1/AAC_256?');
  });

});
