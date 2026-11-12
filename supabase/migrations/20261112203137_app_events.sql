-- Product events (screens reached, actions finished, failures) written by the app.
-- Kept in Decant's own database; nothing is sent to a third party.
create table public.app_events (
  id bigint generated always as identity primary key,
  user_id uuid default auth.uid() references auth.users (id) on delete cascade,
  install_id uuid not null,
  session_id uuid not null,
  name text not null check (char_length(name) between 1 and 64),
  props jsonb not null default '{}' check (pg_column_size(props) <= 4096),
  app_version text check (char_length(app_version) <= 40),
  os_version text check (char_length(os_version) <= 80),
  device text check (char_length(device) <= 40),
  created_at timestamptz not null default now(),
  received_at timestamptz not null default now()
);

create index app_events_name_time on public.app_events (name, received_at desc);
create index app_events_install on public.app_events (install_id, received_at);
create index app_events_user on public.app_events (user_id) where user_id is not null;

alter table public.app_events enable row level security;

-- Write-only from the app: anyone (including people still onboarding) can add events,
-- but only as themselves, and nobody can read them back through the API.
create policy "add own events" on public.app_events
  for insert to anon, authenticated
  with check (user_id is null or user_id = auth.uid());

grant insert on public.app_events to anon, authenticated;
