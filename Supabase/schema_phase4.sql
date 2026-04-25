--------------------------------------------------------------------------------
-- Phase 4 schema for the Creative Profile app.
--
-- WHERE TO RUN:
--   Supabase Dashboard → SQL Editor → New query → paste this whole file → Run.
--   It's idempotent (uses `if not exists` and `drop policy if exists`) so you
--   can re-run it after edits without dropping data.
--
-- WHAT'S CREATED:
--   1. public.profiles               (one row per published profile)
--   2. public.profile_assets         (one row per uploaded image asset)
--   3. updated_at trigger on profiles
--   4. RLS policies on both tables
--   5. Storage RLS policies for the `profile-assets` bucket
--
-- ABOUT KEYS:
--   - The mobile app uses the *anon (publishable)* key only. RLS below is what
--     keeps users honest when running with that key.
--   - service_role bypasses RLS. Never embed it in the client. Use it only in
--     server-side admin tooling.
--
-- STORAGE BUCKET (manual step):
--   Storage → New bucket → name: profile-assets → Public: ON.
--   Then run the storage policies at the bottom of this file.
--------------------------------------------------------------------------------

-- Required extensions (gen_random_uuid lives in pgcrypto on newer Supabase
-- projects; uuid-ossp keeps both options happy).
create extension if not exists pgcrypto;
create extension if not exists "uuid-ossp";

--------------------------------------------------------------------------------
-- Tables
--------------------------------------------------------------------------------

create table if not exists public.profiles (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null references auth.users(id) on delete cascade,
    username        text not null unique,
    display_name    text,
    design_json     jsonb not null,
    thumbnail_url   text,
    is_published    boolean not null default true,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    published_at    timestamptz,
    constraint username_format check (
        username ~ '^[a-z0-9_]+$' and char_length(username) between 3 and 30
    )
);

create index if not exists profiles_user_idx on public.profiles(user_id);

create table if not exists public.profile_assets (
    id              uuid primary key default gen_random_uuid(),
    profile_id      uuid not null references public.profiles(id) on delete cascade,
    user_id         uuid not null references auth.users(id) on delete cascade,
    local_path      text,
    storage_path    text not null,
    public_url      text,
    asset_type      text not null,
    created_at      timestamptz not null default now()
);

create index if not exists profile_assets_profile_idx on public.profile_assets(profile_id);
create index if not exists profile_assets_user_idx on public.profile_assets(user_id);

--------------------------------------------------------------------------------
-- updated_at trigger for profiles
--------------------------------------------------------------------------------

create or replace function public.handle_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at
    before update on public.profiles
    for each row execute function public.handle_updated_at();

--------------------------------------------------------------------------------
-- RLS — profiles
--------------------------------------------------------------------------------

alter table public.profiles enable row level security;

drop policy if exists "Published profiles are public-readable" on public.profiles;
create policy "Published profiles are public-readable"
    on public.profiles for select
    using (is_published = true);

drop policy if exists "Owners can read their own profiles" on public.profiles;
create policy "Owners can read their own profiles"
    on public.profiles for select
    using (auth.uid() = user_id);

drop policy if exists "Owners can insert their own profiles" on public.profiles;
create policy "Owners can insert their own profiles"
    on public.profiles for insert
    with check (auth.uid() = user_id);

drop policy if exists "Owners can update their own profiles" on public.profiles;
create policy "Owners can update their own profiles"
    on public.profiles for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists "Owners can delete their own profiles" on public.profiles;
create policy "Owners can delete their own profiles"
    on public.profiles for delete
    using (auth.uid() = user_id);

--------------------------------------------------------------------------------
-- RLS — profile_assets
--------------------------------------------------------------------------------

alter table public.profile_assets enable row level security;

drop policy if exists "Public assets are readable for published profiles"
    on public.profile_assets;
create policy "Public assets are readable for published profiles"
    on public.profile_assets for select
    using (
        exists (
            select 1 from public.profiles
             where profiles.id = profile_assets.profile_id
               and profiles.is_published = true
        )
    );

drop policy if exists "Owners can read their own assets" on public.profile_assets;
create policy "Owners can read their own assets"
    on public.profile_assets for select
    using (auth.uid() = user_id);

