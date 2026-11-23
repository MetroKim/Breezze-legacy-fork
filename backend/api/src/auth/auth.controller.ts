import {
  Body,
  Controller,
  Delete,
  Get,
  Header,
  HttpCode,
  HttpStatus,
  Post,
  Param,
  UseGuards,
} from '@nestjs/common';
import { IsEmail, IsString, IsOptional, Matches, MaxLength, MinLength } from 'class-validator';
import { AuthService } from './auth.service';
import { JwtAuthGuard } from './jwt-auth.guard';
import { CurrentUser } from './current-user.decorator';
import { CurrentSession } from './current-session.decorator';

export class RegisterDto {
  @IsEmail()
  email!: string;

  @IsString()
  @MinLength(12)
  @MaxLength(128)
  password!: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  displayName?: string;
}

export class LoginDto {
  @IsEmail()
  email!: string;

  @IsString()
  @MinLength(1)
  password!: string;
}

export class PasswordReauthDto {
  @IsString()
  @MinLength(1)
  @MaxLength(128)
  password!: string;
}

export class TotpCodeDto {
  @IsString()
  @Matches(/^(?:\d{6}|[A-Fa-f0-9]{4}(?:-?[A-Fa-f0-9]{4}){3})$/)
  code!: string;
}

export class MfaRecoveryRegenerationDto {
  @IsString()
  @MinLength(1)
  @MaxLength(128)
  password!: string;

  @IsString()
  @Matches(/^(?:\d{6}|[A-Fa-f0-9]{4}(?:-?[A-Fa-f0-9]{4}){3})$/)
  code!: string;
}

export class RefreshDto {
  @IsString()
  @MinLength(32)
  @MaxLength(256)
  refreshToken!: string;
}

@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Post('register')
  register(@Body() dto: RegisterDto) {
    return this.auth.register(dto.email, dto.password, dto.displayName);
  }

  @Post('login')
  @HttpCode(HttpStatus.OK)
  login(@Body() dto: LoginDto) {
    return this.auth.login(dto.email, dto.password);
  }

  @Post('refresh')
  @HttpCode(HttpStatus.OK)
  refresh(@Body() dto: RefreshDto) {
    return this.auth.refresh(dto.refreshToken);
  }

  @Post('logout')
  @HttpCode(HttpStatus.OK)
  logout(@Body() dto: RefreshDto) {
    return this.auth.logout(dto.refreshToken);
  }

  @Post('logout-all')
  @HttpCode(HttpStatus.OK)
  @UseGuards(JwtAuthGuard)
  async logoutAllDevices(@CurrentUser() userId: string) {
    await this.auth.revokeAllSessions(userId);
    return { revoked: true };
  }

  @Post('mfa/setup')
  @Header('Cache-Control', 'private, no-store')
  @UseGuards(JwtAuthGuard)
  beginMfaSetup(@CurrentUser() userId: string, @Body() dto: PasswordReauthDto) {
    return this.auth.beginMfaSetup(userId, dto.password);
  }

  @Post('mfa/setup/verify')
  @Header('Cache-Control', 'private, no-store')
  @UseGuards(JwtAuthGuard)
  verifyMfaSetup(
    @CurrentUser() userId: string,
    @CurrentSession() sessionId: string,
    @Body() dto: TotpCodeDto,
  ) {
    return this.auth.verifyMfaSetup(userId, sessionId, dto.code);
  }

  @Post('mfa/recovery-codes/regenerate')
  @Header('Cache-Control', 'private, no-store')
  @UseGuards(JwtAuthGuard)
  regenerateMfaRecoveryCodes(
    @CurrentUser() userId: string,
    @CurrentSession() sessionId: string,
    @Body() dto: MfaRecoveryRegenerationDto,
  ) {
    return this.auth.regenerateMfaRecoveryCodes(userId, sessionId, dto.password, dto.code);
  }

  @Post('mfa/verify')
  @Header('Cache-Control', 'private, no-store')
  @UseGuards(JwtAuthGuard)
  verifyMfa(
    @CurrentUser() userId: string,
    @CurrentSession() sessionId: string,
    @Body() dto: TotpCodeDto,
  ) {
    return this.auth.verifyMfa(userId, sessionId, dto.code);
  }

  @Get('me')
  @UseGuards(JwtAuthGuard)
  me(@CurrentUser() userId: string) {
    return this.auth.profile(userId);
  }

  @Get('sessions')
  @UseGuards(JwtAuthGuard)
  sessions(@CurrentUser() userId: string) {
    return this.auth.listSessions(userId);
  }

  @Delete('sessions/:id')
  @UseGuards(JwtAuthGuard)
  async revokeSession(@CurrentUser() userId: string, @Param('id') sessionId: string) {
    await this.auth.revokeSession(userId, sessionId);
    return { revoked: true };
  }
}
