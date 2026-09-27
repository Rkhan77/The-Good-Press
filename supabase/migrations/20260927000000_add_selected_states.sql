-- Stores the states and territories a signed-in reader wants in their live feed.
alter table public.user_agendas
  add column if not exists selected_states text[] not null default '{}';