drop policy if exists "Owners can insert their own assets" on public.profile_assets;
create policy "Owners can insert their own assets"
    on public.profile_assets for insert
    with check (auth.uid() = user_id);

drop policy if exists "Owners can update their own assets" on public.profile_assets;
create policy "Owners can update their own assets"
    on public.profile_assets for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists "Owners can delete their own assets" on public.profile_assets;
create policy "Owners can delete their own assets"
    on public.profile_assets for delete
    using (auth.uid() = user_id);

--------------------------------------------------------------------------------
-- Storage policies for the `profile-assets` bucket.
--
-- Manual step before running these:
--   Storage → New bucket → Name: profile-assets → Public: ON.
--
-- Policies enforce that authenticated users can only write into a folder
-- named after their auth.uid(), e.g. user_<uid>/profile_<pid>/<file>.jpg.
-- Reads are open because published profiles are intended to be public.
--
-- Each write policy uses TWO redundant predicates as defense-in-depth:
--   (a) `(storage.foldername(name))[1] = 'user_' || auth.uid()::text`
--   (b) `name like 'user_' || auth.uid()::text || '/%'`
-- (a) splits the path into folder components and asserts the first one
-- matches; (b) is a literal prefix check on the raw name. Either alone
-- would already block cross-user writes — together they leave no room
-- for unusual path shapes to slip past one check while satisfying the other.
--------------------------------------------------------------------------------

drop policy if exists "Users can upload to their own folder" on storage.objects;
create policy "Users can upload to their own folder"
    on storage.objects for insert
    with check (
        bucket_id = 'profile-assets'
        and auth.role() = 'authenticated'
        and (storage.foldername(name))[1] = ('user_' || auth.uid()::text)
        and name like ('user_' || auth.uid()::text || '/%')
    );

drop policy if exists "Users can update assets in their own folder" on storage.objects;
create policy "Users can update assets in their own folder"
    on storage.objects for update
    using (
        bucket_id = 'profile-assets'
        and auth.role() = 'authenticated'
        and (storage.foldername(name))[1] = ('user_' || auth.uid()::text)
        and name like ('user_' || auth.uid()::text || '/%')
    );

drop policy if exists "Users can delete assets in their own folder" on storage.objects;
create policy "Users can delete assets in their own folder"
    on storage.objects for delete
    using (
        bucket_id = 'profile-assets'
        and auth.role() = 'authenticated'
        and (storage.foldername(name))[1] = ('user_' || auth.uid()::text)
        and name like ('user_' || auth.uid()::text || '/%')
    );

drop policy if exists "Anyone can read profile-assets" on storage.objects;
create policy "Anyone can read profile-assets"
    on storage.objects for select
    using (bucket_id = 'profile-assets');

--------------------------------------------------------------------------------
-- Verification queries (run individually in the SQL Editor; commented so
-- they can't fire as part of the schema setup).
--
-- After running this file plus creating the storage bucket, paste each of
-- these into a SQL Editor query, uncomment the SELECT, and confirm:
--
--   1. RLS is enabled on both public tables.
--   2. The expected policies are present.
--   3. The `profile-assets` storage bucket exists and is public.
--   4. Recent profiles look right.
--   5. Recent profile_assets rows look right.
--------------------------------------------------------------------------------

-- 1. Confirm RLS is enabled on profiles and profile_assets.
-- select relname, relrowsecurity
--   from pg_class
--  where relname in ('profiles', 'profile_assets');

-- 2. List every RLS policy across the schemas this app touches.
-- select schemaname, tablename, policyname, cmd
--   from pg_policies
--  where schemaname in ('public', 'storage')
--  order by schemaname, tablename, policyname;

-- 3. Confirm the storage bucket exists and is public-readable.
-- select id, name, public, created_at
--   from storage.buckets
--  where id = 'profile-assets';

-- 4. Spot-check the most recent published profiles.
-- select id, username, is_published, created_at, updated_at
--   from public.profiles
--  order by created_at desc
--  limit 10;

-- 5. Spot-check the most recent profile_assets rows.
-- select profile_id, asset_type, storage_path, public_url, created_at
--   from public.profile_assets
--  order by created_at desc
--  limit 20;
