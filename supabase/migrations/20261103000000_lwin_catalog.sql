-- LWIN catalog support.
--
-- The catalog moves from a hand-written editorial seed to the LWIN database
-- (Liv-ex Wine Identification Number, CC BY 4.0, https://www.liv-ex.com/lwin/).
-- LWIN identifies wines, not vintages, so each LWIN wine gets one
-- "any vintage" catalog row (year null). The concrete vintage is created on
-- demand by ensure_vintage() when a scan reads a year off the label.

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.wine_products
  add column if not exists lwin text unique check (lwin ~ '^[0-9]{7}$'),
  add column if not exists vintage_config text check (vintage_config in ('vintage', 'non_vintage'));

create extension if not exists unaccent with schema extensions;

-- Accent- and case-insensitive key for matching names ("Château" = "Chateau").
create or replace function public.name_key(t text) returns text
-- Fully qualified and without a SET clause so the planner can inline it.
language sql immutable parallel safe as $$
  select lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, '')))
$$;
grant execute on function public.name_key(text) to authenticated, service_role;

-- Trigram indexes on the accent-free key, used by search and label matching.
create index if not exists wine_products_name_key_trgm on public.wine_products using gin (public.name_key(name) extensions.gin_trgm_ops);
create index if not exists wineries_name_key_trgm on public.wineries using gin (public.name_key(name) extensions.gin_trgm_ops);
create index if not exists wine_products_winery_name_idx on public.wine_products (winery_id, public.name_key(name));
create index if not exists wineries_name_key_idx on public.wineries (public.name_key(name));
create index if not exists wine_vintages_product_year_idx on public.wine_vintages (product_id, year);

-- ---------------------------------------------------------------------------
-- Remove editorial estimates (prices, tasting profiles, pairings, stories).
-- Identity facts (producer, name, region, grapes) stay; LWIN takes over.
-- ---------------------------------------------------------------------------
update public.wine_vintages set price_estimate = null, drink_from = null, drink_until = null
  where source = 'editorial';
delete from public.wine_characteristics where source = 'editorial';
delete from public.wine_pairings where product_id in (select id from public.wine_products where source = 'editorial');
update public.wineries set story = null, practices = '{}', highlights = '{}', founded_year = null
  where source = 'editorial';

-- ---------------------------------------------------------------------------
-- Read model: expose vintage_config and lwin (columns appended at the end).
-- ---------------------------------------------------------------------------
create or replace view public.wine_catalog with (security_invoker = true) as
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
    v.created_at,
    p.vintage_config, p.lwin
  from public.wine_vintages v
  join public.wine_products p on p.id = v.product_id
  join public.wineries w on w.id = p.winery_id
  left join public.wine_characteristics c on c.product_id = p.id
  left join public.wine_rating_stats s on s.vintage_id = v.id;

-- ---------------------------------------------------------------------------
-- Search and matching at catalog scale (~200k wines).
-- Both find and rank candidate ids on the base tables using the trigram
-- indexes, then read full rows from wine_catalog only for the final page,
-- so the view's per-row work (pairings, characteristics) runs a few dozen
-- times instead of once per match. Behaviour matches the previous versions.
-- ---------------------------------------------------------------------------
create index if not exists wine_products_place_key_trgm on public.wine_products
  using gin (public.name_key(coalesce(region, '') || ' ' || coalesce(appellation, '')) extensions.gin_trgm_ops);

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
  with params as (
    select public.name_key(trim(coalesce(q, ''))) as k,
           '%' || public.name_key(trim(coalesce(q, ''))) || '%' as pat
  ), text_hits as (
    select p.id from public.wine_products p, params
    where params.k <> ''
      and (public.name_key(p.name) like params.pat
           or public.name_key(p.name) % params.k
           or public.name_key(coalesce(p.region, '') || ' ' || coalesce(p.appellation, '')) like params.pat)
    union
    select p.id from public.wineries w join public.wine_products p on p.winery_id = w.id, params
    where params.k <> '' and (public.name_key(w.name) like params.pat or public.name_key(w.name) % params.k)
    union
    select p.id from public.wine_products p, params
    where params.k <> '' and cardinality(p.grapes) > 0
      and exists (select 1 from unnest(p.grapes) g where public.name_key(g) like params.pat)
  ), ranked as materialized (
    select v.id,
      row_number() over (order by
        case when params.k = '' then 0
             else greatest(similarity(public.name_key(p.name), params.k), similarity(public.name_key(w.name), params.k)) end desc,
        coalesce(s.ratings_count, 0) desc, p.name, v.year desc nulls last) as ord
    from public.wine_vintages v
    join public.wine_products p on p.id = v.product_id
    join public.wineries w on w.id = p.winery_id
    left join public.wine_rating_stats s on s.vintage_id = v.id
    cross join params
    where (params.k = '' or p.id in (select id from text_hits))
      and (types is null or p.type = any(types))
      and (country_filter is null or p.country ilike country_filter)
      and (region_filter is null or p.region ilike region_filter)
      and (grape_filter is null or exists (select 1 from unnest(p.grapes) g where g ilike grape_filter))
      and (vintage_filter is null or v.year = vintage_filter)
      and (max_price is null or v.price_estimate <= max_price)
      and (min_rating is null or s.avg_rating >= min_rating)
    order by ord
    limit least(lim, 100)
  ), page as (
    select coalesce(array_agg(id order by ord), '{}') as ids from ranked
  )
  -- An id array keeps this a primary-key lookup; joining the CTE directly lets
  -- the planner build the whole view (every wine) before filtering.
  select wc.* from public.wine_catalog wc, page
  where wc.id = any(page.ids)
  order by array_position(page.ids, wc.id);
