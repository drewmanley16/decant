-- Decant initial schema.
-- Wine identity is layered: wineries -> wine_products (a wine, any vintage)
-- -> wine_vintages (a specific year/bottle size). User data (tastings, cellar
-- bottles, wishlists) always references a vintage.

create extension if not exists pg_trgm with schema extensions;
create extension if not exists citext with schema extensions;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.wine_type as enum ('red', 'white', 'rose', 'sparkling', 'dessert', 'fortified', 'orange');
create type public.info_source as enum ('verified', 'label', 'editorial', 'ai_suggested', 'user');
create type public.visibility as enum ('public', 'friends', 'private');
create type public.follow_status as enum ('accepted', 'pending');
create type public.activity_kind as enum ('rated', 'cellared', 'wishlisted', 'followed');
create type public.notification_kind as enum ('follow', 'follow_request', 'like', 'comment', 'tag');
create type public.image_kind as enum ('label', 'bottle', 'user_photo');

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username extensions.citext not null unique
    check (username ~ '^[a-zA-Z0-9_.]{3,30}$'),
  display_name text not null default '' check (char_length(display_name) <= 60),
  avatar_url text,
  bio text check (char_length(bio) <= 280),
  is_private boolean not null default false,
  favorite_types public.wine_type[] not null default '{}',
  default_visibility public.visibility not null default 'public',
  cellar_finish text not null default 'walnut',
  cellar_sort text not null default 'manual',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index profiles_username_trgm on public.profiles using gin ((username::text) extensions.gin_trgm_ops);
create index profiles_display_name_trgm on public.profiles using gin (display_name extensions.gin_trgm_ops);
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- Create a profile for every new auth user.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  requested text := nullif(new.raw_user_meta_data ->> 'username', '');
  candidate text;
