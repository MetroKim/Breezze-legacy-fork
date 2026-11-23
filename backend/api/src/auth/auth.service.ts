import {
  Injectable,
  UnauthorizedException,
  ForbiddenException,
  ConflictException,
  NotFoundException,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import * as argon2 from 'argon2';
import { createHash, randomBytes, randomUUID } from 'crypto';
import { PrismaService } from '../prisma.service';
import {
  decryptTotpSecret,
  encryptTotpSecret,
  generateTotpSecret,
  totpProvisioningUri,
  getVerifiedTotpCounter,
  generateRecoveryCodes,
  hashRecoveryCode,
} from './totp';

export interface AuthResult {
  accessToken: string;
  refreshToken: string;
  mfaRequired?: boolean;
  mfaSetupRequired?: boolean;
  user: { id: string; email: string; displayName: string | null };
}

type AuthUser = {
  id: string;
  email: string;
  displayName: string | null;
  role?: string;
  mfaEnabled?: boolean;
};

@Injectable()
export class AuthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
  ) {}

  private normalizeEmail(email: string): string {
    return email.trim().toLowerCase();
  }

  private hashRefreshToken(token: string): string {
    return createHash('sha256').update(token, 'utf8').digest('hex');
  }

  private refreshExpiry(): Date {
    return new Date(Date.now() + 30 * 24 * 3600 * 1000);
  }

  private async issueTokens(
    user: AuthUser,
    refreshOverride?: string,
    existingFamilyId?: string,
    mfaVerified = false,
  ): Promise<AuthResult> {
    const familyId = existingFamilyId ?? randomUUID();
    const accessToken = await this.jwt.signAsync(
      { sub: user.id, email: user.email, sid: familyId, mfaVerified },
      { expiresIn: '15m' },
    );
    const refreshToken = refreshOverride ?? randomBytes(32).toString('hex');
    if (!refreshOverride) {
      await this.prisma.refreshToken.create({
        data: {
          tokenHash: this.hashRefreshToken(refreshToken),
          familyId,
          userId: user.id,
          expiresAt: this.refreshExpiry(),
          mfaVerified,
        },
      });
    }
    const mfaSetupRequired = user.role === 'admin' && user.mfaEnabled !== true;
    const mfaRequired = user.role === 'admin' && (user.mfaEnabled !== true || !mfaVerified);
    return {
      accessToken,
      refreshToken,
      ...(mfaRequired ? { mfaRequired: true } : {}),
      ...(mfaSetupRequired ? { mfaSetupRequired: true } : {}),
      user: { id: user.id, email: user.email, displayName: user.displayName },
    };
  }

  /// Called only after SocialAuthService verifies a provider-signed ID token
  /// and resolves its unique provider subject to an existing or new user.
  async issueVerifiedSocialSession(userId: string): Promise<AuthResult> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: {
        id: true, email: true, displayName: true,
        role: true, mfaEnabled: true,
      },
    });
    if (!user) throw new UnauthorizedException('SOCIAL_USER_MISSING');
    // Never bypass the administrator MFA security boundary.
    return this.issueTokens(user);
  }

  async register(
    email: string,
    password: string,
    displayName?: string,
  ): Promise<AuthResult> {
    const normalizedEmail = this.normalizeEmail(email);
    const exists = await this.prisma.user.findFirst({
      where: { email: { equals: normalizedEmail, mode: 'insensitive' } },
      select: { id: true },
    });
    if (exists) throw new ConflictException('EMAIL_TAKEN');

    const passwordHash = await argon2.hash(password, {
      type: argon2.argon2id,
      memoryCost: 19456,
      timeCost: 2,
      parallelism: 1,
    });
    let user: AuthUser;
    try {
      user = await this.prisma.user.create({
        data: { email: normalizedEmail, passwordHash, displayName: displayName ?? null },
      });
    } catch (error) {
      if (
        error &&
        typeof error === 'object' &&
        (error as { code?: string }).code === 'P2002'
      ) {
        throw new ConflictException('EMAIL_TAKEN');
      }
      throw error;
    }
    return this.issueTokens(user);
  }

  async login(email: string, password: string): Promise<AuthResult> {
    const normalizedEmail = this.normalizeEmail(email);
    const user = await this.prisma.user.findFirst({
      where: { email: { equals: normalizedEmail, mode: 'insensitive' } },
    });
    if (!user) throw new UnauthorizedException('INVALID_CREDENTIALS');

    const valid = await argon2
      .verify(user.passwordHash, password)
      .catch(() => false);
    if (!valid) throw new UnauthorizedException('INVALID_CREDENTIALS');
    return this.issueTokens(user);
  }

  async refresh(refreshToken: string): Promise<AuthResult> {
    const token = await this.prisma.refreshToken.findUnique({
      where: { tokenHash: this.hashRefreshToken(refreshToken) },
      include: { user: true },
    });

    if (!token || token.revokedAt !== null || token.expiresAt < new Date()) {
      if (token) {
        await this.prisma.refreshToken.updateMany({
          where: { familyId: token.familyId, revokedAt: null },
          data: { revokedAt: new Date() },
        });
      }
      throw new UnauthorizedException('REFRESH_REUSED_OR_INVALID');
    }

    const rotated = randomBytes(32).toString('hex');
    const consumed = await this.prisma.$transaction(async (tx) => {
      const result = await tx.refreshToken.updateMany({
        where: { id: token.id, revokedAt: null },
        data: { revokedAt: new Date() },
      });
      if (result.count !== 1) {
        await tx.refreshToken.updateMany({
          where: { familyId: token.familyId, revokedAt: null },
          data: { revokedAt: new Date() },
        });
        return false;
      }
      await tx.refreshToken.create({
        data: {
          tokenHash: this.hashRefreshToken(rotated),
          familyId: token.familyId,
          userId: token.userId,
          expiresAt: this.refreshExpiry(),
          mfaVerified: token.mfaVerified,
        },
      });
      return true;
    });
    if (!consumed) throw new UnauthorizedException('REFRESH_REUSED_OR_INVALID');

    return this.issueTokens(token.user, rotated, token.familyId, token.mfaVerified);
  }

  async beginMfaSetup(userId: string, password: string) {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, email: true, passwordHash: true, role: true, mfaEnabled: true },
    });
    if (!user) throw new NotFoundException('USER_NOT_FOUND');
    if (user.role !== 'admin') throw new ForbiddenException('ADMIN_MFA_ONLY');
    const passwordValid = await argon2.verify(user.passwordHash, password).catch(() => false);
    if (!passwordValid) throw new UnauthorizedException('INVALID_CREDENTIALS');
    if (user.mfaEnabled) throw new ConflictException('MFA_ALREADY_ENABLED');

    const secret = generateTotpSecret();
    await this.prisma.user.update({
      where: { id: userId },
      data: { mfaPendingSecretCiphertext: encryptTotpSecret(secret) },
    });
    return {
      secret,
      provisioningUri: totpProvisioningUri(secret, user.email),
      algorithm: 'SHA1',
      digits: 6,
      periodSeconds: 30,
    };
  }

  async verifyMfaSetup(userId: string, sessionId: string, code: string) {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, email: true, displayName: true, role: true, mfaEnabled: true, mfaPendingSecretCiphertext: true },
    });
    if (!user) throw new NotFoundException('USER_NOT_FOUND');
    if (user.role !== 'admin') throw new ForbiddenException('ADMIN_MFA_ONLY');
    if (user.mfaEnabled || !user.mfaPendingSecretCiphertext) {
      throw new ConflictException('MFA_SETUP_NOT_PENDING');
    }

    const secret = decryptTotpSecret(user.mfaPendingSecretCiphertext);
    const counter = getVerifiedTotpCounter(secret, code);
    if (counter === null) throw new UnauthorizedException('MFA_CODE_INVALID');
    const recoveryCodes = generateRecoveryCodes();

    await this.prisma.$transaction(async (tx) => {
      const accepted = await tx.user.updateMany({
        where: { id: userId, OR: [{ mfaLastUsedStep: null }, { mfaLastUsedStep: { lt: BigInt(counter) } }] },
        data: { mfaLastUsedStep: BigInt(counter) },
      });
      if (accepted.count === 0) throw new UnauthorizedException('MFA_CODE_REPLAYED');
      await tx.user.update({
        where: { id: userId },
        data: {
          mfaEnabled: true,
          mfaSecretCiphertext: user.mfaPendingSecretCiphertext,
          mfaPendingSecretCiphertext: null,
        },
      });
      await tx.mfaRecoveryCode.createMany({
        data: recoveryCodes.map((codeHash) => ({ userId, codeHash: hashRecoveryCode(codeHash) })),
      });
      const verified = await tx.refreshToken.updateMany({
        where: { userId, familyId: sessionId, revokedAt: null, expiresAt: { gt: new Date() } },
        data: { mfaVerified: true },
      });
      if (verified.count === 0) throw new UnauthorizedException('SESSION_INVALID');
      if (user.role === 'admin') {
        await tx.adminAuditEvent.create({
          data: {
            actorId: userId,
            action: 'admin.mfa.enabled',
            targetType: 'user',
            targetId: userId,
            metadata: { method: 'totp' },
          },
        });
      }
    });

    const accessToken = await this.jwt.signAsync(
      { sub: user.id, email: user.email, sid: sessionId, mfaVerified: true },
      { expiresIn: '15m' },
    );
    return { verified: true, accessToken, recoveryCodes };
  }

  async verifyMfa(userId: string, sessionId: string, code: string) {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, email: true, role: true, mfaEnabled: true, mfaSecretCiphertext: true },
    });
    if (!user) throw new NotFoundException('USER_NOT_FOUND');
    if (user.role !== 'admin') throw new ForbiddenException('ADMIN_MFA_ONLY');
    if (!user.mfaEnabled || !user.mfaSecretCiphertext) {
      throw new UnauthorizedException('MFA_NOT_CONFIGURED');
    }
    const counter = getVerifiedTotpCounter(decryptTotpSecret(user.mfaSecretCiphertext), code);
    const method = counter === null ? 'recovery_code' : 'totp';

    await this.prisma.$transaction(async (tx) => {
      if (counter !== null) {
        const accepted = await tx.user.updateMany({
          where: { id: userId, OR: [{ mfaLastUsedStep: null }, { mfaLastUsedStep: { lt: BigInt(counter) } }] },
          data: { mfaLastUsedStep: BigInt(counter) },
        });
        if (accepted.count === 0) throw new UnauthorizedException('MFA_CODE_REPLAYED');
      } else {
        if (!/^[A-Fa-f0-9]{4}(?:-?[A-Fa-f0-9]{4}){3}$/.test(code)) {
          throw new UnauthorizedException('MFA_CODE_INVALID');
        }
        const recovery = await tx.mfaRecoveryCode.findFirst({
          where: { userId, codeHash: hashRecoveryCode(code), consumedAt: null },
          select: { id: true },
        });
        if (!recovery) throw new UnauthorizedException('MFA_CODE_INVALID');
        const consumed = await tx.mfaRecoveryCode.updateMany({
          where: { id: recovery.id, userId, consumedAt: null },
          data: { consumedAt: new Date() },
        });
        if (consumed.count === 0) throw new UnauthorizedException('MFA_RECOVERY_CODE_USED');
      }
      const updated = await tx.refreshToken.updateMany({
        where: { userId, familyId: sessionId, revokedAt: null, expiresAt: { gt: new Date() } },
        data: { mfaVerified: true },
      });
      if (updated.count === 0) throw new UnauthorizedException('SESSION_INVALID');
      if (user.role === 'admin') {
        await tx.adminAuditEvent.create({
          data: {
            actorId: userId,
            action: 'admin.mfa.verified',
            targetType: 'user',
            targetId: userId,
            metadata: { method },
          },
        });
      }
    });

    const accessToken = await this.jwt.signAsync(
      { sub: user.id, email: user.email, sid: sessionId, mfaVerified: true },
      { expiresIn: '15m' },
    );
    return { verified: true, accessToken };
  }

  async regenerateMfaRecoveryCodes(userId: string, sessionId: string, password: string, code: string) {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, passwordHash: true, role: true, mfaEnabled: true, mfaSecretCiphertext: true },
    });
    if (!user) throw new NotFoundException('USER_NOT_FOUND');
    if (user.role !== 'admin') throw new ForbiddenException('ADMIN_MFA_ONLY');
    if (!user.mfaEnabled || !user.mfaSecretCiphertext) {
      throw new UnauthorizedException('MFA_NOT_CONFIGURED');
    }
    const passwordValid = await argon2.verify(user.passwordHash, password).catch(() => false);
    if (!passwordValid) throw new UnauthorizedException('INVALID_CREDENTIALS');

    const totpCounter = getVerifiedTotpCounter(decryptTotpSecret(user.mfaSecretCiphertext), code);
    const method = totpCounter === null ? 'recovery_code' : 'totp';
    if (totpCounter === null && !/^[A-Fa-f0-9]{4}(?:-?[A-Fa-f0-9]{4}){3}$/.test(code)) {
      throw new UnauthorizedException('MFA_CODE_INVALID');
    }
    const recoveryCodes = generateRecoveryCodes();
    const now = new Date();

    await this.prisma.$transaction(async (tx) => {
      const session = await tx.refreshToken.findFirst({
        where: {
          userId,
          familyId: sessionId,
          revokedAt: null,
          expiresAt: { gt: now },
          mfaVerified: true,
        },
        select: { id: true },
      });
      if (!session) throw new UnauthorizedException('SESSION_INVALID');

      if (totpCounter !== null) {
        const accepted = await tx.user.updateMany({
          where: { id: userId, OR: [{ mfaLastUsedStep: null }, { mfaLastUsedStep: { lt: BigInt(totpCounter) } }] },
          data: { mfaLastUsedStep: BigInt(totpCounter) },
        });
        if (accepted.count === 0) throw new UnauthorizedException('MFA_CODE_REPLAYED');
      } else {
        const existingCode = await tx.mfaRecoveryCode.findFirst({
          where: { userId, codeHash: hashRecoveryCode(code), consumedAt: null },
          select: { id: true },
        });
        if (!existingCode) throw new UnauthorizedException('MFA_CODE_INVALID');
        const consumed = await tx.mfaRecoveryCode.updateMany({
          where: { id: existingCode.id, userId, consumedAt: null },
          data: { consumedAt: now },
        });
        if (consumed.count !== 1) throw new UnauthorizedException('MFA_RECOVERY_CODE_USED');
      }

      await tx.mfaRecoveryCode.deleteMany({ where: { userId } });
      await tx.mfaRecoveryCode.createMany({
        data: recoveryCodes.map((recoveryCode) => ({
          userId,
          codeHash: hashRecoveryCode(recoveryCode),
        })),
      });
      await tx.adminAuditEvent.create({
        data: {
          actorId: userId,
          action: 'admin.mfa.recovery_codes.regenerated',
          targetType: 'user',
          targetId: userId,
          metadata: { method, codeCount: recoveryCodes.length },
        },
      });
    });

    return { regenerated: true, recoveryCodes };
  }


  async logout(refreshToken: string): Promise<void> {
    const token = await this.prisma.refreshToken.findUnique({
      where: { tokenHash: this.hashRefreshToken(refreshToken) },
      select: { familyId: true, userId: true },
    });
    if (!token) return;

    await this.prisma.refreshToken.updateMany({
      where: { familyId: token.familyId, userId: token.userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }

  /** Invalidate every active refresh-token family owned by this user.
   * JWT strategy checks active session families, so already-issued access
   * tokens stop working on the next authenticated API request.
   */
  async revokeAllSessions(userId: string): Promise<void> {
    await this.prisma.refreshToken.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }

  async profile(userId: string) {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: {
        id: true,
        email: true,
        displayName: true,
        createdAt: true,
      },
    });
    if (!user) throw new NotFoundException('USER_NOT_FOUND');
    return user;
  }

  async listSessions(userId: string) {
    return this.prisma.refreshToken.findMany({
      where: { userId, revokedAt: null },
      select: { id: true, createdAt: true, expiresAt: true },
    });
  }

  async revokeSession(userId: string, tokenId: string): Promise<void> {
    const sessionToken = await this.prisma.refreshToken.findFirst({
      where: { id: tokenId, userId, revokedAt: null },
      select: { familyId: true },
    });
    if (!sessionToken) throw new NotFoundException('SESSION_NOT_FOUND');

    await this.prisma.refreshToken.updateMany({
      where: { familyId: sessionToken.familyId, userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }
}
