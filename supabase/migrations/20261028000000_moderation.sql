-- User safety (App Store Guideline 1.2): blocking, reporting, and terms acceptance.
-- Blocking is symmetric for visibility: neither side sees the other's content.

create table public.user_blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index user_blocks_blocked_idx on public.user_blocks (blocked_id);

create type public.report_reason as enum ('spam', 'harassment', 'hate', 'sexual', 'violence', 'misinformation', 'other');
create type public.report_status as enum ('open', 'actioned', 'dismissed');

create table public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reported_user_id uuid references public.profiles (id) on delete cascade,
  entry_id uuid references public.tasting_entries (id) on delete cascade,
  comment_id uuid references public.review_comments (id) on delete cascade,
  reason public.report_reason not null,
  details text check (char_length(details) <= 1000),
  status public.report_status not null default 'open',
  created_at timestamptz not null default now(),
  check (reported_user_id is not null or entry_id is not null or comment_id is not null)
);
create index content_reports_status_idx on public.content_reports (status, created_at);
create unique index content_reports_once on public.content_reports
  (reporter_id, coalesce(entry_id, '00000000-0000-0000-0000-000000000000'::uuid),
   coalesce(comment_id, '00000000-0000-0000-0000-000000000000'::uuid),
   coalesce(reported_user_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- Content a moderator removed is hidden from everyone but its author.
alter table public.tasting_entries add column hidden_by_moderation boolean not null default false;
alter table public.review_comments add column hidden_by_moderation boolean not null default false;

alter table public.profiles add column terms_accepted_at timestamptz;

create or replace function public.is_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_blocks
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  );
$$;

-- Visibility now also respects blocks.
create or replace function public.can_view_content(owner uuid, vis public.visibility) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when owner = auth.uid() then true
    when public.is_blocked_between(auth.uid(), owner) then false
    when vis = 'public' then public.can_view_profile_content(owner)
    when vis = 'friends' then public.are_friends(auth.uid(), owner)
    else false
  end;
$$;

-- Entries: hide moderated content and anything the viewer reported.
drop policy "entries visible per visibility" on public.tasting_entries;
create policy "entries visible per visibility" on public.tasting_entries
  for select to authenticated using (
    public.can_view_content(user_id, visibility)
    and (user_id = auth.uid() or not hidden_by_moderation)
    and not exists (select 1 from public.content_reports r where r.reporter_id = auth.uid() and r.entry_id = tasting_entries.id)
  );

drop policy "comments visible with entry" on public.review_comments;
create policy "comments visible with entry" on public.review_comments
  for select to authenticated using (
    public.can_view_entry(entry_id)
    and (user_id = auth.uid() or not hidden_by_moderation)
    and not public.is_blocked_between(auth.uid(), user_id)
    and not exists (select 1 from public.content_reports r where r.reporter_id = auth.uid() and r.comment_id = review_comments.id)
  );

-- Blocked users cannot follow, like or comment on each other.
drop policy "users follow as themselves" on public.user_follows;
create policy "users follow as themselves" on public.user_follows
  for insert to authenticated with check (follower_id = auth.uid() and not public.is_blocked_between(follower_id, followee_id));

drop policy "users comment on visible entries" on public.review_comments;
create policy "users comment on visible entries" on public.review_comments
  for insert to authenticated with check (user_id = auth.uid() and public.can_view_entry(entry_id));

-- Blocking removes follows in both directions.
create or replace function public.on_block_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.user_follows
  where (follower_id = new.blocker_id and followee_id = new.blocked_id)
     or (follower_id = new.blocked_id and followee_id = new.blocker_id);
  return new;
end $$;
create trigger user_blocks_cleanup after insert on public.user_blocks
  for each row execute function public.on_block_insert();

-- Notifications from blocked users are not shown.
drop policy "own notifications" on public.notifications;
create policy "own notifications" on public.notifications
  for select to authenticated using (recipient_id = auth.uid() and not public.is_blocked_between(recipient_id, actor_id));

alter table public.user_blocks enable row level security;
alter table public.content_reports enable row level security;

create policy "own blocks" on public.user_blocks
  for all to authenticated using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

-- Reporters can file and see their own reports; moderation happens with the service role (dashboard).
create policy "file reports" on public.content_reports
  for insert to authenticated with check (reporter_id = auth.uid() and status = 'open');
create policy "see own reports" on public.content_reports
  for select to authenticated using (reporter_id = auth.uid());

grant execute on function public.is_blocked_between to authenticated;
revoke execute on function public.is_blocked_between from anon, public;
