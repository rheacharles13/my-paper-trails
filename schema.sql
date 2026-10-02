-- My Paper Trail — Supabase schema
-- Run this in the Supabase SQL Editor (Project > SQL Editor > New query) on a fresh project.
-- Safe to re-run: uses "if not exists" / "or replace" everywhere.

-- ============================================================
-- Extensions
-- ============================================================
create extension if not exists pgcrypto;

-- ============================================================
-- Tables
-- ============================================================

-- Allowlist of educator emails. Add your teacher account(s) here by hand
-- after creating the project (Table Editor > educators > Insert row),
-- or with: insert into educators (email) values ('you@example.com');
create table if not exists educators (
  email text primary key
);

-- One row per signed-in user, mostly to store the display/student name.
create table if not exists profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  updated_at timestamptz not null default now()
);

-- One row per student per week. Mirrors the app's in-memory "entry" shape.
create table if not exists entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  student text not null,
  week int not null check (week between 1 and 10),

  submitted_at timestamptz,
  confidence_before int,
  confidence_after int,
  learned text default '',
  challenged text default '',
  goal text default '',

  debugging jsonb not null default '[]',           -- [{worked, reasons:[...], note, media:[{src,kind}]}]
  design jsonb not null default '[]',               -- [{type, note, media:[{src,kind}]}]
  design_final_photo text,                          -- legacy single-photo column, kept for old rows
  design_final_media jsonb not null default '[]',   -- [{src, kind:"image"|"video"}] — any number of files
  design_final_label text default '',

  week1_materials text default '',                  -- week 1 only: conductive vs. insulating parts
  week1_switch_type text default '',                -- week 1 only: momentary or toggle switch
  week1_interaction text default '',                -- week 1 only: how/when the lights turn on
  week1_outside_materials text default '',          -- week 1 only: outside materials used (e.g. foil, coins)
  week2_explain text default '',                    -- Ohm's Law reflections (currently week 3): how the LED's brightness changes
  week2_battery_change text default '',              -- Ohm's Law reflections (currently week 3): switching from a 9V to a 3V battery
  week3_circuit_choice text default '',              -- Series & Parallel reflections (currently week 2): which circuit, and why
  week3_remove_light text default '',                -- Series & Parallel reflections (currently week 2): what happens removing one light
  week3_bigger_resistor text default '',             -- Series & Parallel reflections (currently week 2): predicted effect of a bigger resistor
  week4_led_brightness text default '',              -- Transistor as a Switch reflections (week 4): how the LED's brightness changes

  optional_attempted boolean not null default false,
  optional_debugging jsonb not null default '[]',
  optional_design jsonb not null default '[]',
  optional_design_final_photo text,                 -- legacy single-photo column, kept for old rows
  optional_design_final_media jsonb not null default '[]',
  optional_design_final_label text default '',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (user_id, week)
);

-- Educator feedback notes, one per student per week.
create table if not exists educator_notes (
  id uuid primary key default gen_random_uuid(),
  student_user_id uuid not null references auth.users(id) on delete cascade,
  week int not null check (week between 1 and 10),
  text text not null default '',
  sent_at timestamptz,
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  unique (student_user_id, week)
);

-- ============================================================
-- Helper: is the current JWT an educator?
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

-- Public wrapper the client calls (supabase.rpc("am_i_educator")). Needed
-- because is_educator() alone isn't callable directly from the client in a
-- way that returns a plain boolean — this is the actual RPC the app uses.
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
-- ============================================================
alter table educators enable row level security;
alter table profiles enable row level security;
alter table entries enable row level security;
alter table educator_notes enable row level security;

-- educators: only educators can read the allowlist (needed so the UI can
-- show an "you are an educator" state); nobody writes it from the client.
drop policy if exists "educators_select" on educators;
create policy "educators_select" on educators
  for select using (is_educator());

-- profiles: readable by anyone signed in (needed for gallery names/labels
-- lookups and educator dashboard); writable only by the owner.
drop policy if exists "profiles_select_all" on profiles;
create policy "profiles_select_all" on profiles
  for select using (true);

drop policy if exists "profiles_upsert_own" on profiles;
create policy "profiles_upsert_own" on profiles
  for insert with check (auth.uid() = user_id);

drop policy if exists "profiles_update_own" on profiles;
create policy "profiles_update_own" on profiles
  for update using (auth.uid() = user_id);

-- entries: readable by anyone (the class gallery and public gallery view
-- need to show final designs without a login); writes restricted to the
-- owning student or an educator (for feedback-adjacent bookkeeping).
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

-- educator_notes: the student can read their own notes; only educators
-- can write them.
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
-- Realtime (so the educator dashboard + gallery update live)
-- ============================================================
alter publication supabase_realtime add table entries;
alter publication supabase_realtime add table educator_notes;

-- ============================================================
-- Storage bucket for photos
-- ============================================================
insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do nothing;

-- Anyone can view photos (the gallery and educator dashboard are public-read).
drop policy if exists "photos_public_read" on storage.objects;
create policy "photos_public_read" on storage.objects
  for select using (bucket_id = 'photos');

-- A signed-in user may only upload into a folder named after their own
-- user id: photos/<user_id>/<file>. This is enforced by checking that the
-- first path segment equals auth.uid().
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

-- ============================================================
-- Done. Next steps live in SETUP.md.
-- ============================================================

