import {
  ConflictException,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { AuthService } from './auth.service';
import { SupabaseAuthBridge } from './supabase-auth.bridge';

const token = `${'a'.repeat(50)}.${'b'.repeat(60)}.${'c'.repeat(70)}`;
const supabaseUser = {
  id: '123e4567-e89b-42d3-a456-426614174000',
  email: 'listener@example.test',
  email_confirmed_at: '2026-11-23T00:00:00Z',
};

describe('SupabaseAuthBridge (private NestJS identity exchange)', () => {
  const oldUrl = process.env.SUPABASE_URL;
  const oldKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  let prisma: any;
  let auth: any;
  let bridge: SupabaseAuthBridge;
  let fetchSpy: jest.SpyInstance;

  beforeEach(() => {
    process.env.SUPABASE_URL = 'https://breezzetest.supabase.co';
    process.env.SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_test-only';
    prisma = {
      supabaseAuthIdentity: {
        findUnique: jest.fn().mockResolvedValue(null),
        create: jest.fn().mockResolvedValue({ userId: 'breezze-1' }),
      },
      user: {
        findFirst: jest.fn().mockResolvedValue(null),
        findUnique: jest.fn().mockResolvedValue({
          id: 'breezze-1', email: 'listener@example.test',
        }),
        create: jest.fn().mockResolvedValue({ id: 'breezze-1' }),
      },
    };
    auth = { issueVerifiedSocialSession: jest.fn().mockResolvedValue({
      accessToken: 'breezze-session', refreshToken: 'opaque-refresh',
      user: { id: 'breezze-1', email: 'listener@example.test' },
    }) };
    bridge = new SupabaseAuthBridge(prisma as PrismaService, auth as AuthService);
    fetchSpy = jest.spyOn(global, 'fetch').mockResolvedValue(
      new Response(JSON.stringify(supabaseUser), { status: 200 }),
    );
  });

  afterEach(() => {
    fetchSpy.mockRestore();
    if (oldUrl === undefined) delete process.env.SUPABASE_URL;
    else process.env.SUPABASE_URL = oldUrl;
    if (oldKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY;
    else process.env.SUPABASE_PUBLISHABLE_KEY = oldKey;
  });

  it('verifies a Supabase user via /auth/v1/user before issuing a Breezze session', async () => {
    await expect(bridge.exchange(token)).resolves.toMatchObject({
      accessToken: 'breezze-session',
    });
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, options] = fetchSpy.mock.calls[0];
    expect(url).toBe('https://breezzetest.supabase.co/auth/v1/user');
    expect(options.redirect).toBe('manual');
    expect(options.headers.apikey).toBe('sb_publishable_test-only');
    expect(options.headers.Authorization).toBe(`Bearer ${token}`);
    expect(prisma.user.create).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({
        email: 'listener@example.test',
        passwordHash: expect.stringMatching(/^!supabase-managed:/),
        supabaseIdentity: { create: { subject: supabaseUser.id } },
      }),
    }));
    expect(auth.issueVerifiedSocialSession).toHaveBeenCalledWith('breezze-1');
  });

  it('refuses unverified emails even if the provider returns a user ID', async () => {
    fetchSpy.mockResolvedValue(new Response(JSON.stringify({
      ...supabaseUser, email_confirmed_at: null,
    }), { status: 200 }));
    await expect(bridge.exchange(token)).rejects.toBeInstanceOf(UnauthorizedException);
    expect(prisma.user.create).not.toHaveBeenCalled();
  });

  it('never silently links a pre-existing account by matching email', async () => {
    prisma.user.findFirst.mockResolvedValue({ id: 'old-account' });
    await expect(bridge.exchange(token)).rejects.toBeInstanceOf(ConflictException);
    expect(prisma.supabaseAuthIdentity.create).not.toHaveBeenCalled();
    expect(prisma.user.create).not.toHaveBeenCalled();
  });

  it('reuses only a stored, explicitly linked Supabase subject', async () => {
    prisma.supabaseAuthIdentity.findUnique.mockResolvedValue({ userId: 'owner-1' });
    await bridge.exchange(token);
    expect(auth.issueVerifiedSocialSession).toHaveBeenCalledWith('owner-1');
    expect(prisma.user.findFirst).not.toHaveBeenCalled();
  });

  it('explicit linking requires the existing account and verified Supabase email to match', async () => {
    await expect(bridge.link('breezze-1', token)).resolves.toEqual({ linked: true });
    expect(prisma.supabaseAuthIdentity.create).toHaveBeenCalledWith({
      data: { userId: 'breezze-1', subject: supabaseUser.id },
    });
    prisma.user.findUnique.mockResolvedValue({ id: 'breezze-1', email: 'other@example.test' });
    await expect(bridge.link('breezze-1', token))
      .rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rejects linking a Supabase subject already owned by another listener', async () => {
    prisma.supabaseAuthIdentity.findUnique.mockResolvedValue({ userId: 'other-account' });
    await expect(bridge.link('breezze-1', token))
      .rejects.toBeInstanceOf(ConflictException);
  });

  it('fails closed when Supabase rejects a user token', async () => {
    fetchSpy.mockResolvedValue(new Response('{}', { status: 401 }));
    await expect(bridge.exchange(token)).rejects.toBeInstanceOf(UnauthorizedException);
    expect(auth.issueVerifiedSocialSession).not.toHaveBeenCalled();
  });

  it('never falls back to an untrusted host, missing project, or broken provider', async () => {
    process.env.SUPABASE_URL = 'https://attacker.example';
    await expect(bridge.exchange(token)).rejects.toBeInstanceOf(ServiceUnavailableException);
    process.env.SUPABASE_URL = 'https://breezzetest.supabase.co';
    delete process.env.SUPABASE_PUBLISHABLE_KEY;
    await expect(bridge.exchange(token)).rejects.toBeInstanceOf(ServiceUnavailableException);
    process.env.SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_test-only';
    fetchSpy.mockRejectedValue(new Error('network offline'));
    await expect(bridge.exchange(token)).rejects.toBeInstanceOf(ServiceUnavailableException);
  });
});
