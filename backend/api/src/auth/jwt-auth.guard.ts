import {
  CanActivate,
  ConflictException,
  ExecutionContext,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { randomUUID } from 'crypto';
import { PrismaService } from '../prisma.service';

/**
 * Breezze accepts a single user identity: the verified Supabase Auth user.
 * Never trust a JWT's unverified claims or a client-supplied user id.
 * Supabase Auth validates the bearer token before a local row is resolved.
 */
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(private readonly prisma: PrismaService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<{
      headers: { authorization?: string };
      user?: Record<string, unknown>;
    }>();
    const match = /^Bearer\s+(\S+)$/i.exec(request.headers.authorization ?? '');
    if (!match) throw new UnauthorizedException('AUTH_REQUIRED');

    const supabaseUrl = (process.env.SUPABASE_URL ??
      'https://djwvyjtebmsavhcrmhxf.supabase.co').replace(/\/$/, '');
    const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY ??
      'sb_publishable_ZloCmmQPo86OqHbH3Yqgsw_xZGPqSi3';
    if (!supabaseUrl.startsWith('https://') || !publishableKey) {
      throw new ServiceUnavailableException('AUTH_NOT_CONFIGURED');
    }

    let identity: {
      id?: string;
      email?: string;
      email_confirmed_at?: string | null;
      user_metadata?: { full_name?: string; name?: string };
    };
    try {
      const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
        headers: {
          Authorization: `Bearer ${match[1]}`,
          apikey: publishableKey,
        },
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) throw new UnauthorizedException('SESSION_INVALID');
      identity = (await response.json()) as typeof identity;
    } catch (error) {
      if (error instanceof UnauthorizedException) throw error;
      throw new ServiceUnavailableException('AUTH_PROVIDER_UNAVAILABLE');
    }

    const id = identity.id;
    const email = identity.email?.trim().toLowerCase();
    if (!id || !/^[0-9a-f-]{36}$/i.test(id) || !email ||
        !identity.email_confirmed_at) {
      throw new UnauthorizedException('VERIFIED_IDENTITY_REQUIRED');
    }

    // Do not auto-merge a Supabase identity into a legacy Breezze account
    // on an email match: account migration needs an explicit proof-of-ownership.
    let user = await this.prisma.user.findUnique({ where: { id } });
    if (!user) {
      const emailOwner = await this.prisma.user.findUnique({ where: { email } });
      if (emailOwner) throw new ConflictException('ACCOUNT_MIGRATION_REQUIRED');
      try {
        user = await this.prisma.user.create({
          data: {
            id,
            email,
            // No user password exists in Breezze. This is deliberately not
            // an Argon2 hash and cannot authenticate via the old API.
            passwordHash: `supabase-managed:${randomUUID()}`,
            displayName: identity.user_metadata?.full_name ??
              identity.user_metadata?.name ?? null,
          },
        });
      } catch (error) {
        // Concurrent first requests from the same Supabase account.
        user = await this.prisma.user.findUnique({ where: { id } });
        if (!user) throw error;
      }
    }
    if (user.email !== email) {
      // Fail closed if a new email collides with a different local account.
      const existing = await this.prisma.user.findUnique({ where: { email } });
      if (existing && existing.id !== id) {
        throw new ConflictException('ACCOUNT_MIGRATION_REQUIRED');
      }
      user = await this.prisma.user.update({
        where: { id },
        data: { email },
      });
    }

    request.user = {
      id: user.id,
      email: user.email,
      role: user.role,
      mfaEnabled: user.mfaEnabled,
      // Privileged admin operations remain denied until Supabase AAL2
      // verification is explicitly implemented and tested.
      mfaVerified: false,
      sessionId: null,
    };
    return true;
  }
}
