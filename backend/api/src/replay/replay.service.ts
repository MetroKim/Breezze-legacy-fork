import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { RightsDecisionService } from '../rights/rights-decision.service';

export interface ReplaySummary {
  totalPlays: number;
  topSongIds: { id: string; title: string; artist: string; plays: number }[];
  topArtistIds: { id: string; name: string; plays: number }[];
}

@Injectable()
export class ReplayService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly rights: RightsDecisionService,
  ) {}

  async summary(userId: string, edgeTerritory?: string, year?: number): Promise<ReplaySummary> {
    const territory = edgeTerritory?.trim().toUpperCase() ?? '';
    const rawEvents = await this.prisma.listeningEvent.findMany({
      where: {
        userId,
        isServerVerified: true,
        ...(year == null ? {} : {
          createdAt: {
            gte: new Date(Date.UTC(year, 0, 1)),
            lt: new Date(Date.UTC(year + 1, 0, 1)),
          },
        }),
      },
      select: { trackId: true },
    });
    const visibleTrackIds = await this.rights.filterMetadataDisplay(
      [...new Set(rawEvents.map((event) => event.trackId))],
      territory,
    );
    const events = rawEvents.filter((event) => visibleTrackIds.has(event.trackId));

    const songCounts = new Map<string, number>();
    for (const event of events) {
      songCounts.set(event.trackId, (songCounts.get(event.trackId) ?? 0) + 1);
    }

    const trackIds = [...songCounts.keys()];
    const tracks = trackIds.length
      ? await this.prisma.track.findMany({
          where: { id: { in: trackIds } },
          select: { id: true, title: true, artist: { select: { id: true, name: true } } },
        })
      : [];

    const artistCounts = new Map<string, number>();
    for (const track of tracks) {
      const plays = songCounts.get(track.id) ?? 0;
      artistCounts.set(track.artist.id, (artistCounts.get(track.artist.id) ?? 0) + plays);
    }

    const topSongIds = [...songCounts.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, 10)
      .map(([id, plays]) => {
        const track = tracks.find((item) => item.id === id);
        return {
          id,
          title: track?.title ?? 'Unknown track',
          artist: track?.artist.name ?? 'Unknown artist',
          plays,
        };
      });

    const topArtistIds = [...artistCounts.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, 10)
      .map(([id, plays]) => ({
        id,
        name: tracks.find((item) => item.artist.id === id)?.artist.name ?? 'Unknown artist',
        plays,
      }));

    return { totalPlays: events.length, topSongIds, topArtistIds };
  }
}
