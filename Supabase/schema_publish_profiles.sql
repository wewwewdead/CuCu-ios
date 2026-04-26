--------------------------------------------------------------------------------
-- CuCu — Publish Profiles schema
--
-- Idempotent: every statement uses `if not exists` / `drop policy if exists`
-- so re-running this file in the Supabase SQL Editor is safe. This is the
-- canonical schema for the Publish + Native Public Viewer phase.
--
-- WHERE TO RUN:
--   Supabase Dashboard → SQL Editor → New query → paste this whole file → Run.
--
-- WHAT'S CREATED:
--   1. public.profiles               (one row per published profile)
--   2. public.profile_assets         (one row per uploaded image asset)
--   3. updated_at trigger on profiles
--   4. RLS policies on both tables
--   5. Storage RLS policies for the `profile-assets` bucket
--
-- ABOUT KEYS:
--   - The mobile app uses the *anon (publishable)* key only. RLS below is
--     what keeps users honest when running with that key.
--   - service_role bypasses RLS. Never embed it in the client. Use it only
--     in server-side admin tooling.
--
-- STORAGE BUCKET (manual step before running storage policies below):
--   Storage → New bucket → Name: profile-assets → Public: ON.
--
-- COLUMN NAMING NOTE:
--   `design_json` carries the JSON-encoded `ProfileDocument` (CuCu v2 scene
--   graph). The historical name "design" predates the v2 rename — the
--   column itself remains stable so existing rows keep working. The native
--   iOS viewer decodes it via `ProfileDocument(from:)` directly.
--------------------------------------------------------------------------------

create extension if not exists pgcrypto;
create extension if not exists "uuid-ossp";

--------------------------------------------------------------------------------
-- Tables
--------------------------------------------------------------------------------

create table if not exists public.profiles (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null references auth.users(id) on delete cascade,
    username        text not null unique,
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

-- Migration for older deployments: the prototype carried `display_name`
-- and `bio` columns that the iOS app stopped writing. Drop them if
-- they exist so the schema converges on a single source of truth (the
-- canvas inside `design_json`). `if exists` keeps the statement
-- idempotent for fresh installs that never had the columns.
alter table public.profiles drop column if exists display_name;
alter table public.profiles drop column if exists bio;

create index if not exists profiles_user_idx on public.profiles(user_id);
create unique index if not exists profiles_username_lower_idx
    on public.profiles (lower(username));

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
-- updated_at trigger
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
-- Path layout (enforced by the policies + by the iOS publish service):
--   profile-assets/
--     user_<auth.uid()>/
--       profile_<profileId>/
--         block_<nodeId>.jpg
--         gallery_<imageId>.jpg
--         container_<nodeId>.jpg
--         background.jpg
--
-- Policies use TWO redundant predicates as defense-in-depth:
--   (a) `(storage.foldername(name))[1] = 'user_' || auth.uid()::text`
--   (b) `name like 'user_' || auth.uid()::text || '/%'`
-- Either alone blocks cross-user writes; together they leave no room for
-- unusual path shapes to slip past one check while satisfying the other.
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
-- Verification queries (paste individually into the SQL Editor)
--------------------------------------------------------------------------------

-- 1. RLS enabled on both tables?
-- select relname, relrowsecurity from pg_class
--  where relname in ('profiles', 'profile_assets');

-- 2. Every policy on the schemas this app touches
-- select schemaname, tablename, policyname, cmd from pg_policies
--  where schemaname in ('public', 'storage') order by schemaname, tablename, policyname;

-- 3. Storage bucket exists and is public?
-- select id, name, public, created_at from storage.buckets where id = 'profile-assets';

-- 4. Recent published profiles
-- select id, username, is_published, created_at, updated_at from public.profiles
--  order by created_at desc limit 10;

-- 5. Recent profile_assets rows
-- select profile_id, asset_type, storage_path, public_url, created_at
--   from public.profile_assets order by created_at desc limit 20;
