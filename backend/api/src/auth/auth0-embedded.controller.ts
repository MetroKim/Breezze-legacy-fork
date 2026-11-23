import {
  Body, Controller, Header, HttpCode, HttpStatus, Post, UseGuards,
} from '@nestjs/common';
import { IsEmail, IsOptional, IsString, MaxLength, MinLength } from 'class-validator';
import { CurrentUser } from './current-user.decorator';
import { JwtAuthGuard } from './jwt-auth.guard';
import { SocialAuthService } from './social-auth.service';

class EmbeddedCredentialsDto {
  @IsEmail()
  @MaxLength(254)
  email!: string;

  @IsString()
  @MinLength(1)
  @MaxLength(128)
  password!: string;
}

class EmbeddedRegisterDto extends EmbeddedCredentialsDto {
  @MinLength(12)
  declare password: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  displayName?: string;
}

class EmbeddedResetDto {
  @IsEmail()
  @MaxLength(254)
  email!: string;
}

/** Breezze-rendered sign-in: Auth0 credential exchange is backend-only. */
@Controller('auth/auth0')
export class Auth0EmbeddedController {
  constructor(private readonly auth0: SocialAuthService) {}

  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.OK)
  @Post('login')
  login(@Body() body: EmbeddedCredentialsDto) {
    return this.auth0.embeddedLogin(body.email, body.password);
  }

  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.ACCEPTED)
  @Post('register')
  register(@Body() body: EmbeddedRegisterDto) {
    return this.auth0.embeddedRegister(body.email, body.password, body.displayName);
  }

  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.ACCEPTED)
  @Post('password/reset')
  reset(@Body() body: EmbeddedResetDto) {
    return this.auth0.embeddedReset(body.email);
  }

  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.OK)
  @UseGuards(JwtAuthGuard)
  @Post('link')
  link(@CurrentUser() userId: string, @Body() body: EmbeddedCredentialsDto) {
    return this.auth0.embeddedLink(userId, body.email, body.password);
  }
}
