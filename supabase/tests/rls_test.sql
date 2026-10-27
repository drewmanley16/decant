-- RLS regression checks. Run against a database with the migration + seed applied:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_test.sql
-- Every check raises an exception on failure. Runs in a transaction and rolls back.
begin;

insert into auth.users (id, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', '{"username":"alice"}'),
  ('00000000-0000-0000-0000-00000000000b', '{"username":"bob"}'),
  ('00000000-0000-0000-0000-00000000000c', '{"username":"carol"}');
update public.profiles set is_private = true where username = 'carol';

-- Helper to impersonate a user the way PostgREST does.
create or replace function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function pg_temp.check(ok boolean, label text) returns void language plpgsql as $$
begin
  if not ok then raise exception 'RLS check failed: %', label; end if;
  raise notice 'ok: %', label;
end $$;

-- Alice logs a public, a friends-only and a private tasting.
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
insert into public.tasting_entries (id, user_id, vintage_id, rating, visibility)
select '10000000-0000-0000-0000-000000000001', auth.uid(), id, 4.5, 'public' from public.wine_vintages limit 1;
insert into public.tasting_entries (id, user_id, vintage_id, rating, visibility)
select '10000000-0000-0000-0000-000000000002', auth.uid(), id, 3, 'friends' from public.wine_vintages limit 1;
insert into public.tasting_entries (id, user_id, vintage_id, rating, visibility)
select '10000000-0000-0000-0000-000000000003', auth.uid(), id, 2, 'private' from public.wine_vintages limit 1;
insert into public.tasting_private_notes (entry_id, user_id, notes)
values ('10000000-0000-0000-0000-000000000001', auth.uid(), 'secret note');
insert into public.cellar_bottles (user_id, vintage_id) select auth.uid(), id from public.wine_vintages limit 1;
select pg_temp.check((select count(*) from public.tasting_entries) = 3, 'owner sees all own entries');

-- Bob (not a friend) sees only the public entry, no notes, no cellar.
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select pg_temp.check((select count(*) from public.tasting_entries) = 1, 'stranger sees only public entry');
select pg_temp.check((select count(*) from public.tasting_private_notes) = 0, 'private notes hidden');
select pg_temp.check((select count(*) from public.cellar_bottles) = 0, 'cellar hidden from others');

-- Mutual follow makes Bob a friend: he now sees the friends-only entry but not the private one.
insert into public.user_follows (follower_id, followee_id) values (auth.uid(), '00000000-0000-0000-0000-00000000000a');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
insert into public.user_follows (follower_id, followee_id) values (auth.uid(), '00000000-0000-0000-0000-00000000000b');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select pg_temp.check((select count(*) from public.tasting_entries) = 2, 'friend sees public + friends entries');
select pg_temp.check(not exists (select 1 from public.tasting_entries where visibility = 'private'), 'private entry hidden from friend');

-- Bob can like Alice's visible entry, which notifies Alice.
insert into public.review_likes (entry_id, user_id) values ('10000000-0000-0000-0000-000000000001', auth.uid());

-- Bob cannot write entries as Alice.
do $$ begin
  insert into public.tasting_entries (user_id, vintage_id) select '00000000-0000-0000-0000-00000000000a', id from public.wine_vintages limit 1;
  raise exception 'RLS check failed: impersonated insert succeeded';
exception when insufficient_privilege then raise notice 'ok: cannot insert as another user';
end $$;

-- Carol is private: Bob's follow is pending and he cannot see her public entries.
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000c');
insert into public.tasting_entries (user_id, vintage_id, rating, visibility)
select auth.uid(), id, 5, 'public' from public.wine_vintages limit 1;
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
insert into public.user_follows (follower_id, followee_id) values (auth.uid(), '00000000-0000-0000-0000-00000000000c');
select pg_temp.check((select status from public.user_follows where followee_id = '00000000-0000-0000-0000-00000000000c') = 'pending', 'private profile follow is pending');
select pg_temp.check(not exists (select 1 from public.tasting_entries where user_id = '00000000-0000-0000-0000-00000000000c'), 'private profile content hidden before approval');

reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000c');
select public.respond_follow_request('00000000-0000-0000-0000-00000000000b', true);
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select pg_temp.check(exists (select 1 from public.tasting_entries where user_id = '00000000-0000-0000-0000-00000000000c'), 'approved follower sees private profile content');

-- Notifications are recipient-only.
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select pg_temp.check((select count(*) from public.notifications where kind = 'like') = 1, 'like notification delivered');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select pg_temp.check(not exists (select 1 from public.notifications where recipient_id <> auth.uid()), 'cannot read others notifications');

-- Label cache is not readable by clients.
select pg_temp.check((select count(*) from public.label_cache) = 0, 'label cache hidden');

-- Catalog creation via RPC and vintage distinction.
select pg_temp.check(public.create_wine_from_scan('Test Estate', 'Test Red', 'red', 2020)
  <> public.create_wine_from_scan('Test Estate', 'Test Red', 'red', 2021), 'different vintages are distinct');
select pg_temp.check(public.create_wine_from_scan('Test Estate', 'Test Red', 'red', 2020)
  = public.create_wine_from_scan('test estate', 'test red', 'red', 2020), 'same vintage is reused');
select pg_temp.check((select count(*) from public.search_wines('margaux')) >= 1, 'search finds seeded wine');
select pg_temp.check((select score from public.match_wines('Chateau Margaux', 'Chateau Margaux', 2015) limit 1) > 0.5, 'matching scores seeded wine');

-- Moderation: blocking hides content both ways and removes follows; reports hide content for the reporter.
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
insert into public.content_reports (reporter_id, entry_id, reason)
values (auth.uid(), '10000000-0000-0000-0000-000000000001', 'spam');
select pg_temp.check(not exists (select 1 from public.tasting_entries where id = '10000000-0000-0000-0000-000000000001'), 'reported entry hidden from reporter');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select pg_temp.check(exists (select 1 from public.tasting_entries where id = '10000000-0000-0000-0000-000000000001'), 'reported entry still visible to author');
select pg_temp.check((select count(*) from public.content_reports) = 0, 'reports are private to reporter');
insert into public.user_blocks (blocker_id, blocked_id) values (auth.uid(), '00000000-0000-0000-0000-00000000000b');
select pg_temp.check(not exists (select 1 from public.user_follows where follower_id = '00000000-0000-0000-0000-00000000000b' or followee_id = '00000000-0000-0000-0000-00000000000b'), 'block removes follows');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select pg_temp.check(not exists (select 1 from public.tasting_entries where user_id = '00000000-0000-0000-0000-00000000000a'), 'blocked user cannot see blocker content');
do $$ begin
  insert into public.user_follows (follower_id, followee_id) values (auth.uid(), '00000000-0000-0000-0000-00000000000a');
  raise exception 'RLS check failed: blocked user could follow';
exception when insufficient_privilege then raise notice 'ok: blocked user cannot follow';
end $$;
reset role;
update public.tasting_entries set hidden_by_moderation = true where user_id = '00000000-0000-0000-0000-00000000000c';
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select pg_temp.check(not exists (select 1 from public.tasting_entries where user_id = '00000000-0000-0000-0000-00000000000c'), 'moderated content hidden');

reset role;
rollback;
