import {
  ConflictException,
  GoneException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { PlaybackResolveService } from './playback-resolve.service';

const SESSION_TTL_MS = 2 * 60 * 60 * 1000;
const MAX_HEARTBEAT_CREDIT_MS = 30_000;

export const externalRecordingId = /^bz:(?:youtube_music:[A-Za-z0-9_-]{11}|deezer:[0-9]{1,20})$/;

export interface StartPlaybackSessionInput {
  trackId?: string;
  externalTrackId?: string;
  requestedQuality?: string;
  providerId?: string;
  providerTrackId?: string;
  canonicalTrackId?: string;
}

@Injectable()
export class PlaybackSessionService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly resolver: PlaybackResolveService,
  ) {}

  async start(userId: string, territory: string | undefined, input: StartPlaybackSessionInput) {
    if (!territory || !/^[A-Za-z]{2}$/.test(territory.trim())) {
      throw new ConflictException('PLAYBACK_TERRITORY_UNAVAILABLE');
    }
    const country = territory.trim().toUpperCase();
    let trackId: string;
    let providerId: string | null = null;
    let playback: Record<string, unknown>;

    if (input.externalTrackId !== undefined) {
      if (!externalRecordingId.test(input.externalTrackId) ||
          input.trackId || input.providerId || input.providerTrackId || input.canonicalTrackId) {
        throw new ConflictException('INVALID_EXTERNAL_SESSION_REQUEST');
      }
      const track = await this.prisma.track.findUnique({
        where: { externalId: input.externalTrackId },
        select: { id: true, source: true },
      });
      if (!track || track.source !== input.externalTrackId.split(':')[1]) {
        throw new NotFoundException('AUDIO_SOURCE_UNAVAILABLE');
      }
      input = { trackId: track.id, requestedQuality: input.requestedQuality };
    }

    if (input.providerId || input.providerTrackId || input.canonicalTrackId) {
      if (!input.providerId || !input.providerTrackId || !input.canonicalTrackId || input.trackId) {
        throw new ConflictException('INVALID_PROVIDER_SESSION_REQUEST');
      }
      trackId = input.canonicalTrackId;
      providerId = input.providerId;
      playback = await this.resolver.resolveProvider(userId, {
        providerId: input.providerId,
        providerTrackId: input.providerTrackId,
        canonicalTrackId: input.canonicalTrackId,
      }, country);
    } else {
      if (!input.trackId) throw new ConflictException('TRACK_ID_REQUIRED');
      trackId = input.trackId;
      playback = await this.resolver.resolve(userId, {
        trackId,
        ...(input.requestedQuality ? { requestedQuality: input.requestedQuality } : {}),
      }, country);
    }

    const now = new Date();
    const expiresAt = new Date(now.getTime() + SESSION_TTL_MS);
    const session = await this.prisma.playbackSession.create({
      data: {
        userId,
        trackId,
        providerId,
        territory: country,
        startedAt: now,
        lastHeartbeatAt: now,
        expiresAt,
      },
      select: { id: true, startedAt: true, expiresAt: true, territory: true },
    });
    return { ...session, playback };
  }

  async heartbeat(userId: string, sessionId: string, eventId: string, sequence: number) {
    const priorEvent = await this.prisma.playbackHeartbeat.findUnique({
      where: { id: eventId },
      select: { sessionId: true, sequence: true, elapsedMs: true },
    });
    if (priorEvent) {
      if (priorEvent.sessionId !== sessionId || priorEvent.sequence !== sequence) {
        throw new ConflictException('PLAYBACK_HEARTBEAT_ID_CONFLICT');
      }
      // A duplicate acknowledgement must still prove that the caller owns
      // the session. Event IDs are unguessable, but ownership is enforced
      // consistently on every session operation.
      const owner = await this.prisma.playbackSession.findUnique({
        where: { id: sessionId },
        select: { userId: true },
      });
      if (!owner || owner.userId !== userId) {
        throw new NotFoundException('PLAYBACK_SESSION_NOT_FOUND');
      }
      return { accepted: true, duplicate: true, creditedMs: priorEvent.elapsedMs };
    }

    const now = new Date();
    try {
      return await this.prisma.$transaction(async (tx) => {
        const session = await tx.playbackSession.findUnique({
          where: { id: sessionId },
        });
        if (!session || session.userId !== userId) {
          throw new NotFoundException('PLAYBACK_SESSION_NOT_FOUND');
        }
        if (session.status !== 'active' || session.expiresAt <= now) {
          throw new GoneException('PLAYBACK_SESSION_EXPIRED');
        }
        if (!Number.isInteger(sequence) || sequence !== session.lastSequence + 1) {
          throw new ConflictException('PLAYBACK_HEARTBEAT_SEQUENCE_INVALID');
        }

        // Credit only server-observed wall time, capped per heartbeat. A client
        // cannot claim an arbitrary duration by sending a large playedMs value.
        const elapsedMs = Math.max(0, Math.min(
          MAX_HEARTBEAT_CREDIT_MS,
          now.getTime() - session.lastHeartbeatAt.getTime(),
        ));
        const updated = await tx.playbackSession.updateMany({
          where: {
            id: sessionId,
            userId,
            status: 'active',
            lastSequence: session.lastSequence,
            expiresAt: { gt: now },
          },
          data: {
            lastSequence: sequence,
            lastHeartbeatAt: now,
            accumulatedMs: { increment: elapsedMs },
          },
        });
        if (updated.count !== 1) {
          throw new ConflictException('PLAYBACK_HEARTBEAT_RACE');
        }
        await tx.playbackHeartbeat.create({
          data: { id: eventId, sessionId, sequence, elapsedMs },
        });
        const total = await tx.playbackSession.findUnique({
          where: { id: sessionId },
          select: { accumulatedMs: true },
        });
        return {
          accepted: true,
          duplicate: false,
          creditedMs: elapsedMs,
          accumulatedMs: total?.accumulatedMs ?? elapsedMs,
        };
      });
    } catch (error) {
      if (error && typeof error === 'object' && 'code' in error && error.code === 'P2002') {
        const raced = await this.prisma.playbackHeartbeat.findUnique({
          where: { id: eventId },
          select: { sessionId: true, sequence: true, elapsedMs: true },
        });
        if (raced?.sessionId === sessionId && raced.sequence === sequence) {
          const owner = await this.prisma.playbackSession.findUnique({
            where: { id: sessionId },
            select: { userId: true },
          });
          if (!owner || owner.userId !== userId) {
            throw new NotFoundException('PLAYBACK_SESSION_NOT_FOUND');
          }
          return { accepted: true, duplicate: true, creditedMs: raced.elapsedMs };
        }
        throw new ConflictException('PLAYBACK_HEARTBEAT_ID_CONFLICT');
      }
      throw error;
    }
  }

  async pause(userId: string, sessionId: string) {
    return this.prisma.$transaction(async (tx) => {
      const now = new Date();
      const session = await tx.playbackSession.findUnique({ where: { id: sessionId } });
      if (!session || session.userId !== userId) {
        throw new NotFoundException('PLAYBACK_SESSION_NOT_FOUND');
      }
      if (session.status === 'paused') {
        return { paused: true, duplicate: true, accumulatedMs: session.accumulatedMs };
      }
      if (session.status !== 'active' || session.expiresAt <= now) {
        throw new GoneException('PLAYBACK_SESSION_EXPIRED');
      }

      // Credit only the bounded interval up to the pause command. Resetting
      // lastHeartbeatAt prevents paused wall time from being counted later.
      const pauseCreditMs = Math.max(0, Math.min(
        MAX_HEARTBEAT_CREDIT_MS,
        now.getTime() - session.lastHeartbeatAt.getTime(),
      ));
      const updated = await tx.playbackSession.updateMany({
        where: {
          id: sessionId,
          userId,
          status: 'active',
          lastSequence: session.lastSequence,
          expiresAt: { gt: now },
        },
        data: {
          status: 'paused',
          lastHeartbeatAt: now,
          accumulatedMs: { increment: pauseCreditMs },
        },
      });
      if (updated.count !== 1) {
        throw new ConflictException('PLAYBACK_SESSION_PAUSE_RACE');
      }
      return {
        paused: true,
        duplicate: false,
        creditedMs: pauseCreditMs,
        accumulatedMs: session.accumulatedMs + pauseCreditMs,
      };
    });
  }

  async resume(userId: string, sessionId: string) {
    return this.prisma.$transaction(async (tx) => {
      const now = new Date();
      const session = await tx.playbackSession.findUnique({ where: { id: sessionId } });
      if (!session || session.userId !== userId) {
        throw new NotFoundException('PLAYBACK_SESSION_NOT_FOUND');
      }
      if (session.status === 'active') {
        return { resumed: true, duplicate: true };
      }
      if (session.status !== 'paused' || session.expiresAt <= now) {
        throw new GoneException('PLAYBACK_SESSION_EXPIRED');
      }
      const updated = await tx.playbackSession.updateMany({
        where: {
          id: sessionId,
          userId,
          status: 'paused',
          expiresAt: { gt: now },
        },
        data: {
          status: 'active',
          lastHeartbeatAt: now,
        },
      });
      if (updated.count !== 1) {
        throw new ConflictException('PLAYBACK_SESSION_RESUME_RACE');
      }
      return { resumed: true, duplicate: false };
    });
  }

  async stop(userId: string, sessionId: string) {
    return this.prisma.$transaction(async (tx) => {
      const session = await tx.playbackSession.findUnique({ where: { id: sessionId } });
      if (!session || session.userId !== userId) {
        throw new NotFoundException('PLAYBACK_SESSION_NOT_FOUND');
      }
      if (session.status === 'stopped') {
        const event = await tx.listeningEvent.findUnique({
          where: { id: sessionId },
          select: { id: true },
        });
        return { stopped: true, duplicate: true, qualifiedPlayRecorded: Boolean(event) };
      }
      const stoppedAt = new Date();
      // Expired sessions may be closed for cleanup, but cannot accrue any
      // additional listening time after their authorization lease ends.
      const finalCreditMs = session.status === 'paused' || session.expiresAt <= stoppedAt
        ? 0
        : Math.max(0, Math.min(
            MAX_HEARTBEAT_CREDIT_MS,
            stoppedAt.getTime() - session.lastHeartbeatAt.getTime(),
          ));
      const totalAccumulatedMs = session.accumulatedMs + finalCreditMs;
      if (session.status !== 'active' && session.status !== 'paused') {
        throw new GoneException('PLAYBACK_SESSION_NOT_ACTIVE');
      }
      const stopped = await tx.playbackSession.updateMany({
        where: { id: sessionId, userId, status: session.status },
        data: {
          status: 'stopped',
          stoppedAt,
          accumulatedMs: { increment: finalCreditMs },
        },
      });
      if (stopped.count !== 1) {
        const latest = await tx.playbackSession.findUnique({ where: { id: sessionId } });
        const event = await tx.listeningEvent.findUnique({
          where: { id: sessionId },
          select: { id: true },
        });
        if (latest?.status === 'stopped') {
          return { stopped: true, duplicate: true, qualifiedPlayRecorded: Boolean(event) };
        }
        throw new ConflictException('PLAYBACK_SESSION_STOP_RACE');
      }
      const qualified = totalAccumulatedMs >= 30_000;
      if (qualified) {
        await tx.listeningEvent.create({
          data: {
            id: session.id,
            userId,
            trackId: session.trackId,
            playedMs: totalAccumulatedMs,
            isServerVerified: true,
          },
        });
        await tx.recentlyPlayed.upsert({
          where: { userId_trackId: { userId, trackId: session.trackId } },
          create: { userId, trackId: session.trackId },
          update: { playedAt: new Date() },
        });
      }
      return {
        stopped: true,
        duplicate: false,
        qualifiedPlayRecorded: qualified,
        accumulatedMs: totalAccumulatedMs,
      };
    });
  }
}
