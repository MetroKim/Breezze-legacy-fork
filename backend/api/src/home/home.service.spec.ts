import { NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { HomeService } from './home.service';
import { RecommendationsService } from '../recommendations/recommendations.service';

describe('HomeService history and personalized feed', () => {
  const prisma = {
    track: { findUnique: jest.fn() },
    recentlyPlayed: { findMany: jest.fn(), upsert: jest.fn() },
    favorite: { findMany: jest.fn() },
  };
  const recommendations = { forUser: jest.fn() };
  let service: HomeService;

  beforeEach(() => {
    jest.clearAllMocks();
    prisma.track.findUnique.mockResolvedValue({ id: 'track-1' });
    prisma.recentlyPlayed.upsert.mockResolvedValue({ id: 'recent-1' });
    prisma.recentlyPlayed.findMany.mockResolvedValue([]);
    prisma.favorite.findMany.mockResolvedValue([]);
    recommendations.forUser.mockResolvedValue([]);
    service = new HomeService(
      prisma as unknown as PrismaService,
      recommendations as unknown as RecommendationsService,
    );
  });

  it('syncs recent history without creating a qualified listening event', async () => {
    await expect(service.recordRecent('user-1', 'track-1'))
      .resolves.toEqual({ recorded: true });
    expect(prisma.recentlyPlayed.upsert).toHaveBeenCalledWith({
      where: { userId_trackId: { userId: 'user-1', trackId: 'track-1' } },
      create: { userId: 'user-1', trackId: 'track-1' },
      update: { playedAt: expect.any(Date) },
    });
  });

  it('rejects recent history for a non-existent canonical track', async () => {
    prisma.track.findUnique.mockResolvedValue(null);
    await expect(service.recordRecent('user-1', 'missing-track'))
      .rejects.toBeInstanceOf(NotFoundException);
    expect(prisma.recentlyPlayed.upsert).not.toHaveBeenCalled();
  });

  it('includes recommendations selected for the trusted edge territory', async () => {
    recommendations.forUser.mockResolvedValue([
      { trackId: 'recommended-1', reason: 'Because you listen to this artist' },
      { trackId: 'recommended-2', reason: 'Popular on Breezze' },
    ]);
    await expect(service.feed('user-1', 'TZ')).resolves.toEqual([{
      sectionType: 'personalized',
      title: 'Made for You',
      layout: 'rail',
      trackIds: ['recommended-1', 'recommended-2'],
    }]);
    expect(recommendations.forUser).toHaveBeenCalledWith('user-1', 'TZ');
  });

  it('places followed-artist tracks in their own Home shelf without duplicates', async () => {
    recommendations.forUser.mockResolvedValue([
      { trackId: 'followed-1', reason: 'Because you follow this artist' },
      { trackId: 'discovery-1', reason: 'More from your favorite artists' },
      { trackId: 'followed-2', reason: 'Because you follow this artist' },
    ]);
    await expect(service.feed('user-1', 'TZ')).resolves.toEqual([
      {
        sectionType: 'followed_artists',
        title: 'From Artists You Follow',
        layout: 'rail',
        trackIds: ['followed-1', 'followed-2'],
      },
      {
        sectionType: 'personalized',
        title: 'Made for You',
        layout: 'rail',
        trackIds: ['discovery-1'],
      },
    ]);
  });

});
