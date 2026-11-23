import {
  BadRequestException,
  ConflictException,
  HttpException,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import {
  createCipheriv, createDecipheriv, createHash, createPrivateKey,
  createPublicKey, randomBytes, sign, timingSafeEqual, verify,
} from 'node:crypto';
import { PrismaService } from '../prisma.service';
import { AuthService } from './auth.service';

type Provider = 'google' | 'apple' | 'auth0';
type OAuthConfig = {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
  authorizationEndpoint: string;
  tokenEndpoint: string;
  issuer: string;
  jwksEndpoint: string;
};

function digest(input: string): string {
  return createHash('sha256').update(input, 'utf8').digest('hex');
}

function encodeJson(data: object): string {
  return Buffer.from(JSON.stringify(data)).toString('base64url');
}

function safeCompare(a: string, b: string): boolean {
  const one = Buffer.from(a, 'utf8');
  const two = Buffer.from(b, 'utf8');
  return one.length === two.length && timingSafeEqual(one, two);
}

@Injectable()
export class SocialAuthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
  ) {}

  private validateProvider(input: string): Provider {
    if (input === 'google' || input === 'apple' || input === 'auth0') return input;
    throw new BadRequestException('SOCIAL_PROVIDER_UNSUPPORTED');
  }

  private appleSecret(): string {
    const { APPLE_TEAM_ID: teamId, APPLE_KEY_ID: keyId, APPLE_PRIVATE_KEY: rawKey } = process.env;
    if (!teamId || !keyId || !rawKey) {
      throw new ServiceUnavailableException('SOCIAL_PROVIDER_NOT_CONFIGURED');
    }
    const now = Math.floor(Date.now() / 1000);
    const header = encodeJson({ alg: 'ES256', kid: keyId, typ: 'JWT' });
    const payload = encodeJson({
      iss: teamId,
      iat: now,
      exp: now + 300,
      aud: 'https://appleid.apple.com',
      sub: process.env.APPLE_SERVICE_ID,
    });
    const unsigned = header + '.' + payload;
    const signature = sign(null, Buffer.from(unsigned), {
      key: createPrivateKey(rawKey.replace(/\\n/g, '\n')),
      dsaEncoding: 'ieee-p1363',
    });
    return unsigned + '.' + signature.toString('base64url');
  }

  private config(provider: Provider): OAuthConfig {
    // Only Auth0's managed tenant domains are accepted as OAuth origins.
    // An arbitrary URL here would send the server-side client secret to an
    // attacker during code exchange (SSRF/token exfiltration).
    const auth0Domain = process.env.AUTH0_DOMAIN?.trim().toLowerCase() ?? '';
    const auth0Trusted = /^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.auth0\.com$/.test(auth0Domain);
    const configured = provider === 'auth0'
      ? {
          clientId: process.env.AUTH0_CLIENT_ID ?? '',
          clientSecret: process.env.AUTH0_CLIENT_SECRET ?? '',
          redirectUri: process.env.AUTH0_REDIRECT_URI ?? '',
          authorizationEndpoint: auth0Trusted ? `https://${auth0Domain}/authorize` : '',
          tokenEndpoint: auth0Trusted ? `https://${auth0Domain}/oauth/token` : '',
          issuer: auth0Trusted ? `https://${auth0Domain}/` : '',
          jwksEndpoint: auth0Trusted ? `https://${auth0Domain}/.well-known/jwks.json` : '',
        }
      : provider === 'google'
        ? {
            clientId: process.env.GOOGLE_OAUTH_CLIENT_ID ?? '',
            clientSecret: process.env.GOOGLE_OAUTH_CLIENT_SECRET ?? '',
            redirectUri: process.env.GOOGLE_OAUTH_REDIRECT_URI ?? '',
            authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
            tokenEndpoint: 'https://oauth2.googleapis.com/token',
            issuer: 'https://accounts.google.com',
            jwksEndpoint: 'https://www.googleapis.com/oauth2/v3/certs',
          }
        : {
            clientId: process.env.APPLE_SERVICE_ID ?? '',
            clientSecret: '',
            redirectUri: process.env.APPLE_OAUTH_REDIRECT_URI ?? '',
            authorizationEndpoint: 'https://appleid.apple.com/auth/authorize',
            tokenEndpoint: 'https://appleid.apple.com/auth/token',
            issuer: 'https://appleid.apple.com',
            jwksEndpoint: 'https://appleid.apple.com/auth/keys',
          };
    if (provider === 'auth0' && !auth0Trusted) {
      throw new ServiceUnavailableException('AUTH0_DOMAIN_NOT_CONFIGURED');
    }
    if (!configured.clientId ||
        !configured.redirectUri ||
        ((provider === 'google' || provider === 'auth0') && !configured.clientSecret) ||
        (provider === 'apple' && (!process.env.APPLE_TEAM_ID ||
          !process.env.APPLE_KEY_ID || !process.env.APPLE_PRIVATE_KEY))) {
      throw new ServiceUnavailableException('SOCIAL_PROVIDER_NOT_CONFIGURED');
    }
    const redirect = new URL(configured.redirectUri);
    if ((process.env.NODE_ENV === 'production' && redirect.protocol !== 'https:') ||
        redirect.username || redirect.password || redirect.hash ||
        !redirect.pathname.endsWith('/auth/social/callback/' + provider)) {
      throw new ServiceUnavailableException('SOCIAL_REDIRECT_INVALID');
    }
    return configured;
  }

  providers() {
    return {
      google: Boolean(process.env.GOOGLE_OAUTH_CLIENT_ID &&
        process.env.GOOGLE_OAUTH_CLIENT_SECRET &&
        process.env.GOOGLE_OAUTH_REDIRECT_URI),
      auth0: Boolean(process.env.AUTH0_DOMAIN &&
        process.env.AUTH0_CLIENT_ID && process.env.AUTH0_CLIENT_SECRET &&
        process.env.AUTH0_REDIRECT_URI &&
        /^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.auth0\.com$/.test(process.env.AUTH0_DOMAIN.trim().toLowerCase())),
      apple: Boolean(process.env.APPLE_SERVICE_ID &&
        process.env.APPLE_TEAM_ID &&
        process.env.APPLE_KEY_ID &&
        process.env.APPLE_PRIVATE_KEY &&
        process.env.APPLE_OAUTH_REDIRECT_URI),
    };
  }

  async start(rawProvider: string, linkUserId?: string) {
    const provider = this.validateProvider(rawProvider);
    if (linkUserId) {
      if (provider !== 'auth0') throw new BadRequestException('SOCIAL_LINK_PROVIDER_UNSUPPORTED');
      // User ID comes ONLY from the authenticated, session-checked API guard.
      const owner = await this.prisma.user.findUnique({
        where: { id: linkUserId }, select: { id: true },
      });
      if (!owner) throw new UnauthorizedException('SOCIAL_LINK_OWNER_MISSING');
    }
    const config = this.config(provider);
    const state = randomBytes(32).toString('base64url');
    const pollSecret = randomBytes(32).toString('base64url');
    const nonce = randomBytes(32).toString('base64url');
    const codeVerifier = randomBytes(48).toString('base64url');
    const flow = await this.prisma.socialLoginFlow.create({
      data: {
        provider,
        linkUserId: linkUserId ?? null,
        stateHash: digest(state),
        pollSecretHash: digest(pollSecret),
        nonce,
        codeVerifier,
        expiresAt: new Date(Date.now() + 8 * 60 * 1000),
      },
      select: { id: true, expiresAt: true },
    });

    const endpoint = new URL(config.authorizationEndpoint);
    endpoint.searchParams.set('client_id', config.clientId);
    endpoint.searchParams.set('redirect_uri', config.redirectUri);
    endpoint.searchParams.set('response_type', 'code');
    endpoint.searchParams.set('scope', provider === 'apple' ? 'name email' : 'openid email profile');
    endpoint.searchParams.set('state', state);
    endpoint.searchParams.set('nonce', nonce);
    if (provider !== 'apple') {
      endpoint.searchParams.set('code_challenge', createHash('sha256').update(codeVerifier).digest('base64url'));
      endpoint.searchParams.set('code_challenge_method', 'S256');
      if (provider === 'google') endpoint.searchParams.set('prompt', 'select_account');
    } else {
      endpoint.searchParams.set('response_mode', 'form_post');
    }
    return {
      id: flow.id,
      secret: pollSecret,
      authorizationUrl: endpoint.toString(),
      expiresAt: flow.expiresAt,
    };
  }

  private async exchangeCode(
    provider: Provider, code: string, cfg: OAuthConfig, codeVerifier: string,
  ) {
    const params = new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      client_id: cfg.clientId,
      client_secret: provider === 'apple' ? this.appleSecret() : cfg.clientSecret,
      redirect_uri: cfg.redirectUri,
    });
    if (provider !== 'apple') params.set('code_verifier', codeVerifier);
    const response = await fetch(cfg.tokenEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: params,
      signal: AbortSignal.timeout(10000),
    });
    if (!response.ok) throw new UnauthorizedException('SOCIAL_CODE_REJECTED');
    const data = await response.json() as Record<string, unknown>;
    if (typeof data.id_token !== 'string' || data.id_token.length > 8192) {
      throw new UnauthorizedException('SOCIAL_ID_TOKEN_MISSING');
    }
    return data.id_token;
  }

  private async verifyIdentity(token: string, provider: Provider, cfg: OAuthConfig, expectedNonce: string | null) {
    const parts = token.split('.');
    if (parts.length !== 3) throw new UnauthorizedException('SOCIAL_TOKEN_INVALID');
    const header = JSON.parse(Buffer.from(parts[0], 'base64url').toString()) as { alg?: string; kid?: string };
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString()) as {
      sub?: string; iss?: string; aud?: string | string[]; exp?: number; iat?: number;
      nonce?: string; email?: string; email_verified?: boolean | string; name?: string;
      azp?: string;
    };
    if (header.alg !== 'RS256' || !header.kid ||
        (provider === 'google' ? !['accounts.google.com', 'https://accounts.google.com'].includes(payload.iss ?? '') : payload.iss !== cfg.issuer) ||
        (Array.isArray(payload.aud) && payload.aud.length > 1 && payload.azp !== cfg.clientId) ||
        !(Array.isArray(payload.aud) ? payload.aud.includes(cfg.clientId) : payload.aud === cfg.clientId) ||
        typeof payload.exp !== 'number' || payload.exp < Math.floor(Date.now() / 1000) ||
        typeof payload.iat !== 'number' || payload.iat > Math.floor(Date.now() / 1000) + 60 ||
        !payload.sub || (expectedNonce !== null && !safeCompare(payload.nonce ?? '', expectedNonce)) ||
        payload.email_verified === false || payload.email_verified === 'false' ||
        !payload.email) {
      throw new UnauthorizedException('SOCIAL_IDENTITY_INVALID');
    }

    const response = await fetch(cfg.jwksEndpoint, { signal: AbortSignal.timeout(8000) });
    if (!response.ok) throw new ServiceUnavailableException('SOCIAL_JWKS_UNAVAILABLE');
    const jwks = await response.json() as { keys?: Array<Record<string, unknown>> };
    const jwk = jwks.keys?.find((k) => k.kid === header.kid && k.kty === 'RSA');
    if (!jwk) throw new UnauthorizedException('SOCIAL_KEY_UNKNOWN');
    const isValid = verify(
      'RSA-SHA256',
      Buffer.from(parts[0] + '.' + parts[1]),
      createPublicKey({ key: jwk as any, format: 'jwk' }),
      Buffer.from(parts[2], 'base64url'),
    );
    if (!isValid) throw new UnauthorizedException('SOCIAL_SIGNATURE_INVALID');
    const email = payload.email.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254 ||
        ![true, 'true'].includes(payload.email_verified as never)) {
      throw new UnauthorizedException('SOCIAL_EMAIL_NOT_VERIFIED');
    }
    return { subject: payload.sub, email, name: payload.name?.trim().slice(0, 64) ?? null };
  }

  private async findOrCreateUser(
    provider: Provider,
    subject: string,
    email: string,
    name: string | null,
  ): Promise<string> {
    const existing = await this.prisma.socialAuthIdentity.findUnique({
      where: { provider_subject: { provider, subject } },
      select: { userId: true },
    });
    if (existing) return existing.userId;

    // Matching email is not proof that the OAuth provider controls an
    // existing Breezze password account. Require deliberate account linking.
    const collision = await this.prisma.user.findFirst({
      where: { email: { equals: email, mode: 'insensitive' } },
      select: { id: true },
    });
    if (collision) throw new ConflictException('SOCIAL_ACCOUNT_LINK_REQUIRED');

    try {
      const user = await this.prisma.user.create({
        data: {
          email,
          displayName: name,
          passwordHash: randomBytes(64).toString('base64url'),
          socialIdentities: { create: { provider, subject } },
        },
        select: { id: true },
      });
      return user.id;
    } catch (error) {
      // Concurrent callbacks cannot create duplicate provider identities.
      if (error && typeof error === 'object' && (error as {code?: string}).code === 'P2002') {
        const saved = await this.prisma.socialAuthIdentity.findUnique({
          where: { provider_subject: { provider, subject } },
          select: { userId: true },
        });
        if (saved) return saved.userId;
        throw new ConflictException('SOCIAL_ACCOUNT_LINK_REQUIRED');
      }
      throw error;
    }
  }

  private encryptResult(result: unknown): string {
    const secret = process.env.JWT_SECRET;
    if (!secret || secret.length < 32) throw new ServiceUnavailableException('SOCIAL_SESSION_ENCRYPTION_UNAVAILABLE');
    const key = createHash('sha256').update('breezze-social/v1:' + secret).digest();
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', key, iv);
    const encrypted = Buffer.concat([
      cipher.update(JSON.stringify(result), 'utf8'), cipher.final(),
    ]);
    return [iv.toString('base64url'), cipher.getAuthTag().toString('base64url'),
      encrypted.toString('base64url')].join('.');
  }

  private decryptResult(result: string): Record<string, unknown> {
    const secret = process.env.JWT_SECRET;
    if (!secret || secret.length < 32) throw new ServiceUnavailableException('SOCIAL_SESSION_ENCRYPTION_UNAVAILABLE');
    const parts = result.split('.');
    if (parts.length !== 3) throw new UnauthorizedException('SOCIAL_SESSION_INVALID');
    const key = createHash('sha256').update('breezze-social/v1:' + secret).digest();
    const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(parts[0], 'base64url'));
    decipher.setAuthTag(Buffer.from(parts[1], 'base64url'));
    return JSON.parse(Buffer.concat([
      decipher.update(Buffer.from(parts[2], 'base64url')), decipher.final(),
    ]).toString()) as Record<string, unknown>;
  }


  /** Explicit feature gate: Password Realm flow cannot support every MFA,
   * SSO and passkey feature. No Auth0 tokens or client secrets reach Flutter. */
  private embeddedSettings(): { config: OAuthConfig; connection: string } {
    const domain = process.env.AUTH0_DOMAIN?.trim().toLowerCase() ?? '';
    const clientId = process.env.AUTH0_NATIVE_CLIENT_ID?.trim() ?? '';
    const connection = process.env.AUTH0_DB_CONNECTION?.trim() ?? '';
    if (process.env.AUTH0_EMBEDDED_ENABLED !== 'true' ||
        !/^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.auth0\.com$/.test(domain) ||
        !clientId || clientId.length > 256 ||
        !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(connection)) {
      throw new ServiceUnavailableException('AUTH0_EMBEDDED_NOT_CONFIGURED');
    }
    return { connection, config: {
      clientId, clientSecret: '', redirectUri: '',
      authorizationEndpoint: '',
      tokenEndpoint: 'https://' + domain + '/oauth/token',
      issuer: 'https://' + domain + '/',
      jwksEndpoint: 'https://' + domain + '/.well-known/jwks.json',
    } };
  }

  private async authenticateEmbedded(email: string, password: string) {
    const { config, connection } = this.embeddedSettings();
    let response: Response;
    try {
      response = await fetch(config.tokenEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({
          grant_type: 'http://auth0.com/oauth/grant-type/password-realm',
          client_id: config.clientId, realm: connection,
          username: email.trim().toLowerCase(), password,
          scope: 'openid email profile',
        }),
        signal: AbortSignal.timeout(10000),
      });
    } catch (_) {
      throw new ServiceUnavailableException('AUTH0_EMBEDDED_UNAVAILABLE');
    }
    if (!response.ok) {
      const data = await response.json().catch(() => ({})) as Record<string, unknown>;
      if (response.status === 429 || data.error === 'too_many_attempts') {
        throw new HttpException('RATE_LIMITED', 429);
      }
      if (data.error === 'mfa_required') {
        throw new UnauthorizedException('AUTH0_EMBEDDED_MFA_REQUIRED');
      }
      if (data.error === 'invalid_grant' || data.error === 'invalid_user_password') {
        throw new UnauthorizedException('INVALID_CREDENTIALS');
      }
      throw new ServiceUnavailableException('AUTH0_EMBEDDED_UNAVAILABLE');
    }
    const data = await response.json().catch(() => ({})) as Record<string, unknown>;
    if (typeof data.id_token !== 'string' || data.id_token.length > 8192) {
      throw new ServiceUnavailableException('AUTH0_ID_TOKEN_MISSING');
    }
    // Password Realm grants do not carry an authorization-request nonce.
    // This token is received exclusively from pinned Auth0 over backend TLS.
    return this.verifyIdentity(data.id_token, 'auth0', config, null);
  }

  async embeddedLogin(email: string, password: string) {
    const identity = await this.authenticateEmbedded(email, password);
    const userId = await this.findOrCreateUser(
      'auth0', identity.subject, identity.email, identity.name,
    );
    return this.auth.issueVerifiedSocialSession(userId);
  }

  async embeddedRegister(email: string, password: string, displayName?: string) {
    const { config, connection } = this.embeddedSettings();
    let response: Response;
    try {
      response = await fetch(config.issuer + 'dbconnections/signup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({
          client_id: config.clientId, connection,
          email: email.trim().toLowerCase(), password,
          ...(displayName ? { user_metadata: { display_name: displayName.trim().slice(0, 64) } } : {}),
        }),
        signal: AbortSignal.timeout(10000),
      });
    } catch (_) {
      throw new ServiceUnavailableException('AUTH0_EMBEDDED_UNAVAILABLE');
    }
    if (!response.ok) {
      const data = await response.json().catch(() => ({})) as Record<string, unknown>;
      if (response.status === 429) throw new HttpException('RATE_LIMITED', 429);
      if (response.status === 409 || data.code === 'user_exists') {
        throw new ConflictException('EMAIL_TAKEN');
      }
      if (response.status >= 500) throw new ServiceUnavailableException('AUTH0_EMBEDDED_UNAVAILABLE');
      throw new BadRequestException('AUTH0_SIGNUP_REJECTED');
    }
    // Never issue a Breezze session until Auth0 verifies the email on login.
    return { verificationRequired: true };
  }

  async embeddedReset(email: string) {
    const { config, connection } = this.embeddedSettings();
    let response: Response;
    try {
      response = await fetch(config.issuer + 'dbconnections/change_password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({
          client_id: config.clientId, connection, email: email.trim().toLowerCase(),
        }),
        signal: AbortSignal.timeout(10000),
      });
    } catch (_) {
      throw new ServiceUnavailableException('AUTH0_EMBEDDED_UNAVAILABLE');
    }
    if (response.status === 429) throw new HttpException('RATE_LIMITED', 429);
    if (response.status >= 500) throw new ServiceUnavailableException('AUTH0_EMBEDDED_UNAVAILABLE');
    // Generic response avoids revealing whether the address has an account.
    return { sent: true };
  }

  private async linkVerifiedAuth0Identity(
    ownerId: string, identity: { subject: string; email: string },
  ): Promise<void> {
    const owner = await this.prisma.user.findUnique({
      where: { id: ownerId }, select: { id: true, email: true },
    });
    if (!owner || owner.email.trim().toLowerCase() !== identity.email) {
      throw new ConflictException('AUTH0_LINK_EMAIL_MISMATCH');
    }
    const bound = await this.prisma.socialAuthIdentity.findUnique({
      where: { provider_subject: { provider: 'auth0', subject: identity.subject } },
      select: { userId: true },
    });
    if (bound?.userId && bound.userId !== owner.id) {
      throw new ConflictException('AUTH0_IDENTITY_ALREADY_LINKED');
    }
    if (!bound) {
      try {
        await this.prisma.socialAuthIdentity.create({
          data: { userId: owner.id, provider: 'auth0', subject: identity.subject },
        });
      } catch (caught) {
        if ((caught as { code?: string })?.code !== 'P2002') throw caught;
        const current = await this.prisma.socialAuthIdentity.findUnique({
          where: { provider_subject: { provider: 'auth0', subject: identity.subject } },
          select: { userId: true },
        });
        if (current?.userId !== owner.id) throw new ConflictException('AUTH0_IDENTITY_ALREADY_LINKED');
      }
    }
  }

  async embeddedLink(userId: string, email: string, password: string) {
    const identity = await this.authenticateEmbedded(email, password);
    await this.linkVerifiedAuth0Identity(userId, identity);
    return { linked: true };
  }

  async callback(providerInput: string, state: string, code?: string, error?: string) {
    const provider = this.validateProvider(providerInput);
    if (!state || state.length > 256) throw new BadRequestException('SOCIAL_STATE_INVALID');
    const flow = await this.prisma.socialLoginFlow.findUnique({ where: { stateHash: digest(state) } });
    if (!flow || flow.provider !== provider || flow.expiresAt < new Date()) {
      throw new UnauthorizedException('SOCIAL_STATE_EXPIRED');
    }
    const locked = await this.prisma.socialLoginFlow.updateMany({
      where: { id: flow.id, status: 'pending', expiresAt: { gt: new Date() } },
      data: { status: 'processing' },
    });
    if (locked.count !== 1) throw new UnauthorizedException('SOCIAL_STATE_ALREADY_USED');
    try {
      if (error || !code) throw new UnauthorizedException('SOCIAL_PROVIDER_CANCELLED');
      const cfg = this.config(provider);
      const token = await this.exchangeCode(provider, code, cfg, flow.codeVerifier);
      const identity = await this.verifyIdentity(token, provider, cfg, flow.nonce);
      let session: unknown;
      if (provider === 'auth0' && flow.linkUserId) {
        // Explicit linking requires BOTH an existing Breezze session to
        // initiate the flow and this independent, verified Auth0 challenge.
        await this.linkVerifiedAuth0Identity(flow.linkUserId, identity);
        session = { linked: true };
      } else {
        const userId = await this.findOrCreateUser(
          provider, identity.subject, identity.email, identity.name,
        );
        session = await this.auth.issueVerifiedSocialSession(userId);
      }
      await this.prisma.socialLoginFlow.update({
        where: { id: flow.id },
        data: { status: 'completed', resultCiphertext: this.encryptResult(session),
          codeVerifier: '', nonce: '', completedAt: new Date() },
      });
      return true;
    } catch (caught) {
      const code = caught instanceof ConflictException
        ? (provider === 'auth0' ? 'AUTH0_ACCOUNT_LINK_REQUIRED' : 'SOCIAL_ACCOUNT_LINK_REQUIRED')
        : (error ? 'SOCIAL_PROVIDER_CANCELLED' : 'SOCIAL_AUTH_FAILED');
      await this.prisma.socialLoginFlow.update({
        where: { id: flow.id },
        data: { status: 'failed', errorCode: code,
          codeVerifier: '', nonce: '', completedAt: new Date() },
      });
      return false;
    }
  }

  async poll(flowId: string, suppliedSecret: string) {
    if (!/^[0-9a-f-]{36}$/.test(flowId) ||
        suppliedSecret.length < 32 || suppliedSecret.length > 256) {
      throw new UnauthorizedException('SOCIAL_FLOW_INVALID');
    }
    const flow = await this.prisma.socialLoginFlow.findUnique({ where: { id: flowId } });
    if (!flow || flow.expiresAt < new Date() ||
        !safeCompare(flow.pollSecretHash, digest(suppliedSecret))) {
      throw new UnauthorizedException('SOCIAL_FLOW_INVALID');
    }
    if (flow.status === 'failed') return { status: 'failed', code: flow.errorCode };
    if (flow.status !== 'completed' || !flow.resultCiphertext) return { status: 'pending' };
    const consumed = await this.prisma.socialLoginFlow.updateMany({
      where: { id: flowId, status: 'completed', pollSecretHash: digest(suppliedSecret) },
      data: { status: 'consumed', resultCiphertext: null },
    });
    if (consumed.count !== 1) throw new UnauthorizedException('SOCIAL_FLOW_CONSUMED');
    const result = this.decryptResult(flow.resultCiphertext);
    // A link confirmation must never be misinterpreted as a new bearer session.
    return result.linked === true
      ? { status: 'linked', linked: true }
      : { status: 'completed', session: result };
  }
}
