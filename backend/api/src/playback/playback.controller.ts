import {
  Body,
  Headers,
  Controller,
  HttpCode,
  HttpStatus,
  Post,
  Param,
  ParseUUIDPipe,
  UseGuards,
} from '@nestjs/common';
import { IsIn, IsInt, IsOptional, IsString, IsUUID, Matches, Min } from 'class-validator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { CurrentUser } from '../auth/current-user.decorator';
import { PlaybackResolveService } from './playback-resolve.service';
import { externalRecordingId, PlaybackSessionService } from './playback-session.service';

export class ProviderResolveDto {
  @IsString()
  providerId!: string;

  @IsString()
  providerTrackId!: string;

  @IsString()
  canonicalTrackId!: string;

  @IsOptional()
  @IsString()
  territory?: string;
}

export class StartPlaybackSessionDto {
  @IsOptional() @Matches(externalRecordingId)
  externalTrackId?: string;
  @IsOptional() @IsUUID() trackId?: string;
  @IsOptional() @IsIn(['AAC_128', 'AAC_256', 'LOSSLESS', 'HI_RES'])
  requestedQuality?: string;
  @IsOptional() @IsString() providerId?: string;
  @IsOptional() @IsString() providerTrackId?: string;
  @IsOptional() @IsUUID() canonicalTrackId?: string;
}

export class PlaybackHeartbeatDto {
  @IsUUID() eventId!: string;
  @IsInt() @Min(1) sequence!: number;
}

export class ResolveDto {
  @IsString()
  trackId!: string;

  // Deprecated compatibility field. Playback authorization uses only the
  // country injected by the trusted Cloudflare Worker.
  @IsOptional()
  @IsString()
  territory?: string;

  @IsOptional()
  @IsIn(['AAC_128', 'AAC_256', 'LOSSLESS', 'HI_RES'])
  requestedQuality?: string;
}

@Controller('playback')
export class PlaybackController {
  constructor(
    private readonly resolver: PlaybackResolveService,
    private readonly sessions: PlaybackSessionService,
  ) {}

  @Post('sessions')
  @HttpCode(HttpStatus.CREATED)
  @UseGuards(JwtAuthGuard)
  startSession(@CurrentUser() userId: string, @Headers('x-breezze-country') edgeCountry: string | undefined, @Body() dto: StartPlaybackSessionDto) {
    return this.sessions.start(userId, edgeCountry, dto);
  }

  @Post('sessions/:sessionId/heartbeat')
  @HttpCode(HttpStatus.OK)
  @UseGuards(JwtAuthGuard)
  heartbeat(@CurrentUser() userId: string, @Param('sessionId', new ParseUUIDPipe()) sessionId: string, @Body() dto: PlaybackHeartbeatDto) {
    return this.sessions.heartbeat(userId, sessionId, dto.eventId, dto.sequence);
  }

  @Post('sessions/:sessionId/pause')
  @HttpCode(HttpStatus.OK)
  @UseGuards(JwtAuthGuard)
  pauseSession(@CurrentUser() userId: string, @Param('sessionId', new ParseUUIDPipe()) sessionId: string) {
    return this.sessions.pause(userId, sessionId);
  }

  @Post('sessions/:sessionId/resume')
  @HttpCode(HttpStatus.OK)
  @UseGuards(JwtAuthGuard)
  resumeSession(@CurrentUser() userId: string, @Param('sessionId', new ParseUUIDPipe()) sessionId: string) {
    return this.sessions.resume(userId, sessionId);
  }

  @Post('sessions/:sessionId/stop')
  @HttpCode(HttpStatus.OK)
  @UseGuards(JwtAuthGuard)
  stopSession(@CurrentUser() userId: string, @Param('sessionId', new ParseUUIDPipe()) sessionId: string) {
    return this.sessions.stop(userId, sessionId);
  }

  @Post('provider/resolve')
  @HttpCode(HttpStatus.OK)
  @UseGuards(JwtAuthGuard)
  resolveProvider(
    @CurrentUser() userId: string,
    @Headers('x-breezze-country') edgeCountry: string | undefined,
    @Body() dto: ProviderResolveDto,
  ) {
    return this.resolver.resolveProvider(userId, dto, edgeCountry);
  }

  @Post('resolve')
  @HttpCode(HttpStatus.OK)
  @UseGuards(JwtAuthGuard)
  resolve(
    @CurrentUser() userId: string,
    @Headers('x-breezze-country') edgeCountry: string | undefined,
    @Body() dto: ResolveDto,
  ) {
    return this.resolver.resolve(userId, dto, edgeCountry);
  }
}
