import { UnauthorizedException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import * as argon2 from 'argon2';
import { JwtService } from '@nestjs/jwt';
import { PrismaService } from '../prisma.service';
import { AuthService } from './auth.service';

describe('AuthService refresh-token rotation', () => {
  let service: AuthService;
  let prisma: any;
  let jwt: Pick<JwtService, 'signAsync'>;
  let transactionRefreshToken: {
    updateMany: jest.Mock;
    create: jest.Mock;
  };

  const user = {
    id: 'user-1',
    email: 'listener@example.com',
    displayName: 'Listener',
  };

  const activeToken = () => ({
    id: 'refresh-1',
    familyId: 'family-1',
    userId: user.id,
    revokedAt: null,
    expiresAt: new Date(Date.now() + 60_000),
    user,
    mfaVerified: false,
  });

  beforeEach(() => {
    transactionRefreshToken = {
      updateMany: jest.fn().mockResolvedValue({ count: 1 }),
      create: jest.fn().mockResolvedValue({ id: 'refresh-2' }),
    };
    prisma = {
      user: {
        findUnique: jest.fn(),
        updateMany: jest.fn().mockResolvedValue({ count: 1 }),
      },
      refreshToken: {
        findUnique: jest.fn(),
        findFirst: jest.fn(),
        updateMany: jest.fn().mockResolvedValue({ count: 1 }),
        findMany: jest.fn(),
      },
      $transaction: jest.fn((callback: (tx: any) => unknown) =>
        callback({ refreshToken: transactionRefreshToken, user: prisma.user }),
      ),
    };
    jwt = { signAsync: jest.fn().mockResolvedValue('new-access-token') };
    service = new AuthService(prisma as PrismaService, jwt as JwtService);
  });

  it('stores only a SHA-256 hash and rotates within the same token family', async () => {
    prisma.refreshToken.findUnique.mockResolvedValue(activeToken());
    const result = await service.refresh('presented-refresh-token');

    const expectedLookupHash = createHash('sha256')
      .update('presented-refresh-token', 'utf8')
      .digest('hex');
    expect(prisma.refreshToken.findUnique).toHaveBeenCalledWith({
      where: { tokenHash: expectedLookupHash },
      include: { user: true },
    });

    const created = transactionRefreshToken.create.mock.calls[0][0].data;
    expect(created.tokenHash).toMatch(/^[a-f0-9]{64}$/);
    expect(created.tokenHash).not.toBe(result.refreshToken);
    expect(created.tokenHash).toBe(
      createHash('sha256').update(result.refreshToken, 'utf8').digest('hex'),
    );
    expect(created.familyId).toBe('family-1');
    expect(jwt.signAsync).toHaveBeenCalledWith(
      { sub: user.id, email: user.email, sid: 'family-1', mfaVerified: false },
      { expiresIn: '15m' },
    );
    expect(transactionRefreshToken.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { id: 'refresh-1', revokedAt: null },
      }),
    );
  });

  it('revokes the remaining family when a revoked token is replayed', async () => {
    prisma.refreshToken.findUnique.mockResolvedValue({
      ...activeToken(),
      revokedAt: new Date(),
    });

    await expect(service.refresh('replayed-token')).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
    expect(prisma.refreshToken.updateMany).toHaveBeenCalledWith({
      where: { familyId: 'family-1', revokedAt: null },
      data: { revokedAt: expect.any(Date) },
    });
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('does not issue a replacement when concurrent rotation already consumed the token', async () => {
    prisma.refreshToken.findUnique.mockResolvedValue(activeToken());
    transactionRefreshToken.updateMany
      .mockResolvedValueOnce({ count: 0 })
      .mockResolvedValueOnce({ count: 1 });

    await expect(service.refresh('racing-token')).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
    expect(transactionRefreshToken.create).not.toHaveBeenCalled();
    expect(transactionRefreshToken.updateMany).toHaveBeenLastCalledWith({
      where: { familyId: 'family-1', revokedAt: null },
      data: { revokedAt: expect.any(Date) },
    });
  });
  it('revokes every refresh token in the selected session family', async () => {
    prisma.refreshToken.findFirst.mockResolvedValue({ familyId: 'family-1' });

    await service.revokeSession('user-1', 'session-owned-by-user-1');

    expect(prisma.refreshToken.findFirst).toHaveBeenCalledWith({
      where: { id: 'session-owned-by-user-1', userId: 'user-1', revokedAt: null },
      select: { familyId: true },
    });
    expect(prisma.refreshToken.updateMany).toHaveBeenCalledWith({
      where: { familyId: 'family-1', userId: 'user-1', revokedAt: null },
      data: { revokedAt: expect.any(Date) },
    });
  });

  it('does not revoke a session owned by another account', async () => {
    prisma.refreshToken.findFirst.mockResolvedValue(null);
    await expect(service.revokeSession('user-1', 'foreign-session'))
      .rejects.toThrow('SESSION_NOT_FOUND');
    expect(prisma.refreshToken.updateMany).not.toHaveBeenCalled();
  });

  it('revokes all active sessions for the requesting user without touching other accounts', async () => {
    await service.revokeAllSessions('user-1');
    expect(prisma.refreshToken.updateMany).toHaveBeenCalledWith({
      where: { userId: 'user-1', revokedAt: null },
      data: { revokedAt: expect.any(Date) },
    });
  });

  it('changes a password using Argon2id and revokes every session for the account', async () => {
    const oldHash = await argon2.hash('old-password-strong', {
      type: argon2.argon2id, memoryCost: 4096, timeCost: 2, parallelism: 1,
    });
    prisma.user.findUnique.mockResolvedValue({ passwordHash: oldHash });
    await service.changePassword('user-1', 'old-password-strong', 'new-password-strong');
    expect(prisma.user.updateMany).toHaveBeenCalledWith({
      where: { id: 'user-1', passwordHash: oldHash },
      data: { passwordHash: expect.any(String) },
    });
    const storedHash = prisma.user.updateMany.mock.calls[0][0].data.passwordHash;
    expect(storedHash).toContain('$argon2id$');
    expect(await argon2.verify(storedHash, 'new-password-strong')).toBe(true);
    expect(transactionRefreshToken.updateMany).toHaveBeenCalledWith({
      where: { userId: 'user-1', revokedAt: null },
      data: { revokedAt: expect.any(Date) },
    });
  });

  it('rejects an incorrect current password without changing the account', async () => {
    const oldHash = await argon2.hash('old-password-strong', {
      type: argon2.argon2id, memoryCost: 4096, timeCost: 2, parallelism: 1,
    });
    prisma.user.findUnique.mockResolvedValue({ passwordHash: oldHash });
    await expect(service.changePassword('user-1', 'bad-password', 'new-password-strong'))
      .rejects.toBeInstanceOf(UnauthorizedException);
    expect(prisma.user.updateMany).not.toHaveBeenCalled();
    expect(transactionRefreshToken.updateMany).not.toHaveBeenCalled();
  });

  it('prevents simultaneous stale-password changes', async () => {
    const oldHash = await argon2.hash('old-password-strong', {
      type: argon2.argon2id, memoryCost: 4096, timeCost: 2, parallelism: 1,
    });
    prisma.user.findUnique.mockResolvedValue({ passwordHash: oldHash });
    prisma.user.updateMany.mockResolvedValue({ count: 0 });
    await expect(service.changePassword('user-1', 'old-password-strong', 'new-password-strong'))
      .rejects.toBeInstanceOf(UnauthorizedException);
    expect(transactionRefreshToken.updateMany).not.toHaveBeenCalled();
  });

  it('revokes the complete family when logging out', async () => {
    prisma.refreshToken.findUnique.mockResolvedValue({
      familyId: 'family-1',
      userId: 'user-1',
    });

    await service.logout('logout-refresh-token');

    expect(prisma.refreshToken.updateMany).toHaveBeenCalledWith({
      where: { familyId: 'family-1', userId: 'user-1', revokedAt: null },
      data: { revokedAt: expect.any(Date) },
    });
  });

});
