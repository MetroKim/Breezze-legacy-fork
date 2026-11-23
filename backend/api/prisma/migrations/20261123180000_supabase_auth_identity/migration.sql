-- An explicit identity bridge permits Breezze sessions to coexist with
-- Supabase Auth while users and data are migrated safely.
-- Applied to whichever PostgreSQL/schema Prisma is configured to use;
-- does not modify the unrelated paused Supabase project.
CREATE TABLE "SupabaseAuthIdentity" (
  "userId" TEXT NOT NULL,
  "subject" TEXT NOT NULL,
  "linkedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "SupabaseAuthIdentity_pkey" PRIMARY KEY ("userId")
);
CREATE UNIQUE INDEX "SupabaseAuthIdentity_subject_key"
  ON "SupabaseAuthIdentity"("subject");
ALTER TABLE "SupabaseAuthIdentity" ADD CONSTRAINT
  "SupabaseAuthIdentity_userId_fkey"
  FOREIGN KEY ("userId") REFERENCES "User"("id")
  ON DELETE CASCADE ON UPDATE CASCADE;