$$;

create or replace function public.match_wines(
  producer text, wine_name text, vintage int default null, lim int default 5
) returns table (vintage_id uuid, score real)
language sql stable security invoker set search_path = public, extensions as $$
  with probe as (
    select public.name_key(coalesce(wine_name, producer, '')) as name_q,
           public.name_key(coalesce(producer, wine_name, '')) as producer_q,
           public.name_key(coalesce(producer, '') || ' ' || coalesce(wine_name, '')) as full_q
  ), hits as (
    select p.id from public.wine_products p, probe
    where public.name_key(p.name) % probe.name_q or public.name_key(p.name) % probe.full_q
    union
    select p.id from public.wineries w join public.wine_products p on p.winery_id = w.id, probe
    where public.name_key(w.name) % probe.producer_q
  ), scored as (
    select v.id, v.year, p.vintage_config,
      greatest(similarity(public.name_key(p.name), probe.name_q), similarity(public.name_key(p.name), probe.full_q)) * 0.6
      + similarity(public.name_key(w.name), probe.producer_q) * 0.4 as base
    from hits
    join public.wine_products p on p.id = hits.id
    join public.wineries w on w.id = p.winery_id
    join public.wine_vintages v on v.product_id = p.id
    cross join probe
  )
  select id,
    (base * case
       when vintage is null then 0.9
       when year = vintage then 1.0
       -- An "any vintage" row for a vintage wine is the right wine; ensure_vintage() fills in the year.
       when year is null and coalesce(vintage_config, 'vintage') = 'vintage' then 0.97
       else 0.75 end)::real as score
  from scored
  order by score desc
  limit least(lim, 20);
$$;

-- ---------------------------------------------------------------------------
-- Find or create the concrete vintage of a catalog wine.
-- ---------------------------------------------------------------------------
create or replace function public.ensure_vintage(p_product uuid, p_year int, p_bottle_size_ml int default 750)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  prod public.wine_products%rowtype;
  size_ml int := coalesce(p_bottle_size_ml, 750);
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_year is not null and (p_year < 1800 or p_year > extract(year from now())::int + 1) then
    raise exception 'invalid vintage';
  end if;
  select * into prod from public.wine_products where id = p_product;
  if not found then raise exception 'unknown wine'; end if;
  if prod.vintage_config = 'non_vintage' then p_year := null; end if;

  select v.id into v_id from public.wine_vintages v
  where v.product_id = p_product and coalesce(v.year, 0) = coalesce(p_year, 0) and v.bottle_size_ml = size_ml;
  if v_id is null then
    insert into public.wine_vintages (product_id, year, bottle_size_ml, source, created_by)
    values (p_product, p_year, size_ml,
            (case when prod.source = 'verified' then 'verified' else 'user' end)::public.info_source, auth.uid())
    returning id into v_id;
  end if;
  return v_id;
