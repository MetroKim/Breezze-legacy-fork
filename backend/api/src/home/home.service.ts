import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { RecommendationsService } from '../recommendations/recommendations.service';

export interface HomeSection {
  sectionType: 'personalized' | 'followed_artists' | 'recently_played' | 'favorites';
  title: string;
  layout: 'rail' | 'grid';
  trackIds: string[];
}

@Injectable()
export class HomeService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly recommendations: RecommendationsService,
  ) {}

  async feed(userId: string, territory?: string): Promise<HomeSection[]> {
    const [recent, favorites, recommendations] = await Promise.all([
      this.prisma.recentlyPlayed.findMany({
        where: { userId },
        orderBy: { playedAt: 'desc' },
        take: 12,
        select: { trackId: true },
      }),
      this.prisma.favorite.findMany({
        where: { userId },
        orderBy: { createdAt: 'desc' },
        take: 12,
        select: { trackId: true },
      }),
      this.recommendations.forUser(userId, territory),
    ]);

    // Artist follows are intentional taste signals: give them a dedicated
    // shelf and do not duplicate those tracks in Made for You.
    const followedTracks = recommendations.filter(
      (item) => item.reason === 'Because you follow this artist',
    );
    const otherRecommendations = recommendations.filter(
      (item) => item.reason !== 'Because you follow this artist',
    );
    const sections: HomeSection[] = [];
    if (followedTracks.length > 0) {
      sections.push({
        sectionType: 'followed_artists',
        title: 'From Artists You Follow',
        layout: 'rail',
        trackIds: followedTracks.map((item) => item.trackId),
      });
    }
    if (otherRecommendations.length > 0) {
      sections.push({
        sectionType: 'personalized',
        title: 'Made for You',
        layout: 'rail',
        trackIds: otherRecommendations.map((item) => item.trackId),
      });
    }
    if (recent.length > 0) {
      sections.push({
        sectionType: 'recently_played',
        title: 'Recently Played',
        layout: 'rail',
        trackIds: recent.map((item) => item.trackId),
      });
    }
    if (favorites.length > 0) {
      sections.push({
        sectionType: 'favorites',
        title: 'Your Favorites',
        layout: 'rail',
        trackIds: favorites.map((item) => item.trackId),
      });
    }
    return sections;
  }

  /** Syncs local history without fabricating a qualified ListeningEvent. */
  async recordRecent(userId: string, trackId: string) {
    const track = await this.prisma.track.findUnique({
      where: { id: trackId },
      select: { id: true },
    });
    if (!track) throw new NotFoundException('TRACK_NOT_FOUND');

    await this.prisma.recentlyPlayed.upsert({
      where: { userId_trackId: { userId, trackId } },
      create: { userId, trackId },
      update: { playedAt: new Date() },
    });
    return { recorded: true };
  }
}
