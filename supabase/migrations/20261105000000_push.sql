-- Push notifications.
--
-- Every row inserted into public.notifications calls the send-push Edge
-- Function (via pg_net), which delivers it to the recipient's devices through
-- APNs. The function only takes a notification id, claims it with pushed_at,
-- and ignores anything older than a few minutes, so calling it directly can't
-- send anything that wasn't already going to be sent.

create extension if not exists pg_net with schema extensions;

alter type public.notification_kind add value if not exists 'invite_joined';

alter table public.notifications add column pushed_at timestamptz;

alter table public.device_tokens
  add column sandbox boolean not null default false,
  add column updated_at timestamptz not null default now();

-- A device belongs to whoever signed in on it last.
create or replace function public.register_device(p_token text, p_sandbox boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_token !~ '^[0-9a-f]{32,200}$' then raise exception 'Invalid device token.' using errcode = '22023'; end if;
  insert into public.device_tokens (token, user_id, platform, sandbox, updated_at)
  values (p_token, auth.uid(), 'ios', p_sandbox, now())
  on conflict (token) do update set user_id = excluded.user_id, sandbox = excluded.sandbox, updated_at = now();
end $$;
grant execute on function public.register_device(text, boolean) to authenticated;

create or replace function public.unregister_device(p_token text) returns void
language sql security definer set search_path = public as $$
  delete from public.device_tokens where token = p_token and user_id = auth.uid();
$$;
grant execute on function public.unregister_device(text) to authenticated;

-- Tell the inviter when someone joins with their code.
create or replace function public.notify_invite_joined() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.member_since is not null and old.member_since is null and new.invited_by is not null then
    insert into public.notifications (recipient_id, actor_id, kind) values (new.invited_by, new.id, 'invite_joined');
  end if;
  return new;
end $$;

create trigger profiles_invite_joined after update of member_since on public.profiles
  for each row execute function public.notify_invite_joined();

-- Hand each new notification to the push function. Failures never block the insert.
create table public.app_config (
  key text primary key,
  value text not null
);
alter table public.app_config enable row level security; -- no policies: server-side only

insert into public.app_config (key, value) values
  ('push_function_url', 'https://duucliymxblrlyzogqiw.supabase.co/functions/v1/send-push')
on conflict (key) do nothing;

create or replace function public.dispatch_push() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  target text;
begin
  select value into target from public.app_config where key = 'push_function_url';
  if target is not null then
    perform net.http_post(
      url := target,
      body := jsonb_build_object('id', new.id),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 5000
    );
  end if;
  return new;
exception when others then
  return new;
end $$;

create trigger notifications_push after insert on public.notifications
  for each row execute function public.dispatch_push();
