import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { RightsDecisionService } from '../rights/rights-decision.service';

export interface RecommendationItem {
  trackId: string;
  reason: string;
}

interface CandidateTrack {
  id: string;
  artistId: string;
}

@Injectable()
export class RecommendationsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly rights: RightsDecisionService,
  ) {}

  async forUser(userId: string, edgeTerritory?: string): Promise<RecommendationItem[]> {
    const territory = edgeTerritory?.trim().toUpperCase();
    // Rights-sensitive recommendations use only the trusted edge country,
    // never the editable country preference stored in the user's profile.
    if (!territory || !/^[A-Z]{2}$/.test(territory)) return [];

    const [recent, favorites, listening, preference, followed] = await Promise.all([
      this.prisma.recentlyPlayed.findMany({
        where: { userId },
        orderBy: { playedAt: 'desc' },
        take: 50,
        select: { trackId: true },
      }),
      this.prisma.favorite.findMany({
        where: { userId },
        orderBy: { createdAt: 'desc' },
        take: 100,
        select: { trackId: true },
      }),
      this.prisma.listeningEvent.groupBy({
        by: ['trackId'],
        where: { userId, isServerVerified: true },
        _count: { trackId: true },
        orderBy: { _count: { trackId: 'desc' } },
        take: 100,
      }),
      this.prisma.userPreference.findUnique({
        where: { userId },
        select: { favoriteArtists: true },
      }),
      this.prisma.userFollowedArtist.findMany({
        where: { userId },
        take: 100,
        select: { artistKey: true, artistName: true },
      }),
    ]);

    const excludedIds = new Set([
      ...recent.map((item) => item.trackId),
      ...favorites.map((item) => item.trackId),
    ]);

    // Onboarding artist choices are a first-class cold-start signal. Genre
    // preferences are not applied yet because the canonical Track schema has
    // no verified genre taxonomy; do not infer genres from titles/providers.
    const favoriteArtistNames = [
      ...new Set(
        (preference?.favoriteArtists ?? [])
          .map((name) => name.trim())
          .filter(Boolean),
      ),
    ];
    // Following an artist is stronger, more intentional than an incidental play.
    // The name survives across Apple/iTunes and canonical catalog IDs, while
    // catalog:<id> follows can resolve directly to a canonical Artist row.
    const followedNames = [...new Set(
      followed.map((item) => item.artistName?.trim())
        .filter((name): name is string => Boolean(name)),
    )];
    const followedCatalogIds = followed
      .filter((item) => item.artistKey.startsWith('catalog:'))
      .map((item) => item.artistKey.substring('catalog:'.length));
    const lookupNames = [...new Set([...favoriteArtistNames, ...followedNames])];
    const preferredArtists = lookupNames.length > 0
      ? await this.prisma.artist.findMany({
          where: {
            name: { in: lookupNames, mode: 'insensitive' },
          },
          select: { id: true, name: true },
        })
      : [];
    const preferredByName = new Map(
      preferredArtists.map((artist) => [artist.name.toLowerCase(), artist.id]),
    );
    const preferredArtistIds = favoriteArtistNames
      .map((name) => preferredByName.get(name.toLowerCase()))
      .filter((id): id is string => Boolean(id));

    const followedArtistIds = [...new Set([
      ...followedCatalogIds,
      ...followedNames.map((name) => preferredByName.get(name.toLowerCase()))
        .filter((id): id is string => Boolean(id)),
    ])];

    // Saved songs form a second strong signal independent of listening
    // sessions; users with no plays yet can still discover similar artists.
    const artistCounts = new Map<string, number>();
    const favoriteArtistCounts = new Map<string, number>();
    const referenceTrackIds = [...new Set([
      ...listening.map((item) => item.trackId),
      ...favorites.map((item) => item.trackId),
    ])];
    if (referenceTrackIds.length > 0) {
      const referenceTracks = await this.prisma.track.findMany({
        where: { id: { in: referenceTrackIds } },
        select: { id: true, artistId: true },
      });
      const artistByTrack = new Map(
        referenceTracks.map((track) => [track.id, track.artistId]),
      );
      for (const event of listening) {
        const artistId = artistByTrack.get(event.trackId);
        if (artistId) {
          artistCounts.set(artistId, (artistCounts.get(artistId) ?? 0) + event._count.trackId);
        }
      }
      for (const favorite of favorites) {
        const artistId = artistByTrack.get(favorite.trackId);
        if (artistId) {
          favoriteArtistCounts.set(artistId,
            (favoriteArtistCounts.get(artistId) ?? 0) + 1);
        }
      }
    }
    const favoriteArtistIds = [...favoriteArtistCounts.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, 6).map(([artistId]) => artistId);
    const listenedArtistIds = [...artistCounts.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, 6).map(([artistId]) => artistId);
    // Stage 1: candidate recall from follows, explicit preferences,
    // library affinity, and qualified listening events. Stronger signals
    // get the first candidate window; stage 2 keeps artist diversity.
    const artistIds = [...new Set([
      ...followedArtistIds,
      ...preferredArtistIds,
      ...favoriteArtistIds,
      ...listenedArtistIds,
    ])].slice(0, 12);

    if (artistIds.length === 0) {
      return this.popularFallback(territory, excludedIds);
    }
    const followedArtistIdSet = new Set(followedArtistIds);
    const favoriteArtistIdSet = new Set(favoriteArtistIds);
    const preferredArtistIdSet = new Set(preferredArtistIds);

    // Fetch a bounded candidate window per artist. A single globally ordered
    // LIMIT can be monopolized by one prolific artist and starve every other
    // artist before rights filtering or the two-per-artist diversity cap.
    const candidatesByArtist = await Promise.all(artistIds.map((artistId) =>
      this.prisma.track.findMany({
        where: {
          artistId,
          id: { notIn: [...excludedIds] },
        },
        orderBy: [{ album: { releaseDate: 'desc' } }, { title: 'asc' }],
        take: 12,
        select: { id: true, artistId: true },
      }),
    ));

    const rankedCandidates: CandidateTrack[] = [];
    const maxCandidates = Math.max(0, ...candidatesByArtist.map((items) => items.length));
    for (let index = 0; index < maxCandidates; index += 1) {
      for (const artistCandidates of candidatesByArtist) {
        const candidate = artistCandidates[index];
        if (candidate) rankedCandidates.push(candidate);
      }
    }

    const personalized = await this.selectPlayable(
      rankedCandidates,
      territory,
      (track) => followedArtistIdSet.has(track.artistId)
          ? 'Because you follow this artist'
          : preferredArtistIdSet.has(track.artistId)
            ? 'Because you chose this artist'
            : favoriteArtistIdSet.has(track.artistId)
              ? 'More from your favorite artists'
              : 'Because you listen to this artist',
    );
    // Known artists may have no playable tracks in this territory. Still show
    // available popular music instead of leaving the recommendation rail empty.
    return personalized.length > 0
      ? personalized
      : this.popularFallback(territory, excludedIds);
  }

  private async popularFallback(
    territory: string,
    excludedIds: Set<string>,
  ): Promise<RecommendationItem[]> {
    const popular = await this.prisma.listeningEvent.groupBy({
      by: ['trackId'],
      where: { isServerVerified: true },
      _count: { trackId: true },
      orderBy: { _count: { trackId: 'desc' } },
      take: 60,
    });
    const ids = popular
      .map((item) => item.trackId)
      .filter((id) => !excludedIds.has(id));
    if (ids.length === 0) return [];

    const tracks = await this.prisma.track.findMany({
      where: { id: { in: ids } },
      select: { id: true, artistId: true },
    });
    const byId = new Map(tracks.map((track) => [track.id, track]));
    const ranked = ids.map((id) => byId.get(id)).filter((track): track is CandidateTrack => Boolean(track));
    return this.selectPlayable(ranked, territory, () => 'Popular on Breezze');
  }

  private async selectPlayable(
    candidates: CandidateTrack[],
    territory: string,
    reasonFor: (track: CandidateTrack) => string,
  ): Promise<RecommendationItem[]> {
    const selected: RecommendationItem[] = [];
    const artistCounts = new Map<string, number>();
    const playableIds = await this.rights.filterFullStream(
      candidates.map((track) => track.id),
      territory,
    );

    for (const track of candidates) {
      if (selected.length >= 12) break;
      if (!playableIds.has(track.id)) continue;
      const count = artistCounts.get(track.artistId) ?? 0;
      if (count >= 2) continue;
      artistCounts.set(track.artistId, count + 1);
      selected.push({ trackId: track.id, reason: reasonFor(track) });
    }
    return selected;
  }
}
