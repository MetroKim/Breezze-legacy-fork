import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { PassportModule } from '@nestjs/passport';
import { AuthService } from './auth.service';
import { AuthController } from './auth.controller';
import { SocialAuthController } from './social-auth.controller';
import { SocialAuthService } from './social-auth.service';
import { JwtStrategy } from './jwt.strategy';
import { SupabaseAuthBridge } from './supabase-auth.bridge';
import { SupabaseAuthController } from './supabase-auth.controller';
import { JwtAuthGuard } from './jwt-auth.guard';

@Module({
  imports: [
    PassportModule,
    JwtModule.register({
      secret: process.env.JWT_SECRET ?? 'dev-only-secret-change-me',
    }),
  ],
  controllers: [AuthController, SocialAuthController, SupabaseAuthController],
  providers: [AuthService, SocialAuthService, SupabaseAuthBridge, JwtStrategy, JwtAuthGuard],
  exports: [AuthService, JwtAuthGuard],
})
export class AuthModule {}
