-- My Paper Trail — Supabase schema (safe to re-run)
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- SAFE ON AN EXISTING PROJECT:
--   * Never drops a table or deletes any rows, photos, or videos.
--   * Creates anything missing and adds any missing columns.
--   * Skips anything that already exists, so running it twice is fine.
--   * Runs as one transaction: if any line errors, NOTHING is changed.

begin;

-- ============================================================
-- Extensions
-- ============================================================
create extension if not exists pgcrypto;

-- ============================================================
-- Tables (created only if they don't exist yet)
-- ============================================================

-- Allowlist of educator emails. Add teacher accounts with:
--   insert into educators (email) values ('you@example.com');
create table if not exists educators (
  email text primary key
);

create table if not exists profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  student text not null,
  week int not null check (week between 1 and 11),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, week)
);

create table if not exists educator_notes (
  id uuid primary key default gen_random_uuid(),
  student_user_id uuid not null references auth.users(id) on delete cascade,
  week int not null check (week between 1 and 11),
  text text not null default '',
  sent_at timestamptz,
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  unique (student_user_id, week)
);

-- ============================================================
-- Columns (added only if missing — existing data is untouched)
-- ============================================================

-- profiles
alter table profiles add column if not exists display_name text not null default '';
alter table profiles add column if not exists updated_at timestamptz not null default now();

-- entries: core
alter table entries add column if not exists submitted_at timestamptz;
alter table entries add column if not exists part1_submitted_at timestamptz;
alter table entries add column if not exists part2_submitted_at timestamptz;
alter table entries add column if not exists confidence_before int;
alter table entries add column if not exists confidence_after int;
alter table entries add column if not exists learned text default '';
alter table entries add column if not exists challenged text default '';
alter table entries add column if not exists goal text default '';
alter table entries add column if not exists created_at timestamptz not null default now();
alter table entries add column if not exists updated_at timestamptz not null default now();

-- entries: debugging + design
alter table entries add column if not exists debugging jsonb not null default '[]';           -- [{worked, reasons:[...], note, media:[{src,kind}]}]
alter table entries add column if not exists design jsonb not null default '[]';              -- [{type, note, media:[{src,kind}]}]
alter table entries add column if not exists design_final_photo text;                         -- legacy single-photo column, kept for old rows
alter table entries add column if not exists design_final_media jsonb not null default '[]';  -- [{src, kind:"image"|"video"}]
alter table entries add column if not exists design_final_label text default '';

-- entries: Reflections (column names describe the topic, not the week shown)
alter table entries add column if not exists week1_materials text default '';          -- week 1: conductive vs. insulating parts
alter table entries add column if not exists week1_switch_type text default '';        -- week 1: momentary or toggle switch
alter table entries add column if not exists week1_interaction text default '';        -- week 1: how/when the lights turn on
alter table entries add column if not exists week1_outside_materials text default '';  -- week 1: outside materials (foil, coins)
alter table entries add column if not exists week2_explain text default '';            -- Ohm's Law (currently week 3): how LED brightness changes
alter table entries add column if not exists week2_battery_change text default '';     -- Ohm's Law (currently week 3): 9V vs. 3V battery
alter table entries add column if not exists week3_circuit_choice text default '';     -- Series & Parallel (currently week 2): which circuit, and why
alter table entries add column if not exists week3_remove_light text default '';       -- Series & Parallel (currently week 2): removing one light
alter table entries add column if not exists week3_bigger_resistor text default '';    -- Series & Parallel (currently week 2): bigger resistor
alter table entries add column if not exists week4_led_brightness text default '';     -- Transistor as a Switch (week 4): how LED brightness changes
alter table entries add column if not exists capacitor_led_brightness text default ''; -- Capacitor (week 6): how LED brightness changes
alter table entries add column if not exists capacitor_battery_change text default ''; -- Capacitor (week 6): 9V vs. 3V battery

-- entries: optional project
alter table entries add column if not exists optional_attempted boolean not null default false;
alter table entries add column if not exists optional_debugging jsonb not null default '[]';
alter table entries add column if not exists optional_design jsonb not null default '[]';
alter table entries add column if not exists optional_design_final_photo text;                 -- legacy single-photo column
alter table entries add column if not exists optional_design_final_media jsonb not null default '[]';
alter table entries add column if not exists optional_design_final_label text default '';
alter table entries add column if not exists optional_reflection_learned text default '';
alter table entries add column if not exists optional_reflection_next text default '';

