import {
  ConflictException,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { randomBytes } from 'crypto';
import { PrismaService } from '../prisma.service';
import { AuthService } from './auth.service';

interface VerifiedSupabaseUser {
  id: string;
  email: string;
}

/**
 * Staged Supabase Auth bridge.
 *
 * The remote Supabase Auth server validates the user's *access JWT*;
 * its publishable key identifies the app but does not authenticate a user.
 * Breezze's existing session family and authorization rules remain intact.
 * Existing accounts require an authenticated explicit link, never an
 * email-match auto-link.
 */
@Injectable()
export class SupabaseAuthBridge {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auth: AuthService,
  ) {}

  private config(): { origin: string; publishableKey: string } {
    const rawUrl = process.env.SUPABASE_URL?.trim();
    const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY?.trim();
    if (!rawUrl || !publishableKey) {
      throw new ServiceUnavailableException('SUPABASE_AUTH_NOT_CONFIGURED');
    }
    let url: URL;
    try {
      url = new URL(rawUrl);
    } catch {
      throw new ServiceUnavailableException('SUPABASE_AUTH_URL_INVALID');
    }
    if (url.protocol !== 'https:' ||
        !/^[a-z0-9-]+\.supabase\.co$/.test(url.hostname) ||
        url.pathname !== '/' || url.search || url.hash ||
        url.username || url.password || url.port) {
      throw new ServiceUnavailableException('SUPABASE_AUTH_URL_INVALID');
    }
    return { origin: url.origin, publishableKey };
  }

  async verifyAccessToken(accessToken: string): Promise<VerifiedSupabaseUser> {
    if (typeof accessToken !== 'string' ||
        accessToken.length < 40 || accessToken.length > 8192 ||
        !/^[A-Za-z0-9_.-]+$/.test(accessToken) ||
        accessToken.split('.').length !== 3) {
      throw new UnauthorizedException('SUPABASE_TOKEN_INVALID');
    }
    const config = this.config();
    let response: Response;
    try {
      response = await fetch(config.origin + '/auth/v1/user', {
        method: 'GET',
        redirect: 'manual',
        headers: {
          apikey: config.publishableKey,
          Authorization: `Bearer ${accessToken}`,
        },
        signal: AbortSignal.timeout(7000),
      });
    } catch {
      throw new ServiceUnavailableException('SUPABASE_AUTH_UNAVAILABLE');
    }
    if (response.status === 401 || response.status === 403) {
      throw new UnauthorizedException('SUPABASE_TOKEN_REJECTED');
    }
    if (response.status !== 200) {
      throw new ServiceUnavailableException('SUPABASE_AUTH_UNAVAILABLE');
    }
    let user: Record<string, unknown>;
    try {
      user = await response.json() as Record<string, unknown>;
    } catch {
      throw new UnauthorizedException('SUPABASE_USER_INVALID');
    }
    if (!user || typeof user.id !== 'string' ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(user.id) ||
        typeof user.email !== 'string' ||
        !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(user.email)) {
      throw new UnauthorizedException('SUPABASE_USER_INVALID');
    }
    // Prevent unverified Supabase emails from bypassing Breezze's account
    // requirements, including OAuth identities with no verified email.
    if (typeof user.email_confirmed_at !== 'string' ||
        !Number.isFinite(Date.parse(user.email_confirmed_at))) {
      throw new UnauthorizedException('SUPABASE_EMAIL_NOT_VERIFIED');
    }
    return { id: user.id, email: user.email.trim().toLowerCase() };
  }

  async exchange(accessToken: string) {
    const identity = await this.verifyAccessToken(accessToken);
    const linked = await this.prisma.supabaseAuthIdentity.findUnique({
      where: { subject: identity.id },
      select: { userId: true },
    });
    if (linked) {
      return this.auth.issueVerifiedSocialSession(linked.userId);
    }

    // Matching email is not evidence of ownership of a pre-existing Breezze
    // account; force an explicit account-link operation with its own session.
    const existing = await this.prisma.user.findFirst({
      where: { email: { equals: identity.email, mode: 'insensitive' } },
      select: { id: true },
    });
    if (existing) throw new ConflictException('SUPABASE_ACCOUNT_LINK_REQUIRED');

    let userId: string;
    try {
      const newUser = await this.prisma.user.create({
        data: {
          email: identity.email,
          displayName: null,
          // Not an Argon2 hash: intentionally impossible to use as a local
          // password; Supabase Auth owns the primary authentication method.
          passwordHash: '!supabase-managed:' + randomBytes(32).toString('hex'),
          supabaseIdentity: { create: { subject: identity.id } },
        },
        select: { id: true },
      });
      userId = newUser.id;
    } catch (error) {
      // Two devices can exchange the same newly registered identity. Accept
      // only the identity-matching winner, never a competing email owner.
      if ((error as { code?: string })?.code !== 'P2002') throw error;
      const winner = await this.prisma.supabaseAuthIdentity.findUnique({
        where: { subject: identity.id },
        select: { userId: true },
      });
      if (!winner) throw new ConflictException('SUPABASE_ACCOUNT_LINK_REQUIRED');
      userId = winner.userId;
    }
    return this.auth.issueVerifiedSocialSession(userId);
  }

  async link(userId: string, accessToken: string) {
    const identity = await this.verifyAccessToken(accessToken);
    const owner = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, email: true },
    });
    if (!owner || owner.email.toLowerCase() !== identity.email) {
      throw new UnauthorizedException('SUPABASE_IDENTITY_EMAIL_MISMATCH');
    }
    const linked = await this.prisma.supabaseAuthIdentity.findUnique({
      where: { subject: identity.id },
      select: { userId: true },
    });
    if (linked) {
      if (linked.userId !== userId) {
        throw new ConflictException('SUPABASE_IDENTITY_IN_USE');
      }
      return { linked: true };
    }
    try {
      await this.prisma.supabaseAuthIdentity.create({
        data: { userId, subject: identity.id },
      });
    } catch (error) {
      if ((error as { code?: string })?.code === 'P2002') {
        throw new ConflictException('SUPABASE_IDENTITY_IN_USE');
      }
      throw error;
    }
    return { linked: true };
  }
}
