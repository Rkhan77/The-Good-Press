-- Repair prompt visibility for current readers and make both onboarding
-- prompts explicitly controllable per user from Supabase.

alter table public.profiles
  add column if not exists show_install_prompt boolean;

update public.profiles
set show_install_prompt = true
where show_install_prompt is null;

alter table public.profiles
  alter column show_install_prompt set default true,
  alter column show_install_prompt set not null;

comment on column public.profiles.show_install_prompt is
  'When true, show the install-app prompt once on the reader''s next eligible visit. Showing it changes this value to false; an administrator can set it back to true.';

-- The previous rollout intentionally excluded existing readers. Reset the
-- switch once so every current reader can receive the repaired prompt. After
-- it is handled, the browser changes the individual row back to false.
insert into public.notification_preferences (user_id, show_notification_prompt)
select id, true
from auth.users
on conflict (user_id) do update
set show_notification_prompt = true;

create or replace function public.create_notification_preferences_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notification_preferences (user_id, show_notification_prompt)
  values (new.id, true)
  on conflict (user_id) do nothing;
  return new;
end;
$$;
