import {
  Body, Controller, Get, Header, HttpCode, HttpStatus, Param, Post, Query, Res, UseGuards,
} from '@nestjs/common';
import { IsOptional, IsString, MaxLength, MinLength } from 'class-validator';
import type { Response } from 'express';
import { SocialAuthService } from './social-auth.service';
import { JwtAuthGuard } from './jwt-auth.guard';
import { CurrentUser } from './current-user.decorator';

class PollSocialFlowDto {
  @IsString()
  @MinLength(36)
  @MaxLength(36)
  id!: string;

  @IsString()
  @MinLength(32)
  @MaxLength(256)
  secret!: string;
}

class AppleCallbackDto {
  @IsString()
  @MinLength(32)
  @MaxLength(256)
  state!: string;

  @IsOptional()
  @IsString()
  @MaxLength(2048)
  code?: string;

  // Apple sends a URL-encoded profile on first consent. Identity and email
  // continue to come exclusively from the verified ID token.
  @IsOptional()
  @IsString()
  @MaxLength(8192)
  user?: string;

  @IsOptional()
  @IsString()
  @MaxLength(128)
  error?: string;
}

@Controller('auth/social')
export class SocialAuthController {
  constructor(private readonly social: SocialAuthService) {}

  @Header('Cache-Control', 'no-store')
  @Get('providers')
  providers() {
    return this.social.providers();
  }

  @Header('Cache-Control', 'no-store')
  @Post('auth0/link/start')
  @UseGuards(JwtAuthGuard)
  @HttpCode(HttpStatus.OK)
  startAuth0Link(@CurrentUser() userId: string) {
    return this.social.start('auth0', userId);
  }

  @Header('Cache-Control', 'no-store')
  @Post(':provider/start')
  @HttpCode(HttpStatus.OK)
  start(@Param('provider') provider: string) {
    return this.social.start(provider);
  }

  @Header('Cache-Control', 'no-store')
  @Post('poll')
  @HttpCode(HttpStatus.OK)
  poll(@Body() body: PollSocialFlowDto) {
    return this.social.poll(body.id, body.secret);
  }

  @Header('Cache-Control', 'no-store')
  @Get('callback/google')
  async googleCallback(
    @Query('state') state: string,
    @Query('code') code: string | undefined,
    @Query('error') error: string | undefined,
    @Res() res: Response,
  ) {
    const ok = await this.social.callback('google', state, code, error);
    this.respond(res, ok);
  }

  @Header('Cache-Control', 'no-store')
  @Get('callback/auth0')
  async auth0Callback(
    @Query('state') state: string,
    @Query('code') code: string | undefined,
    @Query('error') error: string | undefined,
    @Res() res: Response,
  ) {
    const ok = await this.social.callback('auth0', state, code, error);
    this.respond(res, ok);
  }

  @Header('Cache-Control', 'no-store')
  @Post('callback/apple')
  async appleCallback(@Body() body: AppleCallbackDto, @Res() res: Response) {
    const ok = await this.social.callback('apple', body.state ?? '',
      body.code, body.error);
    this.respond(res, ok);
  }

  private respond(res: Response, successful: boolean) {
    // Never put Breezze session or one-time poll secret into a redirect,
    // browser cookie or rendered HTML. Only the app that initiated the
    // pairing can retrieve its encrypted one-time completion via POST poll.
    res.status(successful ? 200 : 400)
      .type('html')
      .send(
        '<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width, initial-scale=1">' +
        '<title>Breezze sign-in</title></head><body style="background:#09090c;color:#f7f7f9;' +
        'font-family:system-ui,sans-serif;max-width:480px;margin:15vh auto;padding:28px">' +
        '<h1>' + (successful ? 'You are signed in' : 'Sign-in could not finish') + '</h1>' +
        '<p>' + (successful ? 'Return to Breezze. You may safely close this browser tab.' :
          'Return to Breezze and retry, or use email sign-in.') + '</p>' +
        '</body></html>',
      );
  }
}
