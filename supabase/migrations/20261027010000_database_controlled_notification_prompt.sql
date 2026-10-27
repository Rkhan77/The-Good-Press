-- Show the email-preference prompt once to new readers, with an explicit
-- per-reader switch that administrators can control in Supabase.

alter table public.notification_preferences
  add column if not exists show_notification_prompt boolean;

-- Readers who existed before this feature should not be interrupted.
update public.notification_preferences
set show_notification_prompt = false
where show_notification_prompt is null;

alter table public.notification_preferences
  alter column show_notification_prompt set default true,
  alter column show_notification_prompt set not null;

grant update (show_notification_prompt)
  on public.notification_preferences to authenticated;

comment on column public.notification_preferences.show_notification_prompt is
  'When true, show the email-preference prompt at the reader''s next explicit sign-in. Confirm or Later changes it to false.';
