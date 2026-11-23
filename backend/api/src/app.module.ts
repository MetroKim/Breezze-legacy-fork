import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { PrismaModule } from './prisma.module';
import { AuthModule } from './auth/auth.module';
import { UsersModule } from './users/users.module';
import { CatalogModule } from './catalog/catalog.module';
import { RightsModule } from './rights/rights.module';
import { PlaybackModule } from './playback/playback.module';
import { LibraryModule } from './library/library.module';
import { SearchModule } from './search/search.module';
import { PlaylistsModule } from './playlists/playlists.module';
import { DownloadsModule } from './downloads/downloads.module';
import { HomeModule } from './home/home.module';
import { LyricsModule } from './lyrics/lyrics.module';
import { RecommendationsModule } from './recommendations/recommendations.module';
import { OnboardingModule } from './onboarding/onboarding.module';
import { ReplayModule } from './replay/replay.module';
import { ClassicalModule } from './classical/classical.module';
import { AdminModule } from './admin/admin.module';
import { ProvidersModule } from './providers/providers.module';
import { NotificationsModule } from './notifications/notifications.module';
import { ModerationModule } from './moderation/moderation.module';
import { DiscoveryModule } from './discovery/discovery.module';
import { SupportModule } from './support/support.module';
import { CloudflareAwareThrottlerGuard } from './cloudflare-aware-throttler.guard';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    PrismaModule,
    AuthModule,
    UsersModule,
    CatalogModule,
    RightsModule,
    PlaybackModule,
    LibraryModule,
    SearchModule,
    PlaylistsModule,
    DownloadsModule,
    HomeModule,
    LyricsModule,
    RecommendationsModule,
    OnboardingModule,
    ReplayModule,
    ClassicalModule,
    AdminModule,
    ProvidersModule,
    NotificationsModule,
    ModerationModule,
    DiscoveryModule,
    SupportModule,
  ],
  providers: [{ provide: APP_GUARD, useClass: CloudflareAwareThrottlerGuard }],
})
export class AppModule {}
