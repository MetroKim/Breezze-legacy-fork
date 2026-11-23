import {
  CanActivate,
  ExecutionContext,
  HttpException,
  Injectable,
  OnModuleDestroy,
  ServiceUnavailableException,
} from '@nestjs/common';
import Redis from 'ioredis';
import { createHash, timingSafeEqual } from 'node:crypto';
import { isIP } from 'node:net';

@Injectable()
export class CloudflareAwareThrottlerGuard
  implements CanActivate, OnModuleDestroy
{
  private readonly redis: Redis;
  private readonly limit = Number(process.env.API_RATE_LIMIT ?? 100);
  private readonly windowMs = Number(process.env.API_RATE_WINDOW_MS ?? 60_000);
  private readonly loginAccountLimit = Number(
    process.env.LOGIN_ACCOUNT_RATE_LIMIT ?? 10,
  );
  private readonly loginAccountWindowMs = Number(
    process.env.LOGIN_ACCOUNT_RATE_WINDOW_MS ?? 900_000,
  );
  private readonly mfaAttemptLimit = Number(process.env.MFA_ATTEMPT_RATE_LIMIT ?? 5);
  private readonly mfaAttemptWindowMs = Number(process.env.MFA_ATTEMPT_RATE_WINDOW_MS ?? 900_000);

  private static readonly incrementScript = `
    local count = redis.call('INCR', KEYS[1])
    if count == 1 then
      redis.call('PEXPIRE', KEYS[1], ARGV[1])
    end
    local ttl = redis.call('PTTL', KEYS[1])
    return { count, ttl }
  `;

  constructor() {
    this.redis = new Redis(process.env.REDIS_URL ?? 'redis://127.0.0.1:6379', {
      lazyConnect: true,
      connectTimeout: 1000,
      maxRetriesPerRequest: 1,
      enableOfflineQueue: false,
      retryStrategy: (attempt) => Math.min(attempt * 250, 2000),
    });
    this.redis.on('error', () => undefined);
  }

  private getClientIp(req: Record<string, any>): string {
    const configuredSecret = process.env.EDGE_SHARED_SECRET;
    const suppliedSecret = req.headers?.['x-breezze-edge-secret'];
    const clientIp = req.headers?.['cf-connecting-ip'];
    const expected = Buffer.from(configuredSecret ?? '');
    const supplied = Buffer.from(
      typeof suppliedSecret === 'string' ? suppliedSecret : '',
    );
    const authenticatedEdge =
      expected.length >= 32 &&
      supplied.length === expected.length &&
      timingSafeEqual(supplied, expected);

    if (
      authenticatedEdge &&
      typeof clientIp === 'string' &&
      isIP(clientIp) !== 0
    ) return clientIp;

    const directIp = req.ip ?? req.socket?.remoteAddress;
    return typeof directIp === 'string' && isIP(directIp) !== 0
      ? directIp
      : 'unknown';
  }

  private async increment(key: string, ttlMs: number): Promise<[number, number]> {
    const result = (await this.redis.eval(
      CloudflareAwareThrottlerGuard.incrementScript,
      1,
      key,
      String(ttlMs * 2),
    )) as [number | string, number | string];
    return [Number(result[0]), Math.max(1, Number(result[1]))];
  }

  private reject(retryMs: number, res: { setHeader: (name: string, value: string) => void }) {
    res.setHeader('Retry-After', String(Math.ceil(retryMs / 1000)));
    throw new HttpException(
      {
        statusCode: 429,
        error: 'RATE_LIMIT_EXCEEDED',
        message: 'Too many requests. Please retry after the window resets.',
      },
      429,
    );
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const http = context.switchToHttp();
    const req = http.getRequest<Record<string, any>>();
    const res = http.getResponse<{ setHeader: (name: string, value: string) => void }>();

    try {
      if (this.redis.status === 'wait') await this.redis.connect();

      const ipDigest = createHash('sha256')
        .update(this.getClientIp(req))
        .digest('hex');
      const windowBucket = Math.floor(Date.now() / this.windowMs);
      const [ipCount, ipTtl] = await this.increment(
        `breezze:ratelimit:v1:ip:${ipDigest}:${windowBucket}`,
        this.windowMs,
      );
      if (ipCount > this.limit) this.reject(ipTtl, res);

      const path = String(req.originalUrl ?? req.url ?? '').split('?')[0];

      // MFA code endpoints get a stricter per-source quota to slow online TOTP guessing.
      if (
        req.method === 'POST' &&
        (path.endsWith('/auth/mfa/verify') || path.endsWith('/auth/mfa/setup/verify') || path.endsWith('/auth/mfa/recovery-codes/regenerate'))
      ) {
        const mfaBucket = Math.floor(Date.now() / this.mfaAttemptWindowMs);
        const [mfaCount, mfaTtl] = await this.increment(
          'breezze:ratelimit:v1:mfa:' + ipDigest + ':' + mfaBucket,
          this.mfaAttemptWindowMs,
        );
        if (mfaCount > this.mfaAttemptLimit) this.reject(mfaTtl, res);
      }

      // Add a second independent bucket for login attempts against one account.
      // Hash the normalized identifier so Redis keys never contain email addresses.
      const email = req.body?.email;
      if (
        req.method === 'POST' &&
        (path.endsWith('/auth/supabase/claim')) &&
        typeof email === 'string' &&
        email.trim().length > 0
      ) {
        const accountDigest = createHash('sha256')
          .update(email.trim().toLowerCase())
          .digest('hex');
        const accountBucket = Math.floor(
          Date.now() / this.loginAccountWindowMs,
        );
        const [accountCount, accountTtl] = await this.increment(
          `breezze:ratelimit:v1:login-account:${accountDigest}:${accountBucket}`,
          this.loginAccountWindowMs,
        );
        if (accountCount > this.loginAccountLimit) this.reject(accountTtl, res);
      }

      return true;
    } catch (error) {
      if (error instanceof HttpException) throw error;
      if (process.env.NODE_ENV !== 'production') return true;
      throw new ServiceUnavailableException(
        'Request protection is temporarily unavailable',
      );
    }
  }

  async onModuleDestroy(): Promise<void> {
    if (this.redis.status === 'ready') await this.redis.quit();
    else this.redis.disconnect();
  }
}
