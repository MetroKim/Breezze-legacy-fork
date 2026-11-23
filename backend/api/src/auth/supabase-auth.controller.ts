import {
  Body,
  Controller,
  Header,
  HttpCode,
  HttpStatus,
  Post,
  UseGuards,
} from '@nestjs/common';
import { IsEmail, IsJWT, IsString, MaxLength, MinLength } from 'class-validator';
import { CurrentUser } from './current-user.decorator';
import { JwtAuthGuard } from './jwt-auth.guard';
import { SupabaseAuthBridge } from './supabase-auth.bridge';

class SupabaseExchangeDto {
  @IsString()
  @IsJWT()
  accessToken!: string;
}

class SupabaseClaimDto extends SupabaseExchangeDto {
  @IsEmail()
  @MaxLength(254)
  email!: string;

  @IsString()
  @MinLength(1)
  @MaxLength(128)
  legacyPassword!: string;
}

@Controller('auth/supabase')
export class SupabaseAuthController {
  constructor(private readonly bridge: SupabaseAuthBridge) {}

  // Supabase already validated credentials; verify its current access
  // token server-side before minting a Breezze session family.
  @Post('exchange')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'private, no-store')
  exchange(@Body() dto: SupabaseExchangeDto) {
    return this.bridge.exchange(dto.accessToken);
  }

  @Post('claim')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'private, no-store')
  claim(@Body() dto: SupabaseClaimDto) {
    return this.bridge.claimLegacy(dto.accessToken, dto.email, dto.legacyPassword);
  }

  // Existing Breezze password users must prove *both* identities before
  // linking. There is no silent email-based account takeover.
  @Post('link')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'private, no-store')
  @UseGuards(JwtAuthGuard)
  link(@CurrentUser() userId: string, @Body() dto: SupabaseExchangeDto) {
    return this.bridge.link(userId, dto.accessToken);
  }
}
