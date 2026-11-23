import { BadRequestException, Controller, Get, Headers, Param, UseGuards } from '@nestjs/common';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { CurrentUser } from '../auth/current-user.decorator';
import { ReplayService } from './replay.service';

@Controller('replay')
@UseGuards(JwtAuthGuard)
export class ReplayController {
  constructor(private readonly replay: ReplayService) {}

  @Get('year/:year')
  yearly(
    @CurrentUser() userId: string,
    @Headers('x-breezze-country') edgeCountry: string | undefined,
    @Param('year') rawYear: string,
  ) {
    if (!/^20[0-9]{2}$/.test(rawYear)) {
      throw new BadRequestException('REPLAY_YEAR_INVALID');
    }
    const year = Number(rawYear);
    if (year > new Date().getUTCFullYear()) {
      throw new BadRequestException('REPLAY_YEAR_IN_FUTURE');
    }
    return this.replay.summary(userId, edgeCountry, year);
  }

  @Get()
  summary(
    @CurrentUser() userId: string,
    @Headers('x-breezze-country') edgeCountry: string | undefined,
  ) {
    return this.replay.summary(userId, edgeCountry);
  }
}
