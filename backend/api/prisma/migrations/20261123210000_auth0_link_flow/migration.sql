-- One-time Auth0 account-link requests are bound to the Breezze session
-- that started the flow. The signed Auth0 callback must prove email ownership
-- independently before the provider subject can be linked to that account.
ALTER TABLE "SocialLoginFlow" ADD COLUMN "linkUserId" TEXT;
