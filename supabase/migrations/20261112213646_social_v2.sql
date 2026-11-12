-- Reactions, comment replies, comment likes, @mentions and share counts.

-- Can a given person (not necessarily the caller) see an entry? Mirrors can_view_content.
create or replace function public.can_user_view_entry(viewer uuid, entry uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select case
      when e.user_id = viewer then true
      when public.is_blocked_between(viewer, e.user_id) then false
      when e.visibility = 'public' then
        not coalesce((select is_private from public.profiles where id = e.user_id), true)
        or public.follows(viewer, e.user_id)
      when e.visibility = 'friends' then public.are_friends(viewer, e.user_id)
      else false
    end
    from public.tasting_entries e where e.id = entry
  ), false);
$$;

-- Reactions ----------------------------------------------------------------
create table public.entry_reactions (
  entry_id uuid not null references public.tasting_entries (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('cheers', 'want', 'wow')),
  created_at timestamptz not null default now(),
  primary key (entry_id, user_id, kind)
);
alter table public.entry_reactions enable row level security;
create policy "reactions visible with entry" on public.entry_reactions for select
  using (public.can_view_entry(entry_id) and not public.is_blocked_between(auth.uid(), user_id));
create policy "members react to visible entries" on public.entry_reactions for insert
  with check (user_id = auth.uid() and public.is_member() and public.can_view_entry(entry_id));
create policy "remove own reactions" on public.entry_reactions for delete using (user_id = auth.uid());
grant select, insert, delete on public.entry_reactions to authenticated;

-- Replies and mentions -------------------------------------------------------
alter table public.review_comments
  add column parent_id uuid references public.review_comments (id) on delete cascade,
  add column mentioned_user_ids uuid[] not null default '{}'
    check (cardinality(mentioned_user_ids) <= 10);
create index review_comments_entry_time on public.review_comments (entry_id, created_at);

-- Comment likes --------------------------------------------------------------
create table public.comment_likes (
  comment_id uuid not null references public.review_comments (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
alter table public.comment_likes enable row level security;
create policy "comment likes visible with entry" on public.comment_likes for select
  using (exists (select 1 from public.review_comments c where c.id = comment_id and public.can_view_entry(c.entry_id)));
create policy "members like visible comments" on public.comment_likes for insert
  with check (user_id = auth.uid() and public.is_member()
    and exists (select 1 from public.review_comments c where c.id = comment_id and public.can_view_entry(c.entry_id)));
create policy "remove own comment likes" on public.comment_likes for delete using (user_id = auth.uid());
grant select, insert, delete on public.comment_likes to authenticated;

-- Shares ---------------------------------------------------------------------
create table public.entry_shares (
  id bigint generated always as identity primary key,
  entry_id uuid not null references public.tasting_entries (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);
create index entry_shares_entry on public.entry_shares (entry_id);
alter table public.entry_shares enable row level security;
create policy "record shares of visible entries" on public.entry_shares for insert
  with check (user_id = auth.uid() and public.can_view_entry(entry_id));
grant insert on public.entry_shares to authenticated;

-- Notifications --------------------------------------------------------------
create or replace function public.on_comment_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  owner uuid;
  parent_author uuid;
begin
  select e.user_id into owner from public.tasting_entries e where e.id = new.entry_id;

  if owner is not null and owner <> new.user_id then
    insert into public.notifications (recipient_id, actor_id, kind, entry_id)
    values (owner, new.user_id, 'comment', new.entry_id);
  end if;

  if new.parent_id is not null then
    select c.user_id into parent_author from public.review_comments c where c.id = new.parent_id;
    if parent_author is not null and parent_author <> new.user_id and parent_author is distinct from owner then
      insert into public.notifications (recipient_id, actor_id, kind, entry_id)
      values (parent_author, new.user_id, 'reply', new.entry_id);
    end if;
  end if;

  -- Mentioned people who can see the entry, once each, skipping anyone already notified above.
  insert into public.notifications (recipient_id, actor_id, kind, entry_id)
  select distinct m, new.user_id, 'mention'::public.notification_kind, new.entry_id
  from unnest(new.mentioned_user_ids) m
  where m <> new.user_id and m is distinct from owner and m is distinct from parent_author
    and public.can_user_view_entry(m, new.entry_id);
  return new;
end $$;

create or replace function public.on_reaction_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- One reaction notification per person per tasting per day, however many they tap.
  insert into public.notifications (recipient_id, actor_id, kind, entry_id)
  select e.user_id, new.user_id, 'reaction', new.entry_id
  from public.tasting_entries e
  where e.id = new.entry_id and e.user_id <> new.user_id
    and not exists (
      select 1 from public.notifications n
      where n.recipient_id = e.user_id and n.actor_id = new.user_id and n.entry_id = new.entry_id
        and n.kind = 'reaction' and n.created_at > now() - interval '1 day');
  return new;
end $$;
create trigger entry_reactions_notify after insert on public.entry_reactions
  for each row execute function public.on_reaction_insert();

-- Stats ----------------------------------------------------------------------
drop function public.entry_stats(uuid[]);
create function public.entry_stats(entry_ids uuid[])
returns table(entry_id uuid, like_count bigint, comment_count bigint, liked_by_me boolean,
              reactions jsonb, my_reactions text[], share_count bigint)
language sql stable security definer set search_path = public as $$
  select e.id,
    (select count(*) from public.review_likes l where l.entry_id = e.id),
    (select count(*) from public.review_comments c where c.entry_id = e.id and not c.hidden_by_moderation),
    exists (select 1 from public.review_likes l where l.entry_id = e.id and l.user_id = auth.uid()),
    coalesce((select jsonb_object_agg(kind, n) from (
      select r.kind, count(*) n from public.entry_reactions r where r.entry_id = e.id group by r.kind) x), '{}'::jsonb),
    coalesce((select array_agg(r.kind) from public.entry_reactions r where r.entry_id = e.id and r.user_id = auth.uid()), '{}'),
    (select count(*) from public.entry_shares s where s.entry_id = e.id)
  from public.tasting_entries e
  where e.id = any(entry_ids) and public.can_view_content(e.user_id, e.visibility);
$$;
grant execute on function public.entry_stats(uuid[]) to authenticated;
