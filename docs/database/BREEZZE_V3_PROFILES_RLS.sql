-- Breezze v3: reproducible *initial* profile schema for a fresh Supabase project.
-- Already applied and audited on project djwvyjtebmsavhcrmhxf.
-- Do not rerun against the existing project; subsequent changes need their own migration.
-- No existing Breezze Prisma/library/catalog records are moved by this script.

begin;

create schema if not exists private;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (display_name is null or char_length(display_name) <= 80),
  handle text unique check (handle is null or handle ~ '^[a-z0-9_]{3,24}$'),
  avatar_url text,
  country text check (country is null or country ~ '^[A-Z]{2}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Supabase anonymous sessions use the authenticated PostgreSQL role;
-- forbid such identities from accessing durable Breezze profile data.
create policy "profiles_select_own" on public.profiles
  for select to authenticated
  using (
    (select auth.uid()) = id
    and ((select auth.jwt()) ->> 'is_anonymous') is distinct from 'true'
  );

create policy "profiles_insert_own" on public.profiles
  for insert to authenticated
  with check (
    (select auth.uid()) = id
    and ((select auth.jwt()) ->> 'is_anonymous') is distinct from 'true'
  );

create policy "profiles_update_own" on public.profiles
  for update to authenticated
  using (
    (select auth.uid()) = id
    and ((select auth.jwt()) ->> 'is_anonymous') is distinct from 'true'
  )
  with check (
    (select auth.uid()) = id
    and ((select auth.jwt()) ->> 'is_anonymous') is distinct from 'true'
  );

revoke all on public.profiles from anon;
grant select, insert, update on public.profiles to authenticated;

-- Trigger is SECURITY DEFINER because the Supabase Auth role must be able
-- to create the corresponding public row. Keep function in a private,
-- unexposed schema with a fixed search_path and no public EXECUTE grant.
create function private.create_breezze_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles(id, display_name, avatar_url)
  values (
    new.id,
    left(nullif(btrim(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', '')), ''), 80),
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function private.create_breezze_profile() from public, anon, authenticated;

create trigger on_breezze_auth_user_created
after insert on auth.users
for each row execute function private.create_breezze_profile();

insert into public.profiles(id, display_name, avatar_url)
select id,
  left(nullif(btrim(coalesce(raw_user_meta_data ->> 'full_name', raw_user_meta_data ->> 'name', '')), ''), 80),
  nullif(raw_user_meta_data ->> 'avatar_url', '')
from auth.users
on conflict (id) do nothing;

commit;
