import {
  createHash, generateKeyPairSync, randomBytes, sign,
} from 'node:crypto';
import {
  ConflictException, ServiceUnavailableException, UnauthorizedException,
} from '@nestjs/common';
import { SocialAuthService } from './social-auth.service';

const config = {
  AUTH0_DOMAIN: '',
  AUTH0_CLIENT_ID: '',
  AUTH0_CLIENT_SECRET: '',
  AUTH0_REDIRECT_URI: '',
  GOOGLE_OAUTH_CLIENT_ID: 'breezze-google-test-client',
  GOOGLE_OAUTH_CLIENT_SECRET: 'server-only-test-secret',
  GOOGLE_OAUTH_REDIRECT_URI:
    'https://api.breezze.example/api/v1/auth/social/callback/google',
  JWT_SECRET: 'test-social-jwt-encryption-secret-value-at-least-32-bytes',
};

describe('Social OAuth safety and cross-platform pairing', () => {
  const prisma = {
    socialLoginFlow: {
      create: jest.fn(),
      findUnique: jest.fn(),
      updateMany: jest.fn(),
      update: jest.fn(),
    },
    socialAuthIdentity: { findUnique: jest.fn(), create: jest.fn() },
    user: { findFirst: jest.fn(), findUnique: jest.fn(), create: jest.fn() },
  };
  const auth = { issueVerifiedSocialSession: jest.fn() };
  let social: SocialAuthService;
  const previous: Record<string, string | undefined> = {};
  let originalFetch: typeof fetch;

  beforeAll(() => {
    for (const [key, value] of Object.entries(config)) {
      previous[key] = process.env[key];
      process.env[key] = value;
    }
  });
  afterAll(() => {
    for (const key of Object.keys(config)) {
      if (previous[key] === undefined) delete process.env[key];
      else process.env[key] = previous[key];
    }
  });
  beforeEach(() => {
    jest.resetAllMocks();
    originalFetch = global.fetch;
    social = new SocialAuthService(prisma as any, auth as any);
  });
  afterEach(() => {
    global.fetch = originalFetch;
    for (const key of ['AUTH0_DOMAIN', 'AUTH0_CLIENT_ID',
      'AUTH0_CLIENT_SECRET', 'AUTH0_REDIRECT_URI']) {
      process.env[key] = '';
    }
  });

  it('only enables providers when server-side OAuth credentials exist', () => {
    expect(social.providers()).toEqual({ google: true, auth0: false, apple: false });
    expect(() => (social as any).config('apple')).toThrow(
      ServiceUnavailableException,
    );
  });

  it('starts with random verifier, hashed state and app-only pairing secret', async () => {
    prisma.socialLoginFlow.create.mockImplementation(({data}: any) =>
      Promise.resolve({
        id: 'd1a7fd75-83f5-4e52-917d-082b25643bb9',
        expiresAt: data.expiresAt,
      }),
    );
    const first = await social.start('google');
    const second = await social.start('google');
    const one = new URL(first.authorizationUrl);
    const two = new URL(second.authorizationUrl);
    expect(first.secret).not.toBe(second.secret);
    expect(one.searchParams.get('state')).not.toBe(two.searchParams.get('state'));
    expect(one.searchParams.get('code_challenge_method')).toBe('S256');
    expect(one.searchParams.get('nonce')).toBeTruthy();
    expect(first.authorizationUrl).not.toContain(first.secret);
    expect(prisma.socialLoginFlow.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          provider: 'google',
          stateHash: expect.any(String),
          pollSecretHash: expect.any(String),
          codeVerifier: expect.any(String),
        }),
      }),
    );
    const stored = prisma.socialLoginFlow.create.mock.calls[0][0].data;
    expect(stored.stateHash).toBe(
      createHash('sha256').update(one.searchParams.get('state')!).digest('hex'),
    );
  });

  it('never sends an encrypted session to anyone with the wrong pairing secret', async () => {
    prisma.socialLoginFlow.findUnique.mockResolvedValue({
      id: 'd1a7fd75-83f5-4e52-917d-082b25643bb9',
      pollSecretHash: createHash('sha256').update('right-secret-xxxxxxxxxxxxxxxxxxxxxxxx').digest('hex'),
      expiresAt: new Date(Date.now() + 100000),
      status: 'completed',
      resultCiphertext: 'encrypted.session.goes.here',
    });
    await expect(social.poll('d1a7fd75-83f5-4e52-917d-082b25643bb9',
      'wrong-secret-xxxxxxxxxxxxxxxxxxxxxxxx'))
      .rejects.toBeInstanceOf(UnauthorizedException);
    expect(prisma.socialLoginFlow.updateMany).not.toHaveBeenCalled();
  });

  it('consumes one-time encrypted session exactly once', async () => {
    const secret = randomBytes(32).toString('base64url');
    const session = { accessToken: 'access', refreshToken: 'refresh', user: {
      id: 'user-a', email: 'a@example.com',
    }};
    const encrypted = (social as any).encryptResult(session);
    const flow = {
      id: 'd1a7fd75-83f5-4e52-917d-082b25643bb9',
      pollSecretHash: createHash('sha256').update(secret).digest('hex'),
      expiresAt: new Date(Date.now() + 100000),
      status: 'completed', resultCiphertext: encrypted,
    };
    prisma.socialLoginFlow.findUnique.mockResolvedValue(flow);
    prisma.socialLoginFlow.updateMany.mockResolvedValueOnce({ count: 1 });
    const done = await social.poll(flow.id, secret);
    expect(done).toEqual({ status: 'completed', session });
    expect(prisma.socialLoginFlow.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({ id: flow.id, status: 'completed' }),
        data: { status: 'consumed', resultCiphertext: null },
      }),
    );
    prisma.socialLoginFlow.updateMany.mockResolvedValueOnce({ count: 0 });
    await expect(social.poll(flow.id, secret))
      .rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('verifies the OIDC JWT signature and nonce with the provider JWKS', async () => {
    const pair = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const jwk = pair.publicKey.export({ format: 'jwk' }) as any;
    jwk.kid = 'test-key';
    jwk.alg = 'RS256';
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ keys: [jwk] }),
    } as unknown as Response);
    const nonce = 'test-challenge';
    const token = (subject: string, challenge: string) => {
      const header = Buffer.from(JSON.stringify({
        typ: 'JWT', alg: 'RS256', kid: 'test-key',
      })).toString('base64url');
      const payload = Buffer.from(JSON.stringify({
        iss: 'https://accounts.google.com',
        aud: config.GOOGLE_OAUTH_CLIENT_ID,
        exp: Math.floor(Date.now() / 1000) + 300,
        iat: Math.floor(Date.now() / 1000),
        sub: subject,
        nonce: challenge,
        email: 'signed@example.com',
        email_verified: true,
      })).toString('base64url');
      const message = header + '.' + payload;
      const sig = sign('RSA-SHA256', Buffer.from(message), pair.privateKey);
      return message + '.' + sig.toString('base64url');
    };
    const cfg = (social as any).config('google');
    await expect((social as any).verifyIdentity(token('subject', nonce),
      'google', cfg, nonce)).resolves.toMatchObject({
        subject: 'subject', email: 'signed@example.com',
    });
    await expect((social as any).verifyIdentity(token('subject', 'incorrect'),
      'google', cfg, nonce)).rejects.toBeInstanceOf(UnauthorizedException);
    const corrupted = token('subject', nonce).split('.');
    corrupted[2] = Buffer.from('bad-signature').toString('base64url');
    await expect((social as any).verifyIdentity(corrupted.join('.'),
      'google', cfg, nonce)).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('requires deliberate linking instead of hijacking a password account by email', async () => {
    prisma.socialAuthIdentity.findUnique.mockResolvedValue(null);
    prisma.user.findFirst.mockResolvedValue({ id: 'existing-password-user' });
    await expect((social as any).findOrCreateUser('google',
      'provider-subject', 'existing@example.com', 'Display Name'))
      .rejects.toBeInstanceOf(ConflictException);
    expect(prisma.user.create).not.toHaveBeenCalled();
  });

  it('rejects reused or expired state before any identity exchange', async () => {
    const state = randomBytes(32).toString('base64url');
    prisma.socialLoginFlow.findUnique.mockResolvedValue({
      id: 'flow', provider: 'google',
      expiresAt: new Date(Date.now() - 1000),
    });
    await expect(social.callback('google', state, 'code'))
      .rejects.toBeInstanceOf(UnauthorizedException);
    expect(global.fetch).toBe(originalFetch);
    expect(prisma.socialLoginFlow.updateMany).not.toHaveBeenCalled();
  });

  const configureAuth0 = () => {
    process.env.AUTH0_DOMAIN = 'breezze-test.us.auth0.com';
    process.env.AUTH0_CLIENT_ID = 'breezze-auth0-test-client';
    process.env.AUTH0_CLIENT_SECRET = 'test-only-auth0-client-secret';
    process.env.AUTH0_REDIRECT_URI =
      'https://breezze-api-edge.example/api/v1/auth/social/callback/auth0';
  };

  it('advertises Auth0 only with a trusted tenant and full server configuration', () => {
    configureAuth0();
    expect(social.providers().auth0).toBe(true);
    const cfg = (social as any).config('auth0');
    expect(cfg.issuer).toBe('https://breezze-test.us.auth0.com/');
    expect(cfg.jwksEndpoint).toBe('https://breezze-test.us.auth0.com/.well-known/jwks.json');
    process.env.AUTH0_DOMAIN = 'evil.example';
    expect(social.providers().auth0).toBe(false);
    expect(() => (social as any).config('auth0')).toThrow(
      ServiceUnavailableException,
    );
    process.env.AUTH0_DOMAIN = 'https://breezze-test.us.auth0.com';
    expect(() => (social as any).config('auth0')).toThrow(
      ServiceUnavailableException,
    );
  });

  it('starts Auth0 Universal Login using PKCE, nonce and no client secret in browser URL', async () => {
    configureAuth0();
    prisma.socialLoginFlow.create.mockImplementation(({data}: any) =>
      Promise.resolve({ id: 'd1a7fd75-83f5-4e52-917d-082b25643bb9', expiresAt: data.expiresAt }),
    );
    const start = await social.start('auth0');
    const redirect = new URL(start.authorizationUrl);
    expect(redirect.origin).toBe('https://breezze-test.us.auth0.com');
    expect(redirect.pathname).toBe('/authorize');
    expect(redirect.searchParams.get('scope')).toBe('openid email profile');
    expect(redirect.searchParams.get('code_challenge_method')).toBe('S256');
    expect(redirect.searchParams.get('nonce')).toBeTruthy();
    expect(redirect.searchParams.get('state')).toBeTruthy();
    expect(redirect.searchParams.get('client_secret')).toBeNull();
    expect(start.authorizationUrl).not.toContain(start.secret);
    expect(prisma.socialLoginFlow.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({
        provider: 'auth0', linkUserId: null, codeVerifier: expect.any(String),
      }) }),
    );
  });

  it('verifies Auth0 ID tokens with exact audience, issuer, nonce, signature and verified email', async () => {
    configureAuth0();
    const pair = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const jwk = pair.publicKey.export({ format: 'jwk' }) as any;
    jwk.kid = 'auth0-kid';
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ keys: [jwk] }),
    } as unknown as Response);
    const cfg = (social as any).config('auth0');
    const nonce = 'breezze-test-nonce';
    const token = (options: Record<string, unknown> = {}) => {
      const header = Buffer.from(JSON.stringify({alg: 'RS256', kid: 'auth0-kid'}))
        .toString('base64url');
      const payload = Buffer.from(JSON.stringify({
        iss: 'https://breezze-test.us.auth0.com/',
        aud: config.AUTH0_CLIENT_ID || 'breezze-auth0-test-client',
        exp: Math.floor(Date.now()/1000)+300,
        iat: Math.floor(Date.now()/1000),
        sub: 'auth0|user-1', nonce,
        email: 'listener@example.com',
        email_verified: true,
        ...options,
      })).toString('base64url');
      const unsigned = header+'.'+payload;
      return unsigned+'.'+sign('RSA-SHA256', Buffer.from(unsigned),pair.privateKey)
        .toString('base64url');
    };
    await expect((social as any).verifyIdentity(token(), 'auth0', cfg, nonce))
      .resolves.toMatchObject({subject:'auth0|user-1',email:'listener@example.com'});
    for (const claims of [
      {iss:'https://evil.example/'}, {aud:'another-client'},
      {nonce:'forged'}, {email_verified:false},
      {aud:['breezze-auth0-test-client','another-audience'],azp:'another-client'},
    ]) {
      await expect((social as any).verifyIdentity(token(claims),'auth0',cfg,nonce))
        .rejects.toBeInstanceOf(UnauthorizedException);
    }
    const corrupted=token().split('.');
    corrupted[2]=randomBytes(256).toString('base64url');
    await expect((social as any).verifyIdentity(corrupted.join('.'),'auth0',cfg,nonce))
      .rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('requires an authenticated Breezze owner to begin an explicit Auth0 link', async () => {
    configureAuth0();
    prisma.user.findUnique.mockResolvedValue({ id: 'existing-breezze-user' });
    prisma.socialLoginFlow.create.mockImplementation(({data}: any) =>
      Promise.resolve({id:'d1a7fd75-83f5-4e52-917d-082b25643bb9',expiresAt:data.expiresAt}),
    );
    await social.start('auth0','existing-breezze-user');
    expect(prisma.user.findUnique).toHaveBeenCalledWith({
      where:{id:'existing-breezze-user'},select:{id:true},
    });
    expect(prisma.socialLoginFlow.create).toHaveBeenCalledWith(
      expect.objectContaining({data:expect.objectContaining({
        provider:'auth0',linkUserId:'existing-breezze-user',
      })}),
    );
    await expect(social.start('google','existing-breezze-user'))
      .rejects.toThrow('SOCIAL_LINK_PROVIDER_UNSUPPORTED');
  });

  it('binds a verified Auth0 identity only to the initiating Breezze user', async () => {
    configureAuth0();
    const secret = randomBytes(32).toString('base64url');
    const flow = {
      id:'d1a7fd75-83f5-4e52-917d-082b25643bb9',
      provider:'auth0',linkUserId:'existing-breezze-user',
      status:'pending',expiresAt:new Date(Date.now()+120000),
      nonce:'nonce',codeVerifier:'code-verifier',
    };
    prisma.socialLoginFlow.findUnique.mockResolvedValue(flow);
    prisma.socialLoginFlow.updateMany.mockResolvedValue({count:1});
    prisma.user.findUnique.mockResolvedValue({
      id:'existing-breezze-user',email:'listener@example.com',
    });
    prisma.socialAuthIdentity.findUnique.mockResolvedValue(null);
    prisma.socialAuthIdentity.create.mockResolvedValue({id:'identity-1'});
    jest.spyOn(social as any,'exchangeCode').mockResolvedValue('verified-token');
    jest.spyOn(social as any,'verifyIdentity').mockResolvedValue({
      subject:'auth0|user-1',email:'listener@example.com',name:'Listener',
    });
    const successful=await social.callback('auth0',secret,'valid-code');
    expect(successful).toBe(true);
    expect(prisma.socialAuthIdentity.create).toHaveBeenCalledWith({
      data:{userId:'existing-breezze-user',provider:'auth0',subject:'auth0|user-1'},
    });
    expect(auth.issueVerifiedSocialSession).not.toHaveBeenCalled();
    const cipher=prisma.socialLoginFlow.update.mock.calls[0][0].data.resultCiphertext;
    prisma.socialLoginFlow.findUnique.mockResolvedValue({
      ...flow, status:'completed',pollSecretHash:createHash('sha256').update(secret).digest('hex'),
      resultCiphertext:cipher,
    });
    expect(await social.poll(flow.id,secret)).toEqual({status:'linked',linked:true});
  });

  it('never links an Auth0 identity if email differs or subject belongs to another user', async () => {
    configureAuth0();
    const flow = {
      id:'d1a7fd75-83f5-4e52-917d-082b25643bb9',
      provider:'auth0',linkUserId:'existing-breezze-user',
      status:'pending',expiresAt:new Date(Date.now()+120000),
      nonce:'nonce',codeVerifier:'code-verifier',
    };
    prisma.socialLoginFlow.findUnique.mockResolvedValue(flow);
    prisma.socialLoginFlow.updateMany.mockResolvedValue({count:1});
    prisma.user.findUnique.mockResolvedValue({
      id:'existing-breezze-user',email:'owner@example.com',
    });
    prisma.socialAuthIdentity.findUnique.mockResolvedValue(null);
    jest.spyOn(social as any,'exchangeCode').mockResolvedValue('token');
    jest.spyOn(social as any,'verifyIdentity').mockResolvedValue({
      subject:'auth0|attacker',email:'attacker@example.com',name:'Attacker',
    });
    expect(await social.callback('auth0','valid-state','valid-code')).toBe(false);
    expect(prisma.socialAuthIdentity.create).not.toHaveBeenCalled();
    expect(prisma.user.create).not.toHaveBeenCalled();
    expect(prisma.socialLoginFlow.update).toHaveBeenCalledWith(expect.objectContaining({
      data:expect.objectContaining({status:'failed',errorCode:'AUTH0_ACCOUNT_LINK_REQUIRED'}),
    }));
  });

  it('Auth0 cannot silently take over a preexisting Breezze email account', async () => {
    prisma.socialAuthIdentity.findUnique.mockResolvedValue(null);
    prisma.user.findFirst.mockResolvedValue({id:'existing-password-user'});
    await expect((social as any).findOrCreateUser('auth0',
      'auth0|someone','existing@example.com','Display Name'))
      .rejects.toBeInstanceOf(ConflictException);
    expect(prisma.user.create).not.toHaveBeenCalled();
  });

});
