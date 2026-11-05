-- Invite-only membership.
--
-- Anyone can create an auth account, but only members (profiles.member_since
-- set) can post, follow, cellar or scan. You become a member by redeeming
-- another member's personal invite code. Each member gets one code with a
-- fixed number of uses. Everyone who existed before this migration is a member.

alter table public.profiles
  add column member_since timestamptz,
  add column invited_by uuid references public.profiles (id) on delete set null;

update public.profiles set member_since = created_at where member_since is null;

create index profiles_invited_by_idx on public.profiles (invited_by);

-- Members can't grant themselves membership through the normal profile update.
create or replace function public.protect_membership() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.member_since := old.member_since;
    new.invited_by := old.invited_by;
  end if;
  return new;
end $$;

create trigger profiles_protect_membership before update on public.profiles
  for each row execute function public.protect_membership();

create or replace function public.is_member(uid uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select member_since is not null from public.profiles where id = uid), false);
$$;
grant execute on function public.is_member(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Invite codes: private to their owner.
-- ---------------------------------------------------------------------------
create table public.invite_codes (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  code text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  max_uses int not null default 5 check (max_uses >= 0),
  created_at timestamptz not null default now()
);
alter table public.invite_codes enable row level security;
create policy "owners read their invite code" on public.invite_codes
  for select to authenticated using (user_id = auth.uid());

-- Six characters without look-alikes (no I, O, 0, 1).
create or replace function public.new_invite_code() returns text
language plpgsql volatile set search_path = public as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  candidate text;
begin
  loop
    candidate := '';
    for i in 1..6 loop
      candidate := candidate || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.invite_codes where code = candidate);
  end loop;
  return candidate;
end $$;

insert into public.invite_codes (user_id, code)
select id, public.new_invite_code() from public.profiles where member_since is not null
on conflict do nothing;

-- The caller's code (created on first use), its limit and how many people joined with it.
create or replace function public.my_invite()
returns table (code text, max_uses int, used int)
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if me is null or not public.is_member(me) then
    raise exception 'Only members have invite codes.' using errcode = '42501';
  end if;
  insert into public.invite_codes (user_id, code) values (me, public.new_invite_code())
  on conflict (user_id) do nothing;
  return query
    select c.code, c.max_uses, (select count(*)::int from public.profiles p where p.invited_by = me)
    from public.invite_codes c where c.user_id = me;
end $$;
grant execute on function public.my_invite() to authenticated;

-- Lets the sign-in screen say whether a code is good before creating an account.
create or replace function public.check_invite(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.invite_codes c
    join public.profiles owner on owner.id = c.user_id and owner.member_since is not null
    where c.code = upper(trim(p_code))
      and (select count(*) from public.profiles p where p.invited_by = c.user_id) < c.max_uses
  );
$$;
grant execute on function public.check_invite(text) to anon, authenticated;

create or replace function public.redeem_invite(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  invite public.invite_codes%rowtype;
  used int;
begin
  if me is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if public.is_member(me) then return; end if;

  -- Lock the code so two people can't take its last use at once.
  select * into invite from public.invite_codes where code = upper(trim(p_code)) for update;
  if not found or not public.is_member(invite.user_id) then
    raise exception 'That invite code isn''t valid.' using errcode = 'P0001';
  end if;
  if invite.user_id = me then
    raise exception 'You can''t use your own invite code.' using errcode = 'P0001';
  end if;
  select count(*) into used from public.profiles where invited_by = invite.user_id;
  if used >= invite.max_uses then
    raise exception 'That invite code has been used up.' using errcode = 'P0001';
  end if;

  update public.profiles set member_since = now(), invited_by = invite.user_id where id = me;
  insert into public.invite_codes (user_id, code) values (me, public.new_invite_code())
  on conflict (user_id) do nothing;
end $$;
grant execute on function public.redeem_invite(text) to authenticated;

revoke execute on function public.new_invite_code() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Members-only writes. Restrictive policies AND with the existing ones.
-- Reports and blocks stay open to everyone for safety.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'tasting_entries', 'wine_reviews', 'tasting_private_notes', 'review_comments', 'review_likes',
    'user_follows', 'cellar_bottles', 'cellar_collections', 'cellar_placements', 'cellar_shelves',
    'wishlists', 'scan_history'
  ] loop
    execute format(
      'create policy "members only" on public.%I as restrictive for insert to authenticated with check (public.is_member())', t);
  end loop;
end $$;
