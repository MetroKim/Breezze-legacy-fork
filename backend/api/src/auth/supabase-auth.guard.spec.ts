import { ConflictException, ExecutionContext, UnauthorizedException } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { JwtAuthGuard } from './jwt-auth.guard';

describe('Supabase JWT API guard', () => {
  const uid = 'a2c4708e-3271-47a3-a2f1-b4c8be8e8afa';
  const baseUser = {
    id: uid, email: 'listener@example.com',
    role: 'user', mfaEnabled: false,
  };
  const prisma = {
    user: {
      findUnique: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
    },
  };
  let oldFetch: typeof globalThis.fetch;

  const ctx = (authorization?: string) => {
    const request: { headers: { authorization?: string }; user?: unknown } = {
      headers: { authorization },
    };
    const context = {
      switchToHttp: () => ({ getRequest: () => request }),
    } as unknown as ExecutionContext;
    return { context, request };
  };

  beforeEach(() => {
    oldFetch = globalThis.fetch;
    jest.clearAllMocks();
  });

  afterEach(() => {
    globalThis.fetch = oldFetch;
  });

  it('rejects a missing session before touching the data store', async () => {
    const guard = new JwtAuthGuard(prisma as unknown as PrismaService);
    await expect(guard.canActivate(ctx().context))
      .rejects.toBeInstanceOf(UnauthorizedException);
    expect(prisma.user.findUnique).not.toHaveBeenCalled();
  });

  it('rejects a provider-denied bearer token', async () => {
    globalThis.fetch = jest.fn().mockResolvedValue(new Response('', { status: 401 }));
    const guard = new JwtAuthGuard(prisma as unknown as PrismaService);
    await expect(guard.canActivate(ctx('Bearer invalid-token').context))
      .rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('authorizes the verified provider user, not a client-supplied id', async () => {
    globalThis.fetch = jest.fn().mockResolvedValue(
      Response.json({
        id: uid, email: baseUser.email, email_confirmed_at: '2026-11-23T10:00:00Z',
      }),
    );
    prisma.user.findUnique.mockResolvedValue(baseUser);
    const { context, request } = ctx('Bearer valid-supabase-token');
    const guard = new JwtAuthGuard(prisma as unknown as PrismaService);
    await expect(guard.canActivate(context)).resolves.toBe(true);
    expect(request.user).toMatchObject({
      id: uid, email: baseUser.email, role: 'user', mfaVerified: false,
    });
    expect(prisma.user.create).not.toHaveBeenCalled();
  });

  it('will not merge an unlinked legacy account on matching email', async () => {
    globalThis.fetch = jest.fn().mockResolvedValue(
      Response.json({
        id: uid, email: baseUser.email, email_confirmed_at: '2026-11-23T10:00:00Z',
      }),
    );
    prisma.user.findUnique
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce({ ...baseUser, id: 'existing-breezze-uuid' });
    const guard = new JwtAuthGuard(prisma as unknown as PrismaService);
    await expect(guard.canActivate(ctx('Bearer valid-token').context))
      .rejects.toBeInstanceOf(ConflictException);
    expect(prisma.user.create).not.toHaveBeenCalled();
  });
});
