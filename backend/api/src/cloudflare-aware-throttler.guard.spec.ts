import { HttpException, ServiceUnavailableException } from '@nestjs/common';
import { CloudflareAwareThrottlerGuard } from './cloudflare-aware-throttler.guard';

describe('CloudflareAwareThrottlerGuard', () => {
  let guard: CloudflareAwareThrottlerGuard;
  let redis: {
    status: string;
    eval: jest.Mock;
    quit: jest.Mock;
    disconnect: jest.Mock;
  };
  let response: { setHeader: jest.Mock };

  const context = (ip = '127.0.0.1', body: Record<string, unknown> = {}, url = '/api/v1/catalog') => ({
    switchToHttp: () => ({
      getRequest: () => ({ ip, body, method: 'POST', originalUrl: url, headers: {}, socket: {} }),
      getResponse: () => response,
    }),
  }) as any;

  beforeEach(() => {
    process.env.NODE_ENV = 'test';
    process.env.API_RATE_LIMIT = '1';
    process.env.API_RATE_WINDOW_MS = '60000';
    process.env.LOGIN_ACCOUNT_RATE_LIMIT = '1';
    process.env.LOGIN_ACCOUNT_RATE_WINDOW_MS = '900000';
    guard = new CloudflareAwareThrottlerGuard();
    redis = {
      status: 'ready',
      eval: jest.fn(),
      quit: jest.fn().mockResolvedValue('OK'),
      disconnect: jest.fn(),
    };
    (guard as any).redis = redis;
    response = { setHeader: jest.fn() };
  });

  afterEach(async () => {
    await guard.onModuleDestroy();
    delete process.env.API_RATE_LIMIT;
    delete process.env.API_RATE_WINDOW_MS;
    delete process.env.LOGIN_ACCOUNT_RATE_LIMIT;
    delete process.env.LOGIN_ACCOUNT_RATE_WINDOW_MS;
    delete process.env.NODE_ENV;
  });

  it('allows a request while its shared Redis counter is within quota', async () => {
    redis.eval.mockResolvedValue([1, 60000]);

    await expect(guard.canActivate(context())).resolves.toBe(true);
    expect(redis.eval).toHaveBeenCalledTimes(1);
  });

  it('rejects requests above quota and returns Retry-After', async () => {
    redis.eval.mockResolvedValue([2, 59001]);

    await expect(guard.canActivate(context())).rejects.toBeInstanceOf(HttpException);
    expect(response.setHeader).toHaveBeenCalledWith('Retry-After', '60');
  });

  it('applies a separate hashed account quota to legacy Supabase claims', async () => {
    process.env.API_RATE_LIMIT = '100';
    process.env.LOGIN_ACCOUNT_RATE_LIMIT = '1';
    redis.eval.mockResolvedValueOnce([1, 60000]).mockResolvedValueOnce([2, 899000]);

    await expect(guard.canActivate(context('127.0.0.1', { email: 'Person@Example.com' }, '/api/v1/auth/supabase/claim')))
      .rejects.toBeInstanceOf(HttpException);
    const accountKey = redis.eval.mock.calls[1][2] as string;
    expect(accountKey).toContain('login-account:');
    expect(accountKey).not.toContain('Person@Example.com');
    expect(response.setHeader).toHaveBeenCalledWith('Retry-After', '899');
  });


  it('shares legacy-claim quota across different source IPs', async () => {
    process.env.API_RATE_LIMIT = '100';
    process.env.LOGIN_ACCOUNT_RATE_LIMIT = '100';
    redis.eval.mockResolvedValue([1, 60000]);

    const email = 'target@example.com';
    await expect(guard.canActivate(context(
      '192.0.2.10',
      { email },
      '/api/v1/auth/supabase/claim',
    ))).resolves.toBe(true);
    await expect(guard.canActivate(context(
      '198.51.100.20',
      { email: 'TARGET@example.com' },
      '/api/v1/auth/supabase/claim',
    ))).resolves.toBe(true);

    const firstAccountKey = redis.eval.mock.calls[1][2] as string;
    const secondAccountKey = redis.eval.mock.calls[3][2] as string;
    expect(firstAccountKey).toBe(secondAccountKey);
    expect(firstAccountKey).not.toContain(email);
  });

  it('applies a strict shared Redis quota to MFA code verification', async () => {
    process.env.API_RATE_LIMIT = '100';
    (guard as any).mfaAttemptLimit = 1;
    redis.eval.mockResolvedValueOnce([1, 60000]).mockResolvedValueOnce([2, 899000]);

    await expect(guard.canActivate(context(
      '127.0.0.1',
      { code: '123456' },
      '/api/v1/auth/mfa/verify',
    ))).rejects.toBeInstanceOf(HttpException);

    expect(redis.eval).toHaveBeenCalledTimes(2);
    expect(String(redis.eval.mock.calls[1][2])).toContain(':mfa:');
    expect(response.setHeader).toHaveBeenCalledWith('Retry-After', '899');
  });

  it('applies the strict MFA quota to recovery code regeneration', async () => {
    process.env.API_RATE_LIMIT = '100';
    (guard as any).mfaAttemptLimit = 1;
    redis.eval.mockResolvedValueOnce([1, 60000]).mockResolvedValueOnce([2, 899000]);

    await expect(guard.canActivate(context(
      '127.0.0.1',
      { password: 'not-logged', code: '123456' },
      '/api/v1/auth/mfa/recovery-codes/regenerate',
    ))).rejects.toBeInstanceOf(HttpException);

    expect(redis.eval).toHaveBeenCalledTimes(2);
    expect(String(redis.eval.mock.calls[1][2])).toContain(':mfa:');
  });

  it('fails closed in production when Redis is unavailable', async () => {
    process.env.NODE_ENV = 'production';
    redis.eval.mockRejectedValue(new Error('redis unavailable'));

    await expect(guard.canActivate(context())).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );
  });

  it('fails open in local development when Redis is unavailable', async () => {
    redis.eval.mockRejectedValue(new Error('redis unavailable'));

    await expect(guard.canActivate(context())).resolves.toBe(true);
  });
});
