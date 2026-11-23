import {
  ConflictException,
  GoneException,
  NotFoundException,
} from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { PlaybackResolveService } from './playback-resolve.service';
import { PlaybackSessionService } from './playback-session.service';

describe('PlaybackSessionService', () => {
  const prisma = {
    track: { findUnique: jest.fn() },
    playbackSession: {
      create: jest.fn(),
      findUnique: jest.fn(),
      updateMany: jest.fn(),
    },
    playbackHeartbeat: { findUnique: jest.fn(), create: jest.fn() },
    listeningEvent: { findUnique: jest.fn(), create: jest.fn() },
    recentlyPlayed: { upsert: jest.fn() },
    $transaction: jest.fn(),
  };
  const tx = {
    playbackSession: { findUnique: jest.fn(), updateMany: jest.fn() },
    playbackHeartbeat: { create: jest.fn() },
    listeningEvent: { findUnique: jest.fn(), create: jest.fn() },
    recentlyPlayed: { upsert: jest.fn() },
  };
  const resolver = { resolve: jest.fn(), resolveProvider: jest.fn() };
  let service: PlaybackSessionService;

  beforeEach(() => {
    jest.useFakeTimers();
    jest.setSystemTime(new Date('2026-11-22T08:00:00.000Z'));
    jest.clearAllMocks();
    const now = new Date();
    prisma.playbackSession.create.mockResolvedValue({
      id: 'session-uuid', startedAt: now, expiresAt: new Date(now.getTime() + 7_200_000), territory: 'TZ',
    });
    prisma.playbackHeartbeat.findUnique.mockResolvedValue(null);
    prisma.playbackHeartbeat.create.mockResolvedValue({});
    tx.playbackSession.findUnique.mockReset();
    tx.playbackSession.findUnique.mockResolvedValueOnce({
      id: 'session-uuid', userId: 'user-1', trackId: 'track-1',
      status: 'active', territory: 'TZ', expiresAt: new Date(Date.now() + 60_000),
      lastSequence: 0, lastHeartbeatAt: new Date(Date.now() - 10_000), accumulatedMs: 0,
    });
    tx.playbackSession.findUnique.mockResolvedValueOnce({ accumulatedMs: 10_000 });
    tx.playbackSession.updateMany.mockResolvedValue({ count: 1 });
    tx.playbackHeartbeat.create.mockResolvedValue({});
    tx.listeningEvent.findUnique.mockResolvedValue(null);
    tx.listeningEvent.create.mockResolvedValue({});
    tx.recentlyPlayed.upsert.mockResolvedValue({});
    prisma.$transaction.mockImplementation((callback: (value: typeof tx) => unknown) => callback(tx));
    service = new PlaybackSessionService(
      prisma as unknown as PrismaService,
      resolver as unknown as PlaybackResolveService,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('creates a session only after full-track playback authorization', async () => {
    resolver.resolve.mockResolvedValue({ streamUrl: 'https://cdn.example/audio' });
    const result = await service.start('user-1', 'tz', { trackId: 'track-1' });
    expect(resolver.resolve).toHaveBeenCalledWith('user-1', { trackId: 'track-1' }, 'TZ');
    expect(prisma.playbackSession.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        userId: 'user-1', trackId: 'track-1', territory: 'TZ', providerId: null,
        expiresAt: expect.any(Date),
      }),
      select: { id: true, startedAt: true, expiresAt: true, territory: true },
    });
    expect(result.playback).toEqual({ streamUrl: 'https://cdn.example/audio' });
  });

  it.each([
    ['youtube_music', 'bz:youtube_music:abcdefghijk'],
    ['deezer', 'bz:deezer:3135556'],
  ])('resolves the exact authorized master for %s', async (source, externalTrackId) => {
    prisma.track.findUnique.mockResolvedValue({ id: 'master-id', source });
    resolver.resolve.mockResolvedValue({ streamUrl: 'https://cdn.example/master.m4a' });
    const session = await service.start('user-1', 'TZ', { externalTrackId, requestedQuality: 'AAC_256' });
    expect(prisma.track.findUnique).toHaveBeenCalledWith({
      where: { externalId: externalTrackId }, select: { id: true, source: true },
    });
    expect(resolver.resolve).toHaveBeenCalledWith('user-1', {
      trackId: 'master-id', requestedQuality: 'AAC_256',
    }, 'TZ');
    expect(session.playback.streamUrl).toBe('https://cdn.example/master.m4a');
  });

  it('does not create a session for a song without a matching recording', async () => {
    prisma.track.findUnique.mockResolvedValue(null);
    await expect(service.start('user-1', 'TZ', { externalTrackId: 'bz:youtube_music:abcdefghijk' }))
      .rejects.toThrow('AUDIO_SOURCE_UNAVAILABLE');
    expect(prisma.playbackSession.create).not.toHaveBeenCalled();
  });

  it('passes the requested streaming quality into full-track authorization', async () => {
    resolver.resolve.mockResolvedValue({ streamUrl: 'https://cdn.example/audio' });
    await service.start('user-1', 'tz', {
      trackId: 'track-1',
      requestedQuality: 'LOSSLESS',
    });
    expect(resolver.resolve).toHaveBeenCalledWith('user-1', {
      trackId: 'track-1',
      requestedQuality: 'LOSSLESS',
    }, 'TZ');
  });

  it('rejects missing trusted territory before creating a session', async () => {
    await expect(service.start('user-1', undefined, { trackId: 'track-1' }))
      .rejects.toThrow('PLAYBACK_TERRITORY_UNAVAILABLE');
    expect(prisma.playbackSession.create).not.toHaveBeenCalled();
  });

  it('resolves provider playback before creating a provider-bound session', async () => {
    resolver.resolveProvider.mockResolvedValue({ streamUrl: 'https://provider.example/stream' });
    await service.start('user-1', 'TZ', {
      providerId: 'audius', providerTrackId: 'remote-1', canonicalTrackId: 'track-1',
    });
    expect(resolver.resolveProvider).toHaveBeenCalledWith('user-1', {
      providerId: 'audius', providerTrackId: 'remote-1', canonicalTrackId: 'track-1',
    }, 'TZ');
    expect(prisma.playbackSession.create).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({ trackId: 'track-1', providerId: 'audius' }),
    }));
  });

  it('credits server elapsed time and rejects a client-supplied duration by design', async () => {
    const result = await service.heartbeat('user-1', 'session-uuid', 'event-uuid', 1);
    expect(result).toMatchObject({ accepted: true, duplicate: false, creditedMs: 10_000 });
    expect(tx.playbackSession.updateMany).toHaveBeenCalledWith({
      where: {
        id: 'session-uuid', userId: 'user-1', status: 'active',
        lastSequence: 0, expiresAt: { gt: expect.any(Date) },
      },
      data: {
        lastSequence: 1,
        lastHeartbeatAt: expect.any(Date),
        accumulatedMs: { increment: 10_000 },
      },
    });
    expect(tx.playbackHeartbeat.create).toHaveBeenCalledWith({
      data: { id: 'event-uuid', sessionId: 'session-uuid', sequence: 1, elapsedMs: 10_000 },
    });
  });

  it('acknowledges an identical heartbeat retry without crediting time twice', async () => {
    prisma.playbackHeartbeat.findUnique.mockResolvedValue({
      sessionId: 'session-uuid', sequence: 1, elapsedMs: 10_000,
    });
    prisma.playbackSession.findUnique.mockResolvedValue({ userId: 'user-1' });
    await expect(service.heartbeat('user-1', 'session-uuid', 'event-uuid', 1))
      .resolves.toEqual({ accepted: true, duplicate: true, creditedMs: 10_000 });
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('does not acknowledge a duplicate heartbeat to a non-owner', async () => {
    prisma.playbackHeartbeat.findUnique.mockResolvedValue({
      sessionId: 'session-uuid', sequence: 1, elapsedMs: 10_000,
    });
    prisma.playbackSession.findUnique.mockResolvedValue({ userId: 'other-user' });
    await expect(service.heartbeat('user-1', 'session-uuid', 'event-uuid', 1))
      .rejects.toBeInstanceOf(NotFoundException);
  });

  it('does not acknowledge a raced duplicate heartbeat to a non-owner', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', trackId: 'track-1',
      status: 'active', expiresAt: new Date(Date.now() + 60_000),
      lastSequence: 0, lastHeartbeatAt: new Date(Date.now() - 10_000), accumulatedMs: 0,
    });
    tx.playbackSession.updateMany.mockResolvedValue({ count: 1 });
    tx.playbackHeartbeat.create.mockRejectedValue({ code: 'P2002' });
    prisma.playbackHeartbeat.findUnique
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce({
        sessionId: 'session-uuid', sequence: 1, elapsedMs: 10_000,
      });
    prisma.playbackSession.findUnique.mockResolvedValue({ userId: 'other-user' });

    await expect(service.heartbeat('user-1', 'session-uuid', 'event-uuid', 1))
      .rejects.toBeInstanceOf(NotFoundException);
  });

  it('rejects reuse of a heartbeat ID for a different session or sequence', async () => {
    prisma.playbackHeartbeat.findUnique.mockResolvedValue({
      sessionId: 'other-session', sequence: 1, elapsedMs: 10_000,
    });
    await expect(service.heartbeat('user-1', 'session-uuid', 'event-uuid', 1))
      .rejects.toBeInstanceOf(ConflictException);
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('rejects a session owned by another user', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'other-user', status: 'active',
    });
    await expect(service.heartbeat('user-1', 'session-uuid', 'event-uuid', 1))
      .rejects.toBeInstanceOf(NotFoundException);
  });

  it('rejects expired sessions and does not create a heartbeat', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', status: 'active',
      expiresAt: new Date(Date.now() - 1), lastSequence: 0,
    });
    await expect(service.heartbeat('user-1', 'session-uuid', 'event-uuid', 1))
      .rejects.toBeInstanceOf(GoneException);
    expect(tx.playbackHeartbeat.create).not.toHaveBeenCalled();
  });

  it('rejects skipped or replayed sequence numbers', async () => {
    await expect(service.heartbeat('user-1', 'session-uuid', 'event-uuid', 2))
      .rejects.toBeInstanceOf(ConflictException);
    expect(tx.playbackHeartbeat.create).not.toHaveBeenCalled();
  });

  it('uses a compare-and-swap update to reject concurrent heartbeat races', async () => {
    tx.playbackSession.updateMany.mockResolvedValue({ count: 0 });
    await expect(service.heartbeat('user-1', 'session-uuid', 'event-uuid', 1))
      .rejects.toThrow('PLAYBACK_HEARTBEAT_RACE');
    expect(tx.playbackHeartbeat.create).not.toHaveBeenCalled();
  });

  it('pauses an active session and credits only the bounded pre-pause interval', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', status: 'active',
      expiresAt: new Date(Date.now() + 60_000), lastSequence: 2,
      lastHeartbeatAt: new Date(Date.now() - 8_000), accumulatedMs: 12_000,
    });
    await expect(service.pause('user-1', 'session-uuid')).resolves.toMatchObject({
      paused: true, duplicate: false, creditedMs: 8_000, accumulatedMs: 20_000,
    });
    expect(tx.playbackSession.updateMany).toHaveBeenCalledWith({
      where: {
        id: 'session-uuid', userId: 'user-1', status: 'active',
        lastSequence: 2, expiresAt: { gt: expect.any(Date) },
      },
      data: {
        status: 'paused', lastHeartbeatAt: expect.any(Date),
        accumulatedMs: { increment: 8_000 },
      },
    });
  });

  it('makes pause retries idempotent', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', status: 'paused', accumulatedMs: 20_000,
    });
    await expect(service.pause('user-1', 'session-uuid')).resolves.toMatchObject({
      paused: true, duplicate: true, accumulatedMs: 20_000,
    });
    expect(tx.playbackSession.updateMany).not.toHaveBeenCalled();
  });

  it('resumes a paused session and resets the server clock', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', status: 'paused',
      expiresAt: new Date(Date.now() + 60_000),
    });
    await expect(service.resume('user-1', 'session-uuid')).resolves.toEqual({
      resumed: true, duplicate: false,
    });
    expect(tx.playbackSession.updateMany).toHaveBeenCalledWith({
      where: {
        id: 'session-uuid', userId: 'user-1', status: 'paused',
        expiresAt: { gt: expect.any(Date) },
      },
      data: { status: 'active', lastHeartbeatAt: expect.any(Date) },
    });
  });

  it('does not credit paused wall time when stopping a paused session', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', trackId: 'track-1',
      status: 'paused', accumulatedMs: 29_999,
      lastHeartbeatAt: new Date(Date.now() - 25_000),
    });
    await expect(service.stop('user-1', 'session-uuid')).resolves.toMatchObject({
      qualifiedPlayRecorded: false, accumulatedMs: 29_999,
    });
    expect(tx.playbackSession.updateMany).toHaveBeenCalledWith({
      where: { id: 'session-uuid', userId: 'user-1', status: 'paused' },
      data: {
        status: 'stopped',
        stoppedAt: expect.any(Date),
        accumulatedMs: { increment: 0 },
      },
    });
    expect(tx.listeningEvent.create).not.toHaveBeenCalled();
  });

  it('closes expired active sessions without crediting post-expiry time', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', trackId: 'track-1',
      status: 'active', accumulatedMs: 29_999,
      expiresAt: new Date(Date.now() - 1),
      lastHeartbeatAt: new Date(Date.now() - 10_000),
    });
    await expect(service.stop('user-1', 'session-uuid')).resolves.toMatchObject({
      stopped: true,
      qualifiedPlayRecorded: false,
      accumulatedMs: 29_999,
    });
    expect(tx.playbackSession.updateMany).toHaveBeenCalledWith({
      where: { id: 'session-uuid', userId: 'user-1', status: 'active' },
      data: {
        status: 'stopped',
        stoppedAt: expect.any(Date),
        accumulatedMs: { increment: 0 },
      },
    });
    expect(tx.listeningEvent.create).not.toHaveBeenCalled();
  });

  it('records a qualified listening event from server-accumulated time on stop', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', trackId: 'track-1',
      status: 'active', accumulatedMs: 45_000, lastHeartbeatAt: new Date(Date.now() - 10_000),
    });
    await expect(service.stop('user-1', 'session-uuid')).resolves.toMatchObject({
      stopped: true, duplicate: false, qualifiedPlayRecorded: true, accumulatedMs: 55_000,
    });
    expect(tx.listeningEvent.create).toHaveBeenCalledWith({
      data: { id: 'session-uuid', userId: 'user-1', trackId: 'track-1', playedMs: 55_000, isServerVerified: true },
    });
    expect(tx.recentlyPlayed.upsert).toHaveBeenCalled();
  });

  it('does not create a qualified event for a short session', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', trackId: 'track-1',
      status: 'active', accumulatedMs: 19_999, lastHeartbeatAt: new Date(Date.now() - 10_000),
    });
    await expect(service.stop('user-1', 'session-uuid')).resolves.toMatchObject({
      qualifiedPlayRecorded: false,
    });
    expect(tx.listeningEvent.create).not.toHaveBeenCalled();
  });

  it('makes stop retries idempotent', async () => {
    tx.playbackSession.findUnique.mockReset().mockResolvedValue({
      id: 'session-uuid', userId: 'user-1', status: 'stopped', accumulatedMs: 45_000,
    });
    tx.listeningEvent.findUnique.mockResolvedValue({ id: 'session-uuid' });
    await expect(service.stop('user-1', 'session-uuid')).resolves.toEqual({
      stopped: true, duplicate: true, qualifiedPlayRecorded: true,
    });
    expect(tx.listeningEvent.create).not.toHaveBeenCalled();
  });
});
