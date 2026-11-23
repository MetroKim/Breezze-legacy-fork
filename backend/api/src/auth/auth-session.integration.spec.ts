import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { PrismaClient } from '@prisma/client';
import * as argon2 from 'argon2';
import { AuthService } from './auth.service';
import { PrismaService } from '../prisma.service';

const databaseUrl = process.env.INTEGRATION_DATABASE_URL;
const describeIntegration = databaseUrl ? describe : describe.skip;
const prisma = new PrismaClient(
  databaseUrl ? { datasources: { db: { url: databaseUrl } } } : undefined,
);

describeIntegration('Auth session PostgreSQL integration', () => {
  const userIds: string[] = [];
  let service: AuthService;

  beforeAll(async () => {
    await prisma.$connect();
    service = new AuthService(
      prisma as unknown as PrismaService,
      { signAsync: jest.fn().mockResolvedValue('integration-access-token') } as never,
    );
  });

  afterAll(async () => {
    if (userIds.length) {
      await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    }
    await prisma.$disconnect();
  });

  async function createUser() {
    const user = await prisma.user.create({
      data: {
        email: `auth-session-${randomUUID()}@integration.invalid`,
        passwordHash: 'integration-only-not-a-real-password',
      },
      select: { id: true, email: true, displayName: true },
    });
    userIds.push(user.id);
    return user;
  }

  async function createRefreshToken(userId: string, familyId: string, rawToken = randomBytes(32).toString('hex')) {
    await prisma.refreshToken.create({
      data: {
        tokenHash: createHash('sha256').update(rawToken, 'utf8').digest('hex'),
        familyId,
        userId,
        expiresAt: new Date(Date.now() + 60_000),
      },
    });
    return rawToken;
  }

  it('rotates a refresh token once and revokes the family on concurrent replay', async () => {
    const user = await createUser();
    const familyId = randomUUID();
    const rawToken = await createRefreshToken(user.id, familyId);

    const attempts = await Promise.allSettled([
      service.refresh(rawToken),
      service.refresh(rawToken),
    ]);

    expect(attempts.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
    expect(attempts.filter((result) => result.status === 'rejected')).toHaveLength(1);

    const family = await prisma.refreshToken.findMany({
      where: { familyId, userId: user.id },
    });
    expect(family.length).toBeGreaterThanOrEqual(1);
    expect(family.every((token) => token.revokedAt !== null)).toBe(true);
    expect(family.some((token) => token.tokenHash === createHash('sha256').update(rawToken, 'utf8').digest('hex'))).toBe(true);
    expect(family.every((token) => token.tokenHash !== rawToken)).toBe(true);
  });

  it('revokes only the selected user-owned session family', async () => {
    const user = await createUser();
    const selectedFamily = randomUUID();
    const otherFamily = randomUUID();
    await createRefreshToken(user.id, selectedFamily);
    await createRefreshToken(user.id, selectedFamily);
    await createRefreshToken(user.id, otherFamily);

    const selectedSession = await prisma.refreshToken.findFirstOrThrow({
      where: { userId: user.id, familyId: selectedFamily },
      select: { id: true },
    });
    await service.revokeSession(user.id, selectedSession.id);

    const rows = await prisma.refreshToken.findMany({ where: { userId: user.id } });
    expect(rows.filter((row) => row.familyId === selectedFamily).every((row) => row.revokedAt !== null)).toBe(true);
    expect(rows.filter((row) => row.familyId === otherFamily).every((row) => row.revokedAt === null)).toBe(true);
  });

  it('does not let one account revoke another account session', async () => {
    const owner = await createUser();
    const attacker = await createUser();
    const familyId = randomUUID();
    const token = await createRefreshToken(owner.id, familyId);
    const session = await prisma.refreshToken.findFirstOrThrow({
      where: { userId: owner.id, familyId },
      select: { id: true },
    });

    await expect(service.revokeSession(attacker.id, session.id)).rejects.toThrow('SESSION_NOT_FOUND');
    const stored = await prisma.refreshToken.findUniqueOrThrow({
      where: { tokenHash: createHash('sha256').update(token, 'utf8').digest('hex') },
    });
    expect(stored.revokedAt).toBeNull();
  });
  it('signs out every device for one account while keeping other users active', async () => {
    const owner = await createUser();
    const other = await createUser();
    const familyA = randomUUID();
    const familyB = randomUUID();
    const foreignFamily = randomUUID();
    await createRefreshToken(owner.id, familyA);
    await createRefreshToken(owner.id, familyB);
    await createRefreshToken(other.id, foreignFamily);

    await service.revokeAllSessions(owner.id);

    const ownerTokens = await prisma.refreshToken.findMany({ where: { userId: owner.id } });
    const otherTokens = await prisma.refreshToken.findMany({ where: { userId: other.id } });
    expect(ownerTokens).toHaveLength(2);
    expect(ownerTokens.every((row) => row.revokedAt !== null)).toBe(true);
    expect(otherTokens).toHaveLength(1);
    expect(otherTokens.every((row) => row.revokedAt === null)).toBe(true);
  });


  it('changes a password transactionally and revokes only the owner sessions', async () => {
    const owner = await createUser();
    const other = await createUser();
    const oldPassword = 'integration-old-password';
    const newPassword = 'integration-new-password';
    const oldHash = await argon2.hash(oldPassword, {
      type: argon2.argon2id, memoryCost: 4096, timeCost: 2, parallelism: 1,
    });
    await prisma.user.update({ where: { id: owner.id }, data: { passwordHash: oldHash } });
    await createRefreshToken(owner.id, randomUUID());
    await createRefreshToken(owner.id, randomUUID());
    await createRefreshToken(other.id, randomUUID());

    await service.changePassword(owner.id, oldPassword, newPassword);

    const changed = await prisma.user.findUniqueOrThrow({ where: { id: owner.id } });
    expect(changed.passwordHash).not.toBe(oldHash);
    expect(await argon2.verify(changed.passwordHash, oldPassword)).toBe(false);
    expect(await argon2.verify(changed.passwordHash, newPassword)).toBe(true);
    const ownerSessions = await prisma.refreshToken.findMany({ where: { userId: owner.id } });
    const otherSessions = await prisma.refreshToken.findMany({ where: { userId: other.id } });
    expect(ownerSessions).toHaveLength(2);
    expect(ownerSessions.every((token) => token.revokedAt !== null)).toBe(true);
    expect(otherSessions).toHaveLength(1);
    expect(otherSessions.every((token) => token.revokedAt === null)).toBe(true);
  });

});