end $$;

revoke all on function public.ensure_vintage(uuid, int, int) from public, anon;
grant execute on function public.ensure_vintage(uuid, int, int) to authenticated;

-- ---------------------------------------------------------------------------
-- Staging table for the LWIN importer (supabase/lwin/import_lwin.py).
-- Service role only: RLS on, no policies.
-- ---------------------------------------------------------------------------
create table if not exists public.lwin_import (
  lwin text primary key,
  producer text not null,
  wine_name text not null,
  type public.wine_type not null,
  country text,
  region text,
  appellation text,
  vintage_config text not null
);
alter table public.lwin_import enable row level security;

-- Merges staged rows into wineries / products / "any vintage" rows.
-- Existing wines (e.g. the old seed, or user-created ones) are linked by
-- producer + name instead of duplicated, so user data keeps its references.
-- Name keys are computed once into indexed temp tables so the merge is a few
-- hash joins rather than per-row lookups (~185k rows).
create or replace function public.merge_lwin_import() returns table (wineries_added int, wines_added int, wines_linked int)
language plpgsql security definer set search_path = public as $$
declare
  w_added int; p_added int; p_linked int;
begin
  create temp table s on commit drop as
    select i.*, public.name_key(i.producer) as pk, public.name_key(i.wine_name) as nk,
           public.name_key(i.producer || ' ' || i.wine_name) as fk
    from public.lwin_import i;
  create index on s (pk);

  insert into public.wineries (name, country, region, source)
  select distinct on (s.pk) s.producer, s.country, s.region, 'verified'::public.info_source
  from s
  where not exists (select 1 from public.wineries w where public.name_key(w.name) = s.pk)
  order by s.pk, s.lwin;
  get diagnostics w_added = row_count;

  -- One winery per key (the oldest wins if names collide).
  create temp table wk on commit drop as
    select distinct on (public.name_key(name)) id, public.name_key(name) as k
    from public.wineries order by public.name_key(name), created_at;
  create unique index on wk (k);

  create temp table pk on commit drop as
    select p.id, p.winery_id, public.name_key(p.name) as k, p.lwin from public.wine_products p;
  create index on pk (winery_id, k);

  -- Link existing products that are the same wine. LWIN splits
  -- "Penfolds Grange" into producer + wine, so accept either form.
  with candidates as (
    select distinct on (p.id) p.id as product_id, s.lwin, s.vintage_config, s.country, s.region, s.appellation
    from s
    join wk on wk.k = s.pk
    join pk p on p.winery_id = wk.id and p.lwin is null and p.k in (s.nk, s.fk)
    where not exists (select 1 from pk p2 where p2.lwin = s.lwin)
    order by p.id, s.lwin
  ), unique_lwin as (
    select distinct on (lwin) * from candidates order by lwin, product_id
  )
  update public.wine_products p
  set lwin = c.lwin, vintage_config = c.vintage_config, source = 'verified',
      country = coalesce(p.country, c.country), region = coalesce(p.region, c.region),
      appellation = coalesce(p.appellation, c.appellation)
  from unique_lwin c
  where p.id = c.product_id;
  get diagnostics p_linked = row_count;

  insert into public.wine_products (winery_id, name, type, country, region, appellation, source, lwin, vintage_config)
  select distinct on (wk.id, s.nk) wk.id, s.wine_name, s.type, s.country, s.region, s.appellation, 'verified', s.lwin, s.vintage_config
  from s
  join wk on wk.k = s.pk
  where not exists (select 1 from public.wine_products p where p.lwin = s.lwin)
    and not exists (select 1 from pk p where p.winery_id = wk.id and p.k in (s.nk, s.fk))
  order by wk.id, s.nk, s.lwin;
  get diagnostics p_added = row_count;

  -- One "any vintage" row per LWIN wine that has no vintages yet, so it is
  -- searchable and scannable. Wines that already have vintages keep them.
  insert into public.wine_vintages (product_id, year, source)
  select p.id, null, 'verified'
  from public.wine_products p
  where p.lwin is not null
    and not exists (select 1 from public.wine_vintages v where v.product_id = p.id);

  truncate public.lwin_import;
  return query select w_added, p_added, p_linked;
end $$;

revoke all on function public.merge_lwin_import() from public, anon, authenticated;