-- ============================================================
-- Migration (2026-09-09): "One thing that challenged you today"
-- field added to Documentation. If you already ran this schema before
-- that date, the create table above won't retroactively add the
-- column — run this once instead:
--
--   alter table entries add column if not exists challenged text default '';
--
-- Safe to run even if the column already exists.
-- ============================================================

-- ============================================================
-- Migration (2026-09-15): multiple photos/videos per submission.
-- Every attempt, design choice, and final design can now carry any number
-- of photos and videos, not just one. debugging/design (jsonb) don't need
-- a schema change — each item just gets a "media" array instead of a
-- single "photo" field going forward, and the app migrates old rows that
-- still have "photo" on read. The final-design fields DO need new
-- columns, since they were previously plain text. If you already ran this
-- schema before this date, run this once:
--
--   alter table entries add column if not exists design_final_media jsonb not null default '[]';
--   alter table entries add column if not exists optional_design_final_media jsonb not null default '[]';
--
-- Safe to run even if the columns already exist. The old design_final_photo
-- / optional_design_final_photo columns are left in place (not dropped) so
-- existing rows' single final photo still shows up until re-submitted.
-- ============================================================

-- ============================================================
-- Migration (2026-09-15): multi-select debugging reasons.
-- A debugging attempt's failure reason changed from a single string
-- ({reason: "..."}) to a list ({reasons: ["...", ...]}), so a student can
-- flag more than one cause per attempt. No schema change needed — it's
-- still inside the same debugging/optional_debugging jsonb columns; the
-- app migrates old rows' single "reason" into a one-item "reasons" array
-- on read.
-- ============================================================

-- ============================================================
-- Migration (2026-09-15): three week-1-only Design questions.
-- Week 1's Design step now asks which parts are conductive vs.
-- insulating, the switch type (momentary/toggle), and how the
-- interaction works. New dedicated columns, since they don't belong
-- inside the per-choice design jsonb array. If you already ran this
-- schema before this date, run this once:
--
--   alter table entries add column if not exists week1_materials text default '';
--   alter table entries add column if not exists week1_switch_type text default '';
--   alter table entries add column if not exists week1_interaction text default '';
--
-- Safe to run even if the columns already exist.
-- ============================================================

-- ============================================================
-- Migration (2026-09-15): fourth week-1-only Design question —
-- outside materials integrated into the circuit (e.g. foil, coins).
-- If you already ran this schema before this date, run this once:
--
--   alter table entries add column if not exists week1_outside_materials text default '';
--
-- Safe to run even if the column already exists.
-- ============================================================

-- ============================================================
-- Migration (2026-09-22): reflections questions for week 2 (Ohm's Law)
-- and week 3 (Series & Parallel Circuits) — the same kind of week-specific
-- text questions week 1 already had, now on two more weeks. If you already
-- ran this schema before this date, run this once:
--
--   alter table entries add column if not exists week2_explain text default '';
--   alter table entries add column if not exists week2_battery_change text default '';
--   alter table entries add column if not exists week3_circuit_choice text default '';
--   alter table entries add column if not exists week3_remove_light text default '';
--   alter table entries add column if not exists week3_bigger_resistor text default '';
--
-- Safe to run even if the columns already exist. IMPORTANT: this is the
-- exact kind of migration that silently broke saving in September 2026 —
-- these "alter table" statements are NOT applied automatically just
-- because this file changed. If you're reading this after already having
-- a live Supabase project, run the block above in the SQL Editor now,
-- before testing week 2 or week 3 pages, or every save on those weeks
-- will fail with a "column ... not found" error.
--
-- NOTE (2026-09-22, later the same day): the curriculum order was swapped
-- back — week 2 is Series & Parallel Circuits again, week 3 is Ohm's Law
-- again — so these column names no longer match the week they're shown on
-- (week2_explain etc. are Ohm's Law questions, now asked on week 3; the
-- week3_* columns are Series & Parallel questions, now asked on week 2).
-- The columns themselves did not change and hold the same data either way
-- — only which week number the app shows them on changed, in index.html's
-- REFLECTIONS_BY_WEEK config. No further migration needed for this.
-- ============================================================

-- ============================================================
-- *** RUN THIS ONE NOW *** — confirmed, not hypothetical, broken.
--
-- Migration (2026-09-28, discovered): the 2026-09-22 migration directly
-- above this one was NEVER run against the live project. Every student
-- submission for every week was silently failing to save (Postgres
-- rejected the whole row with "column ... does not exist", since every
-- submission writes all Reflections columns regardless of week) — this
-- surfaced as "Week 2 pages don't show up for the educator at all." If
-- you haven't specifically confirmed (e.g. via the Table Editor) that
-- week2_explain / week2_battery_change / week3_circuit_choice /
-- week3_remove_light / week3_bigger_resistor already exist on `entries`,
-- run the 2026-09-22 block above right now, in the Supabase SQL Editor,
-- before anything else.
--
-- Migration (2026-10-02): Week 4 (Transistor as a Switch) gets its own
-- Reflections question too now — "Explain how the LED changes brightness.
-- What is happening inside the circuit?" New column, run this once:
--
--   alter table entries add column if not exists week4_led_brightness text default '';
--
-- Safe to run even if the column already exists. The app (index.html) now
-- also ships a backend health check: the educator dashboard itself will
-- show a clear warning banner if any Reflections column it expects is
-- missing, so a forgotten migration like this one won't go unnoticed
-- again — but it's still on you to actually run the "alter table"
-- statements here; the app can only detect the problem, not fix it.
-- ============================================================
