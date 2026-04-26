--------------------------------------------------------------------------------
-- Migration: drop `display_name` and `bio` from `public.profiles`.
--
-- WHY:
--   The iOS app removed both fields from the publish flow and from the
--   public viewer. Identity on a published profile is whatever the
--   author drew on the canvas itself (text nodes, hero containers,
--   headers); duplicate fields above the canvas split the source of
--   truth and confused the design.
--
-- WHEN TO RUN:
--   Once, on any project that previously ran `schema_phase4.sql` or an
--   older `schema_publish_profiles.sql` that included these columns.
--   Idempotent (`if exists`), so re-running is safe.
--
-- HOW TO RUN:
--   Supabase Dashboard → SQL Editor → New query → paste this file → Run.
--
-- DATA NOTE:
--   Dropping a column **deletes the data in that column** for every
--   row. There is no way to recover it from inside the database
--   afterward — only via a backup. If you need to keep the values
--   around for any reason (analytics, migration to canvas content,
--   etc.), export them first:
--     create table profiles_archive_displayname_bio as
--       select id, username, display_name, bio from public.profiles
--        where display_name is not null or bio is not null;
--   then run the drops below.
--------------------------------------------------------------------------------

alter table public.profiles drop column if exists display_name;
alter table public.profiles drop column if exists bio;

-- Verify the columns are gone (uncomment to check):
-- select column_name from information_schema.columns
--  where table_schema = 'public' and table_name = 'profiles'
--  order by ordinal_position;
