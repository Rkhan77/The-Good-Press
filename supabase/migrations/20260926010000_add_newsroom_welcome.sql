-- Introduce the newsroom only to accounts created after this migration.
alter table public.profiles
  add column if not exists newsroom_seen_at timestamptz;

-- Existing readers have already used the app, so avoid showing them a first-time welcome.
update public.profiles
set newsroom_seen_at = now()
where newsroom_seen_at is null;
