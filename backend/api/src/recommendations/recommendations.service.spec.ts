import { PrismaService } from '../prisma.service';
import { RightsDecisionService } from '../rights/rights-decision.service';
import { RecommendationsService } from './recommendations.service';

describe('RecommendationsService', () => {
  const prisma = {
    recentlyPlayed: { findMany: jest.fn() },
    favorite: { findMany: jest.fn() },
    listeningEvent: { groupBy: jest.fn() },
    track: { findMany: jest.fn() },
    artist: { findMany: jest.fn() },
    userPreference: { findUnique: jest.fn() },
    userFollowedArtist: { findMany: jest.fn() },
  };
  const rights = { filterFullStream: jest.fn() };
  let service: RecommendationsService;

  beforeEach(() => {
    jest.clearAllMocks();
    prisma.recentlyPlayed.findMany.mockResolvedValue([]);
    prisma.favorite.findMany.mockResolvedValue([]);
    prisma.artist.findMany.mockResolvedValue([]);
    prisma.userFollowedArtist.findMany.mockResolvedValue([]);
    prisma.userPreference.findUnique.mockResolvedValue({ favoriteArtists: [] });
    prisma.listeningEvent.groupBy.mockResolvedValue([
      { trackId: 'listened-a', _count: { trackId: 5 } },
      { trackId: 'listened-b', _count: { trackId: 3 } },
    ]);
    prisma.track.findMany.mockImplementation(({ where }: any) => {
      if (where.id?.in) {
        return Promise.resolve([
          { id: 'listened-a', artistId: 'artist-a' },
          { id: 'listened-b', artistId: 'artist-b' },
        ]);
      }
      if (where.artistId === 'artist-a') {
        return Promise.resolve([
          { id: 'a-1', artistId: 'artist-a' },
          { id: 'a-2', artistId: 'artist-a' },
          { id: 'a-3', artistId: 'artist-a' },
        ]);
      }
      if (where.artistId === 'artist-b') {
        return Promise.resolve([{ id: 'b-1', artistId: 'artist-b' }]);
      }
      return Promise.resolve([]);
    });
    rights.filterFullStream.mockImplementation((ids: string[]) => Promise.resolve(new Set(ids)));
    service = new RecommendationsService(
      prisma as unknown as PrismaService,
      rights as unknown as RightsDecisionService,
    );
  });

  it('returns no playback recommendations until a trusted edge territory is available', async () => {
    

    await expect(service.forUser('user-1', undefined)).resolves.toEqual([]);
    expect(prisma.listeningEvent.groupBy).not.toHaveBeenCalled();
    expect(rights.filterFullStream).not.toHaveBeenCalled();
  });

  it('ranks listening artists, caps each artist at two tracks, and checks full-play rights', async () => {
    rights.filterFullStream.mockResolvedValue(new Set(['a-3', 'b-1']));

    await expect(service.forUser('user-1', 'TZ')).resolves.toEqual([
      { trackId: 'b-1', reason: 'Because you listen to this artist' },
      { trackId: 'a-3', reason: 'Because you listen to this artist' },
    ]);

    expect(prisma.listeningEvent.groupBy).toHaveBeenCalledWith(expect.objectContaining({
      where: { userId: 'user-1', isServerVerified: true },
    }));
    expect(rights.filterFullStream).toHaveBeenCalledWith(
      ['a-1', 'b-1', 'a-2', 'a-3'],
      'TZ',
    );
  });

  it('interleaves artist candidates so one prolific artist cannot starve the others', async () => {
    prisma.track.findMany.mockImplementation(({ where }: any) => {
      if (where.id?.in) {
        return Promise.resolve([
          { id: 'listened-a', artistId: 'artist-a' },
          { id: 'listened-b', artistId: 'artist-b' },
        ]);
      }
      if (where.artistId === 'artist-a') {
        return Promise.resolve([
          { id: 'a-1', artistId: 'artist-a' },
          { id: 'a-2', artistId: 'artist-a' },
          { id: 'a-3', artistId: 'artist-a' },
        ]);
      }
      return Promise.resolve([
        { id: 'b-1', artistId: 'artist-b' },
        { id: 'b-2', artistId: 'artist-b' },
      ]);
    });
    rights.filterFullStream.mockResolvedValue(new Set(['a-1', 'a-2', 'a-3', 'b-1', 'b-2']));

    const result = await service.forUser('user-1', 'TZ');

    expect(result.slice(0, 3).map((item) => item.trackId)).toEqual(['a-1', 'b-1', 'a-2']);
    expect(result.filter((item) => item.trackId.startsWith('a-'))).toHaveLength(2);
  });

  it('excludes recently played and favorited tracks before checking candidates', async () => {
    prisma.recentlyPlayed.findMany.mockResolvedValue([{ trackId: 'recent-1' }]);
    prisma.favorite.findMany.mockResolvedValue([{ trackId: 'favorite-1' }]);

    await service.forUser('user-1', 'TZ');

    const candidateQueries = prisma.track.findMany.mock.calls.slice(1).map(([query]) => query);
    expect(candidateQueries.length).toBeGreaterThan(0);
    for (const candidateQuery of candidateQueries) {
      expect(candidateQuery.where.id.notIn).toEqual(
        expect.arrayContaining(['recent-1', 'favorite-1']),
      );
    }
  });

  it('uses onboarding favorite artists for cold-start recommendations', async () => {
    prisma.listeningEvent.groupBy.mockResolvedValueOnce([]);
    prisma.userPreference.findUnique.mockResolvedValue({
      favoriteArtists: ['  Artist X  '],
    });
    prisma.artist.findMany.mockResolvedValue([
      { id: 'artist-x', name: 'Artist X' },
    ]);
    prisma.track.findMany.mockResolvedValue([
      { id: 'preferred-1', artistId: 'artist-x' },
      { id: 'preferred-2', artistId: 'artist-x' },
    ]);
    rights.filterFullStream.mockResolvedValue(
      new Set(['preferred-1', 'preferred-2']),
    );

    await expect(service.forUser('new-user', 'TZ')).resolves.toEqual([
      { trackId: 'preferred-1', reason: 'Because you chose this artist' },
      { trackId: 'preferred-2', reason: 'Because you chose this artist' },
    ]);

    expect(prisma.userPreference.findUnique).toHaveBeenCalledWith({
      where: { userId: 'new-user' },
      select: { favoriteArtists: true },
    });
    expect(prisma.artist.findMany).toHaveBeenCalledWith({
      where: { name: { in: ['Artist X'], mode: 'insensitive' } },
      select: { id: true, name: true },
    });
    expect(rights.filterFullStream).toHaveBeenCalledWith(
      ['preferred-1', 'preferred-2'],
      'TZ',
    );
  });

  it('uses rights-filtered popular tracks for a new listener', async () => {
    prisma.listeningEvent.groupBy
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce([
        { trackId: 'popular-1', _count: { trackId: 20 } },
        { trackId: 'popular-2', _count: { trackId: 15 } },
      ]);
    prisma.track.findMany.mockResolvedValue([
      { id: 'popular-1', artistId: 'artist-a' },
      { id: 'popular-2', artistId: 'artist-b' },
    ]);

    await expect(service.forUser('new-user', 'TZ')).resolves.toEqual([
      { trackId: 'popular-1', reason: 'Popular on Breezze' },
      { trackId: 'popular-2', reason: 'Popular on Breezze' },
    ]);
    expect(prisma.listeningEvent.groupBy).toHaveBeenLastCalledWith(expect.objectContaining({
      where: { isServerVerified: true },
    }));
    expect(rights.filterFullStream).toHaveBeenCalledWith(['popular-1', 'popular-2'], 'TZ');
  });

  it('falls back to playable popular tracks when chosen artists have no playable candidates', async () => {
    prisma.listeningEvent.groupBy.mockReset()
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce([
        { trackId: 'recent-1', _count: { trackId: 50 } },
        { trackId: 'popular-1', _count: { trackId: 20 } },
        { trackId: 'blocked-1', _count: { trackId: 15 } },
      ]);
    prisma.recentlyPlayed.findMany.mockResolvedValue([{ trackId: 'recent-1' }]);
    prisma.userPreference.findUnique.mockResolvedValue({ favoriteArtists: ['Artist X'] });
    prisma.artist.findMany.mockResolvedValue([{ id: 'artist-x', name: 'Artist X' }]);
    prisma.track.findMany.mockImplementation(({ where }: any) => Promise.resolve(
      where.artistId ? [{ id: 'unavailable-1', artistId: 'artist-x' }] : [
        { id: 'popular-1', artistId: 'artist-a' },
        { id: 'blocked-1', artistId: 'artist-b' },
      ],
    ));
    rights.filterFullStream
      .mockResolvedValueOnce(new Set())
      .mockResolvedValueOnce(new Set(['popular-1']));

    await expect(service.forUser('user-1', 'TZ')).resolves.toEqual([
      { trackId: 'popular-1', reason: 'Popular on Breezze' },
    ]);
    expect(rights.filterFullStream).toHaveBeenLastCalledWith(['popular-1', 'blocked-1'], 'TZ');
  });

  it('prioritizes an explicitly followed Apple artist when its canonical catalog match exists', async () => {
    prisma.userFollowedArtist.findMany.mockResolvedValue([
      { artistKey: 'apple:198', artistName: 'Artist X' },
    ]);
    prisma.listeningEvent.groupBy.mockResolvedValueOnce([]);
    prisma.artist.findMany.mockResolvedValue([
      { id: 'artist-x', name: 'Artist X' },
    ]);
    prisma.track.findMany.mockImplementation(({ where }: any) => {
      if (where.artistId === 'artist-x') {
        return Promise.resolve([
          { id: 'new-from-followed', artistId: 'artist-x' },
        ]);
      }
      return Promise.resolve([]);
    });

    const items = await service.forUser('follower', 'TZ');
    expect(items).toEqual([
      { trackId: 'new-from-followed', reason: 'Because you follow this artist' },
    ]);
    expect(prisma.userFollowedArtist.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { userId: 'follower' } }),
    );
    expect(rights.filterFullStream).toHaveBeenCalledWith(
      ['new-from-followed'], 'TZ',
    );
  });

  it('uses canonical artist follows even when no name was stored', async () => {
    prisma.userFollowedArtist.findMany.mockResolvedValue([
      { artistKey: 'catalog:artist-a', artistName: null },
    ]);
    prisma.listeningEvent.groupBy.mockResolvedValueOnce([]);
    const items = await service.forUser('follower', 'TZ');
    expect(items[0]).toEqual({
      trackId: 'a-1',
      reason: 'Because you follow this artist',
    });
  });
});