-- ============================================================
-- Allow week 11 (the course is now 11 weeks: week 5 is Review).
-- Replaces only the "week between 1 and N" rule — no rows are touched,
-- and every existing row (weeks 1-10) already passes the new rule.
-- ============================================================
do $$
declare c record;
begin
  for c in
    select conrelid::regclass as tbl, conname
    from pg_constraint
    where contype = 'c'
      and conrelid in ('public.entries'::regclass, 'public.educator_notes'::regclass)
      and pg_get_constraintdef(oid) ilike '%week%'
  loop
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
  end loop;
end $$;
alter table entries add constraint entries_week_check check (week between 1 and 11);
alter table educator_notes add constraint educator_notes_week_check check (week between 1 and 11);

-- educator_notes
alter table educator_notes add column if not exists text text not null default '';
alter table educator_notes add column if not exists sent_at timestamptz;
alter table educator_notes add column if not exists created_by uuid references auth.users(id);
alter table educator_notes add column if not exists updated_at timestamptz not null default now();

-- ============================================================
-- Helper functions
-- ============================================================
create or replace function is_educator()
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from educators
    where lower(email) = lower((auth.jwt() ->> 'email'))
  );
$$;

create or replace function am_i_educator()
returns boolean
language sql
security definer
stable
as $$
  select is_educator();
$$;

grant execute on function is_educator() to anon, authenticated;
grant execute on function am_i_educator() to anon, authenticated;

-- ============================================================
-- Row Level Security
-- (policies are replaced in place — this changes access rules only,
--  never data)
-- ============================================================
alter table educators enable row level security;
alter table profiles enable row level security;
alter table entries enable row level security;
alter table educator_notes enable row level security;

drop policy if exists "educators_select" on educators;
create policy "educators_select" on educators
  for select using (is_educator());

drop policy if exists "profiles_select_all" on profiles;
create policy "profiles_select_all" on profiles
  for select using (true);

drop policy if exists "profiles_upsert_own" on profiles;
create policy "profiles_upsert_own" on profiles
  for insert with check (auth.uid() = user_id);

drop policy if exists "profiles_update_own" on profiles;
create policy "profiles_update_own" on profiles
  for update using (auth.uid() = user_id);

drop policy if exists "entries_select_all" on entries;
create policy "entries_select_all" on entries
  for select using (true);

drop policy if exists "entries_insert_own" on entries;
create policy "entries_insert_own" on entries
  for insert with check (auth.uid() = user_id or is_educator());

drop policy if exists "entries_update_own" on entries;
create policy "entries_update_own" on entries
  for update using (auth.uid() = user_id or is_educator());

drop policy if exists "entries_delete_own" on entries;
create policy "entries_delete_own" on entries
  for delete using (auth.uid() = user_id or is_educator());

drop policy if exists "notes_select_owner_or_educator" on educator_notes;
create policy "notes_select_owner_or_educator" on educator_notes
  for select using (auth.uid() = student_user_id or is_educator());

drop policy if exists "notes_write_educator" on educator_notes;
create policy "notes_write_educator" on educator_notes
  for insert with check (is_educator());

drop policy if exists "notes_update_educator" on educator_notes;
create policy "notes_update_educator" on educator_notes
  for update using (is_educator());

-- ============================================================
-- updated_at triggers
-- ============================================================
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_entries_updated_at on entries;
create trigger trg_entries_updated_at before update on entries
  for each row execute function set_updated_at();

drop trigger if exists trg_notes_updated_at on educator_notes;
create trigger trg_notes_updated_at before update on educator_notes
  for each row execute function set_updated_at();

drop trigger if exists trg_profiles_updated_at on profiles;
create trigger trg_profiles_updated_at before update on profiles
  for each row execute function set_updated_at();

-- ============================================================
-- Realtime (added only if not already on — avoids the
-- "already member of publication" error)
-- ============================================================
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'entries'
  ) then
    alter publication supabase_realtime add table public.entries;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'educator_notes'
  ) then
    alter publication supabase_realtime add table public.educator_notes;
  end if;
end $$;

-- ============================================================
-- Storage bucket for photos/videos (existing files are untouched)
-- ============================================================
insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do nothing;

drop policy if exists "photos_public_read" on storage.objects;
create policy "photos_public_read" on storage.objects
  for select using (bucket_id = 'photos');

drop policy if exists "photos_insert_own_folder" on storage.objects;
create policy "photos_insert_own_folder" on storage.objects
  for insert with check (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "photos_update_own_folder" on storage.objects;
create policy "photos_update_own_folder" on storage.objects
  for update using (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "photos_delete_own_folder" on storage.objects;
create policy "photos_delete_own_folder" on storage.objects
  for delete using (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

commit;