begin
  candidate := coalesce(requested, 'taster_' || substr(replace(new.id::text, '-', ''), 1, 8));
  if exists (select 1 from public.profiles where username = candidate::citext) then
    candidate := 'taster_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;
  insert into public.profiles (id, username, display_name)
  values (new.id, candidate, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', ''));
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Follows and privacy helpers
-- ---------------------------------------------------------------------------
create table public.user_follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  followee_id uuid not null references public.profiles (id) on delete cascade,
  status public.follow_status not null default 'accepted',
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index user_follows_followee_idx on public.user_follows (followee_id, status);

-- True when `viewer` has an accepted follow of `owner`.
create or replace function public.follows(viewer uuid, owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_follows
    where follower_id = viewer and followee_id = owner and status = 'accepted'
  );
$$;

-- Friends = mutual accepted follows.
create or replace function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.follows(a, b) and public.follows(b, a);
$$;

-- Can the current user see `owner`'s content (diary, activity)?
create or replace function public.can_view_profile_content(owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select owner = auth.uid()
    or not coalesce((select is_private from public.profiles where id = owner), true)
    or public.follows(auth.uid(), owner);
$$;

create or replace function public.can_view_content(owner uuid, vis public.visibility) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when owner = auth.uid() then true
    when vis = 'public' then public.can_view_profile_content(owner)
    when vis = 'friends' then public.are_friends(auth.uid(), owner)
    else false
  end;
$$;

-- Private profiles get follow requests instead of instant follows.
create or replace function public.set_follow_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.follower_id <> auth.uid() then
    raise exception 'cannot follow on behalf of another user';
  end if;
  new.status := case
    when (select is_private from public.profiles where id = new.followee_id) then 'pending'::public.follow_status
    else 'accepted'::public.follow_status
  end;
  return new;
end $$;
create trigger user_follows_status before insert on public.user_follows
  for each row execute function public.set_follow_status();

create or replace function public.respond_follow_request(requester uuid, accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if accept then
    update public.user_follows set status = 'accepted'
    where follower_id = requester and followee_id = auth.uid() and status = 'pending';
  else
    delete from public.user_follows
    where follower_id = requester and followee_id = auth.uid() and status = 'pending';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Wine catalog
-- ---------------------------------------------------------------------------
create table public.wineries (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 200),
  country text,
  region text,
  founded_year int check (founded_year between 1000 and 2100),
  story text,
  practices text[] not null default '{}',
  highlights text[] not null default '{}',
  source public.info_source not null default 'user',
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index wineries_name_unique on public.wineries (lower(name));
create index wineries_name_trgm on public.wineries using gin (lower(name) extensions.gin_trgm_ops);

create table public.wine_products (
  id uuid primary key default gen_random_uuid(),
  winery_id uuid not null references public.wineries (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 200),
  type public.wine_type not null,
  country text,
  region text,
  appellation text,
  grapes text[] not null default '{}',
  grape_percentages int[],
  source public.info_source not null default 'user',
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index wine_products_unique on public.wine_products (winery_id, lower(name));
create index wine_products_name_trgm on public.wine_products using gin (lower(name) extensions.gin_trgm_ops);
create index wine_products_type_idx on public.wine_products (type);
create index wine_products_country_idx on public.wine_products (country, region);
create index wine_products_grapes_idx on public.wine_products using gin (grapes);

create table public.wine_vintages (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.wine_products (id) on delete cascade,
  year int check (year between 1800 and 2100), -- null = non-vintage
  bottle_size_ml int not null default 750 check (bottle_size_ml > 0),
  abv numeric(4, 1) check (abv between 0 and 25),
  price_estimate numeric(10, 2) check (price_estimate >= 0),
  currency char(3) not null default 'USD',
  drink_from int,
  drink_until int,
  label_image_path text,
  bottle_image_path text,
  source public.info_source not null default 'user',
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
-- Distinct vintages of the same wine are distinct rows; NV is year 0 in the key.
create unique index wine_vintages_unique on public.wine_vintages (product_id, coalesce(year, 0), bottle_size_ml);

create table public.wine_images (
  id uuid primary key default gen_random_uuid(),
  vintage_id uuid not null references public.wine_vintages (id) on delete cascade,
  kind public.image_kind not null,
  storage_path text not null,
  uploaded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index wine_images_vintage_idx on public.wine_images (vintage_id, kind);

create table public.wine_characteristics (
  product_id uuid primary key references public.wine_products (id) on delete cascade,
  sweetness real check (sweetness between 0 and 1),
  acidity real check (acidity between 0 and 1),
  body real check (body between 0 and 1),
  tannin real check (tannin between 0 and 1),
  fruitiness real check (fruitiness between 0 and 1),
  flavors text[] not null default '{}',
  tasting_notes text,
  serve_min_c int,
  serve_max_c int,
  decant_minutes int,
  aging_years int,
  source public.info_source not null,
  updated_at timestamptz not null default now()
);

create table public.wine_pairings (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.wine_products (id) on delete cascade,
  name text not null,
  source public.info_source not null default 'editorial',
  unique (product_id, name)
);

-- ---------------------------------------------------------------------------
-- Tastings, reviews and social interactions
-- ---------------------------------------------------------------------------
create table public.tasting_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  vintage_id uuid not null references public.wine_vintages (id) on delete restrict,
  rating numeric(2, 1) check (rating is null or (rating between 0.5 and 5 and rating * 2 = floor(rating * 2))),
  consumed_on date not null default current_date,
  location text check (char_length(location) <= 120),
  occasion text check (char_length(occasion) <= 120),
  drink_again boolean,
  is_favorite boolean not null default false,
  visibility public.visibility not null default 'public',
  tagged_user_ids uuid[] not null default '{}',
  photo_paths text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index tasting_entries_user_idx on public.tasting_entries (user_id, consumed_on desc);
create index tasting_entries_vintage_idx on public.tasting_entries (vintage_id, created_at desc);
create trigger tasting_entries_touch before update on public.tasting_entries
  for each row execute function public.touch_updated_at();

-- Public-facing review text for a tasting entry (inherits the entry's visibility).
create table public.wine_reviews (
  entry_id uuid primary key references public.tasting_entries (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 5000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger wine_reviews_touch before update on public.wine_reviews
  for each row execute function public.touch_updated_at();

-- Personal tasting notes are only ever visible to their author.
create table public.tasting_private_notes (
  entry_id uuid primary key references public.tasting_entries (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  notes text not null check (char_length(notes) <= 5000)
);

create table public.review_likes (
  entry_id uuid not null references public.tasting_entries (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (entry_id, user_id)
);
create index review_likes_user_idx on public.review_likes (user_id);

create table public.review_comments (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.tasting_entries (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index review_comments_entry_idx on public.review_comments (entry_id, created_at);

create or replace function public.can_view_entry(entry uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select public.can_view_content(e.user_id, e.visibility)
    from public.tasting_entries e where e.id = entry
  ), false);
$$;

-- ---------------------------------------------------------------------------
-- Cellar
-- ---------------------------------------------------------------------------
create table public.cellar_collections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  symbol text not null default 'square.grid.2x2',
  created_at timestamptz not null default now(),
  unique (user_id, name)
);

create table public.cellar_bottles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  vintage_id uuid not null references public.wine_vintages (id) on delete restrict,
  quantity int not null default 1 check (quantity >= 0),
  consumed_count int not null default 0 check (consumed_count >= 0),
  purchase_price numeric(10, 2) check (purchase_price >= 0),
  currency char(3) not null default 'USD',
  purchase_date date,
  storage_location text check (char_length(storage_location) <= 120),
  collection_id uuid references public.cellar_collections (id) on delete set null,
  added_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index cellar_bottles_user_idx on public.cellar_bottles (user_id, added_at desc);
create trigger cellar_bottles_touch before update on public.cellar_bottles
  for each row execute function public.touch_updated_at();

create table public.cellar_shelves (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  shelf_index int not null check (shelf_index >= 0),
  label text,
  slot_count int not null default 8 check (slot_count between 1 and 24),
  unique (user_id, shelf_index)
);

create table public.cellar_placements (
  bottle_id uuid primary key references public.cellar_bottles (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  shelf_index int not null check (shelf_index >= 0),
  slot_index int not null check (slot_index >= 0),
  unique (user_id, shelf_index, slot_index)
);

-- Replace all placements atomically (swaps would otherwise violate the unique slot constraint).
create or replace function public.save_cellar_placements(placements jsonb) returns void
language plpgsql security invoker set search_path = public as $$
begin
  delete from public.cellar_placements where user_id = auth.uid();
  insert into public.cellar_placements (bottle_id, user_id, shelf_index, slot_index)
  select (p ->> 'bottle_id')::uuid, auth.uid(), (p ->> 'shelf_index')::int, (p ->> 'slot_index')::int
  from jsonb_array_elements(placements) p;
end $$;

create table public.wishlists (
  user_id uuid not null references public.profiles (id) on delete cascade,
  vintage_id uuid not null references public.wine_vintages (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, vintage_id)
);

-- ---------------------------------------------------------------------------
-- Activity feed, notifications, scan history
-- ---------------------------------------------------------------------------
create table public.activities (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.profiles (id) on delete cascade,
  kind public.activity_kind not null,
  vintage_id uuid references public.wine_vintages (id) on delete cascade,
  entry_id uuid references public.tasting_entries (id) on delete cascade,
  subject_user_id uuid references public.profiles (id) on delete cascade,
  visibility public.visibility not null default 'public',
  created_at timestamptz not null default now()
);
create index activities_actor_idx on public.activities (actor_id, created_at desc);
create index activities_created_idx on public.activities (created_at desc);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  actor_id uuid not null references public.profiles (id) on delete cascade,
  kind public.notification_kind not null,
  entry_id uuid references public.tasting_entries (id) on delete cascade,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index notifications_recipient_idx on public.notifications (recipient_id, created_at desc);

create table public.scan_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  vintage_id uuid references public.wine_vintages (id) on delete set null,
  label_image_path text,
  text_key text,
  confidence real,
  engine text,
  created_at timestamptz not null default now()
);
create index scan_history_user_idx on public.scan_history (user_id, created_at desc);
create index scan_history_text_idx on public.scan_history (user_id, text_key);

-- Server-side cache of AI label readings, keyed by a hash of OCR text.
-- Only Edge Functions (service role) can read or write it.
create table public.label_cache (
  text_hash text primary key,
  extraction jsonb not null,
  suggestion jsonb,
  identity_confidence real not null default 0,
  model text,
  created_at timestamptz not null default now()
);

create table public.device_tokens (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null default 'ios',
  created_at timestamptz not null default now()
);

-- Activity triggers -----------------------------------------------------------
create or replace function public.on_tasting_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  tagged uuid;
begin
  if new.visibility <> 'private' then
    insert into public.activities (actor_id, kind, vintage_id, entry_id, visibility)
    values (new.user_id, 'rated', new.vintage_id, new.id, new.visibility);
    foreach tagged in array new.tagged_user_ids loop
      if tagged <> new.user_id then
        insert into public.notifications (recipient_id, actor_id, kind, entry_id)
        values (tagged, new.user_id, 'tag', new.id);
      end if;
    end loop;
  end if;
  return new;
end $$;
create trigger tasting_entries_activity after insert on public.tasting_entries
  for each row execute function public.on_tasting_insert();

-- Keep activity visibility in sync when an entry's visibility changes.
create or replace function public.on_tasting_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.visibility is distinct from old.visibility then
    if new.visibility = 'private' then
      delete from public.activities where entry_id = new.id;
    else
      update public.activities set visibility = new.visibility where entry_id = new.id;
    end if;
  end if;
  return new;
end $$;
create trigger tasting_entries_visibility after update on public.tasting_entries
  for each row execute function public.on_tasting_update();

create or replace function public.on_cellar_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.activities (actor_id, kind, vintage_id, visibility)
  select new.user_id, 'cellared', new.vintage_id, 'friends'
  where (select default_visibility from public.profiles where id = new.user_id) <> 'private';
  return new;
end $$;
create trigger cellar_bottles_activity after insert on public.cellar_bottles
  for each row execute function public.on_cellar_insert();

create or replace function public.on_wishlist_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.activities (actor_id, kind, vintage_id, visibility)
  select new.user_id, 'wishlisted', new.vintage_id, 'friends'
  where (select default_visibility from public.profiles where id = new.user_id) <> 'private';
  return new;
end $$;
create trigger wishlists_activity after insert on public.wishlists
  for each row execute function public.on_wishlist_insert();

create or replace function public.on_follow_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind)
  values (new.followee_id, new.follower_id,
          case when new.status = 'pending' then 'follow_request'::public.notification_kind else 'follow'::public.notification_kind end);
  return new;
end $$;
create trigger user_follows_notify after insert on public.user_follows
  for each row execute function public.on_follow_insert();

create or replace function public.on_like_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, entry_id)
  select e.user_id, new.user_id, 'like', new.entry_id
  from public.tasting_entries e where e.id = new.entry_id and e.user_id <> new.user_id;
  return new;
end $$;
create trigger review_likes_notify after insert on public.review_likes
  for each row execute function public.on_like_insert();

create or replace function public.on_comment_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, entry_id)
  select e.user_id, new.user_id, 'comment', new.entry_id
  from public.tasting_entries e where e.id = new.entry_id and e.user_id <> new.user_id;
  return new;
end $$;
create trigger review_comments_notify after insert on public.review_comments
  for each row execute function public.on_comment_insert();

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------
-- Aggregate community stats. Runs with owner rights so it can count entries the
-- viewer cannot see, but it only exposes counts/averages of public ratings.
create view public.wine_rating_stats as
  select vintage_id, round(avg(rating)::numeric, 2) as avg_rating, count(rating) as ratings_count
  from public.tasting_entries
  where rating is not null and visibility = 'public'
  group by vintage_id;

-- One row per vintage with everything the app needs to render a wine.
create view public.wine_catalog with (security_invoker = true) as
  select
    v.id, v.product_id, p.name, p.type, p.country, p.region, p.appellation, p.grapes, p.grape_percentages,
    v.year, v.bottle_size_ml, v.abv, v.price_estimate, v.currency, v.drink_from, v.drink_until,
    v.label_image_path, v.bottle_image_path, p.source as facts_source,
    w.id as winery_id, w.name as winery_name, w.country as winery_country, w.region as winery_region,
    w.founded_year as winery_founded_year, w.story as winery_story, w.practices as winery_practices,
    w.highlights as winery_highlights, w.source as winery_source,
    to_jsonb(c) - 'product_id' - 'updated_at' as characteristics,
    coalesce((select array_agg(wp.name order by wp.name) from public.wine_pairings wp where wp.product_id = p.id), '{}') as pairings,
    s.avg_rating, coalesce(s.ratings_count, 0) as ratings_count,
    v.created_at
  from public.wine_vintages v
  join public.wine_products p on p.id = v.product_id
  join public.wineries w on w.id = p.winery_id
  left join public.wine_characteristics c on c.product_id = p.id
  left join public.wine_rating_stats s on s.vintage_id = v.id;

-- Catalog search across name, producer and structured filters.
create or replace function public.search_wines(
  q text default '',
  types public.wine_type[] default null,
  country_filter text default null,
  region_filter text default null,
  grape_filter text default null,
  vintage_filter int default null,
  max_price numeric default null,
  min_rating numeric default null,
  lim int default 40
) returns setof public.wine_catalog
language sql stable security invoker set search_path = public, extensions as $$
  select wc.* from public.wine_catalog wc
  where (coalesce(q, '') = ''
         or lower(wc.name) like '%' || lower(q) || '%'
         or lower(wc.winery_name) like '%' || lower(q) || '%'
         or lower(coalesce(wc.region, '')) like '%' || lower(q) || '%'
         or lower(coalesce(wc.appellation, '')) like '%' || lower(q) || '%'
         or exists (select 1 from unnest(wc.grapes) g where lower(g) like '%' || lower(q) || '%')
         or similarity(lower(wc.name), lower(q)) > 0.3
         or similarity(lower(wc.winery_name), lower(q)) > 0.3)
    and (types is null or wc.type = any(types))
    and (country_filter is null or wc.country ilike country_filter)
    and (region_filter is null or wc.region ilike region_filter)
    and (grape_filter is null or exists (select 1 from unnest(wc.grapes) g where g ilike grape_filter))
    and (vintage_filter is null or wc.year = vintage_filter)
    and (max_price is null or wc.price_estimate <= max_price)
    and (min_rating is null or wc.avg_rating >= min_rating)
  order by
    case when coalesce(q, '') = '' then 0
         else greatest(similarity(lower(wc.name), lower(q)), similarity(lower(wc.winery_name), lower(q))) end desc,
    wc.ratings_count desc, wc.name
  limit least(lim, 100);
$$;

-- Label matching: scores catalog vintages against extracted producer/name/year.
create or replace function public.match_wines(
  producer text, wine_name text, vintage int default null, lim int default 5
) returns table (vintage_id uuid, score real)
language sql stable security invoker set search_path = public, extensions as $$
  with scored as (
    select wc.id, wc.year,
      greatest(
        similarity(lower(wc.name), lower(coalesce(wine_name, ''))),
        similarity(lower(wc.name), lower(coalesce(producer, '') || ' ' || coalesce(wine_name, '')))
      ) * 0.6
      + similarity(lower(wc.winery_name), lower(coalesce(producer, wine_name, ''))) * 0.4 as base
    from public.wine_catalog wc
    where similarity(lower(wc.name), lower(coalesce(wine_name, producer, ''))) > 0.15
       or similarity(lower(wc.winery_name), lower(coalesce(producer, wine_name, ''))) > 0.2
  )
  select id,
    (base * case
       when vintage is null then 0.9
       when year = vintage then 1.0
       else 0.75 end)::real as score
  from scored
  order by score desc
  limit least(lim, 20);
$$;

-- Creates (or finds) the winery / product / vintage for a user-confirmed wine.
-- AI suggestions are attached only from the server-side label cache, never from client input.
create or replace function public.create_wine_from_scan(
  p_producer text, p_name text, p_type public.wine_type,
  p_vintage int default null, p_grapes text[] default '{}', p_country text default null,
  p_region text default null, p_appellation text default null, p_abv numeric default null,
  p_bottle_size_ml int default 750, p_price numeric default null, p_currency text default 'USD',
  p_source public.info_source default 'user', p_scan_text_hash text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  w_id uuid;
  p_id uuid;
  v_id uuid;
  size_ml int := coalesce(p_bottle_size_ml, 750);
  safe_source public.info_source := case when p_source in ('label', 'user') then p_source else 'user' end;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if coalesce(trim(p_producer), '') = '' or coalesce(trim(p_name), '') = '' then
    raise exception 'producer and wine name are required';
  end if;

  select w.id into w_id from public.wineries w where lower(w.name) = lower(trim(p_producer));
  if w_id is null then
    insert into public.wineries (name, country, region, source, created_by)
    values (trim(p_producer), p_country, p_region, safe_source, auth.uid())
    returning id into w_id;
  end if;

  select wp.id into p_id from public.wine_products wp where wp.winery_id = w_id and lower(wp.name) = lower(trim(p_name));
  if p_id is null then
    insert into public.wine_products (winery_id, name, type, country, region, appellation, grapes, source, created_by)
    values (w_id, trim(p_name), p_type, p_country, p_region, p_appellation, coalesce(p_grapes, '{}'), safe_source, auth.uid())
    returning id into p_id;
  end if;

  select v.id into v_id from public.wine_vintages v
  where v.product_id = p_id and coalesce(v.year, 0) = coalesce(p_vintage, 0) and v.bottle_size_ml = size_ml;
  if v_id is null then
    insert into public.wine_vintages (product_id, year, bottle_size_ml, abv, price_estimate, currency, source, created_by)
    values (p_id, p_vintage, size_ml, p_abv, p_price, coalesce(p_currency, 'USD'), safe_source, auth.uid())
    returning id into v_id;
  end if;

  if p_scan_text_hash is not null then
    perform public.attach_cached_suggestion(v_id, p_scan_text_hash);
  end if;
  return v_id;
end $$;

-- Copies AI tasting suggestions from label_cache onto a product that has no profile yet.
create or replace function public.attach_cached_suggestion(target_vintage uuid, scan_text_hash text) returns void
language plpgsql security definer set search_path = public as $$
declare
  p_id uuid;
  s jsonb;
  pairing text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select product_id into p_id from public.wine_vintages where id = target_vintage;
  select suggestion into s from public.label_cache where text_hash = scan_text_hash;
  if p_id is null or s is null or exists (select 1 from public.wine_characteristics where product_id = p_id) then
    return;
  end if;
  insert into public.wine_characteristics (product_id, sweetness, acidity, body, tannin, fruitiness, flavors, tasting_notes,
    serve_min_c, serve_max_c, decant_minutes, aging_years, source)
  values (p_id,
    (s -> 'characteristics' ->> 'sweetness')::real, (s -> 'characteristics' ->> 'acidity')::real,
    (s -> 'characteristics' ->> 'body')::real, (s -> 'characteristics' ->> 'tannin')::real,
    (s -> 'characteristics' ->> 'fruitiness')::real,
    coalesce(array(select jsonb_array_elements_text(s -> 'characteristics' -> 'flavors')), '{}'),
    s ->> 'summary',
    (s -> 'characteristics' ->> 'serve_min_c')::int, (s -> 'characteristics' ->> 'serve_max_c')::int,
    (s -> 'characteristics' ->> 'decant_minutes')::int, (s -> 'characteristics' ->> 'aging_years')::int,
    'ai_suggested')
  on conflict (product_id) do nothing;
  for pairing in select jsonb_array_elements_text(coalesce(s -> 'pairings', '[]'::jsonb)) loop
    insert into public.wine_pairings (product_id, name, source) values (p_id, left(pairing, 80), 'ai_suggested')
    on conflict do nothing;
  end loop;
end $$;

-- Sets the label image on a vintage the first time someone scans it.
create or replace function public.set_vintage_label(target_vintage uuid, path text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if path !~ ('^' || auth.uid()::text || '/') then raise exception 'invalid path'; end if;
  update public.wine_vintages set label_image_path = path
  where id = target_vintage and label_image_path is null;
  insert into public.wine_images (vintage_id, kind, storage_path, uploaded_by)
  values (target_vintage, 'label', path, auth.uid());
end $$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.user_follows enable row level security;
alter table public.wineries enable row level security;
alter table public.wine_products enable row level security;
alter table public.wine_vintages enable row level security;
alter table public.wine_images enable row level security;
alter table public.wine_characteristics enable row level security;
alter table public.wine_pairings enable row level security;
alter table public.tasting_entries enable row level security;
alter table public.wine_reviews enable row level security;
alter table public.tasting_private_notes enable row level security;
alter table public.review_likes enable row level security;
alter table public.review_comments enable row level security;
alter table public.cellar_collections enable row level security;
alter table public.cellar_bottles enable row level security;
alter table public.cellar_shelves enable row level security;
alter table public.cellar_placements enable row level security;
alter table public.wishlists enable row level security;
alter table public.activities enable row level security;
alter table public.notifications enable row level security;
alter table public.scan_history enable row level security;
alter table public.label_cache enable row level security; -- no policies: service role only
alter table public.device_tokens enable row level security;

-- Profiles: identity (name/avatar) is discoverable; content privacy is enforced elsewhere.
create policy "profiles readable by signed-in users" on public.profiles
  for select to authenticated using (true);
create policy "users update own profile" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Follows
create policy "follows visible to participants or when content is visible" on public.user_follows
  for select to authenticated using (
    follower_id = auth.uid() or followee_id = auth.uid()
    or (status = 'accepted' and public.can_view_profile_content(followee_id) and public.can_view_profile_content(follower_id))
  );
create policy "users follow as themselves" on public.user_follows
  for insert to authenticated with check (follower_id = auth.uid());
create policy "users unfollow or remove followers" on public.user_follows
  for delete to authenticated using (follower_id = auth.uid() or followee_id = auth.uid());

-- Catalog: readable by everyone signed in; writes go through security-definer RPCs.
create policy "catalog wineries readable" on public.wineries for select to authenticated using (true);
create policy "catalog products readable" on public.wine_products for select to authenticated using (true);
create policy "catalog vintages readable" on public.wine_vintages for select to authenticated using (true);
create policy "catalog images readable" on public.wine_images for select to authenticated using (true);
create policy "catalog characteristics readable" on public.wine_characteristics for select to authenticated using (true);
create policy "catalog pairings readable" on public.wine_pairings for select to authenticated using (true);

-- Tasting entries
create policy "entries visible per visibility" on public.tasting_entries
  for select to authenticated using (public.can_view_content(user_id, visibility));
create policy "users write own entries" on public.tasting_entries
  for insert to authenticated with check (user_id = auth.uid());
create policy "users update own entries" on public.tasting_entries
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "users delete own entries" on public.tasting_entries
  for delete to authenticated using (user_id = auth.uid());

create policy "reviews visible with entry" on public.wine_reviews
  for select to authenticated using (public.can_view_entry(entry_id));
create policy "users write own reviews" on public.wine_reviews
  for insert to authenticated with check (
    user_id = auth.uid() and exists (select 1 from public.tasting_entries e where e.id = entry_id and e.user_id = auth.uid())
  );
create policy "users update own reviews" on public.wine_reviews
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "users delete own reviews" on public.wine_reviews
  for delete to authenticated using (user_id = auth.uid());

create policy "private notes owner only" on public.tasting_private_notes
  for all to authenticated using (user_id = auth.uid()) with check (
    user_id = auth.uid() and exists (select 1 from public.tasting_entries e where e.id = entry_id and e.user_id = auth.uid())
  );

create policy "likes visible with entry" on public.review_likes
  for select to authenticated using (public.can_view_entry(entry_id));
create policy "users like visible entries" on public.review_likes
  for insert to authenticated with check (user_id = auth.uid() and public.can_view_entry(entry_id));
create policy "users remove own likes" on public.review_likes
  for delete to authenticated using (user_id = auth.uid());

create policy "comments visible with entry" on public.review_comments
  for select to authenticated using (public.can_view_entry(entry_id));
create policy "users comment on visible entries" on public.review_comments
  for insert to authenticated with check (user_id = auth.uid() and public.can_view_entry(entry_id));
create policy "authors or entry owners delete comments" on public.review_comments
  for delete to authenticated using (
    user_id = auth.uid() or exists (select 1 from public.tasting_entries e where e.id = entry_id and e.user_id = auth.uid())
  );

-- Cellar data is private to its owner.
create policy "own collections" on public.cellar_collections
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own bottles" on public.cellar_bottles
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own shelves" on public.cellar_shelves
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own placements" on public.cellar_placements
  for all to authenticated using (user_id = auth.uid()) with check (
    user_id = auth.uid() and exists (select 1 from public.cellar_bottles b where b.id = bottle_id and b.user_id = auth.uid())
  );
create policy "own wishlist" on public.wishlists
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Activities: inserted only by triggers; visible per the actor's privacy.
create policy "activities visible per visibility" on public.activities
  for select to authenticated using (public.can_view_content(actor_id, visibility));

create policy "own notifications" on public.notifications
  for select to authenticated using (recipient_id = auth.uid());
create policy "mark own notifications read" on public.notifications
  for update to authenticated using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
create policy "delete own notifications" on public.notifications
  for delete to authenticated using (recipient_id = auth.uid());

create policy "own scan history" on public.scan_history
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own device tokens" on public.device_tokens
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Grants: anon gets nothing; authenticated gets table access filtered by RLS.
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant usage on schema public to authenticated;
grant select on public.wine_catalog, public.wine_rating_stats to authenticated;
grant execute on function
  public.search_wines, public.match_wines, public.create_wine_from_scan, public.attach_cached_suggestion,
  public.set_vintage_label, public.save_cellar_placements, public.respond_follow_request,
  public.can_view_entry, public.can_view_content, public.can_view_profile_content, public.follows, public.are_friends
  to authenticated;
-- Like/comment counts for entries the viewer is allowed to see.
create or replace function public.entry_stats(entry_ids uuid[])
returns table (entry_id uuid, like_count bigint, comment_count bigint, liked_by_me boolean)
language sql stable security definer set search_path = public as $$
  select e.id,
    (select count(*) from public.review_likes l where l.entry_id = e.id),
    (select count(*) from public.review_comments c where c.entry_id = e.id),
    exists (select 1 from public.review_likes l where l.entry_id = e.id and l.user_id = auth.uid())
  from public.tasting_entries e
  where e.id = any(entry_ids) and public.can_view_content(e.user_id, e.visibility);
$$;
grant execute on function public.entry_stats to authenticated;

-- ---------------------------------------------------------------------------
-- Storage buckets
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values
  ('labels', 'labels', true),
  ('avatars', 'avatars', true),
  ('tasting-photos', 'tasting-photos', false)
on conflict (id) do nothing;

-- Uploads are namespaced by user id: "<uid>/<file>".
create policy "users upload own labels" on storage.objects
  for insert to authenticated with check (bucket_id = 'labels' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "users upload own avatars" on storage.objects
  for insert to authenticated with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "users replace own avatars" on storage.objects
  for update to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "users upload own tasting photos" on storage.objects
  for insert to authenticated with check (bucket_id = 'tasting-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "tasting photos follow entry visibility" on storage.objects
  for select to authenticated using (
    bucket_id = 'tasting-photos' and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (
        select 1 from public.tasting_entries e
        where name = any(e.photo_paths) and public.can_view_content(e.user_id, e.visibility)
      )
    )
  );
create policy "users delete own objects" on storage.objects
  for delete to authenticated using (
    bucket_id in ('labels', 'avatars', 'tasting-photos') and (storage.foldername(name))[1] = auth.uid()::text
  );
