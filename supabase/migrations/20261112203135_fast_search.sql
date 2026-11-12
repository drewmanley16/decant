-- search_wines was a non-inlinable SQL function, so Postgres planned it once without
-- knowing the search text and fell back to scanning the catalog (1.5-8s, sometimes timing out).
-- plpgsql + dynamic SQL plans each search for its actual text.
create or replace function public.search_wines(q text default ''::text, types wine_type[] default null::wine_type[], country_filter text default null::text, region_filter text default null::text, grape_filter text default null::text, vintage_filter integer default null::integer, max_price numeric default null::numeric, min_rating numeric default null::numeric, lim integer default 40)
returns setof wine_catalog
language plpgsql stable
set search_path to 'public', 'extensions'
as $fn$
declare
  k text := public.name_key(trim(coalesce(q, '')));
  pat text := '%' || k || '%';
  hit_ids uuid[];
  page_ids uuid[];
begin
  -- Text matches first, as a small id list. Dynamic SQL gets a plan for the actual
  -- search text, so the trigram indexes are used instead of scanning every wine.
  if k <> '' then
    execute $q$
      select coalesce(array_agg(distinct id), '{}') from (
        select p.id from public.wine_products p
        where public.name_key(p.name) like $1 or public.name_key(p.name) % $2
           or public.name_key(coalesce(p.region, '') || ' ' || coalesce(p.appellation, '')) like $1
        union all
        select p.id from public.wineries w join public.wine_products p on p.winery_id = w.id
        where public.name_key(w.name) like $1 or public.name_key(w.name) % $2
        union all
        select p.id from public.wine_products p
        where cardinality(p.grapes) > 0 and exists (select 1 from unnest(p.grapes) g where public.name_key(g) like $1)
      ) h $q$ into hit_ids using pat, k;
    if cardinality(hit_ids) = 0 then return; end if;
  end if;

  execute $q$
    select array(
      select v.id
      from public.wine_vintages v
      join public.wine_products p on p.id = v.product_id
      join public.wineries w on w.id = p.winery_id
      left join public.wine_rating_stats s on s.vintage_id = v.id
      where ($1 is null or p.id = any($1))
        and ($2::wine_type[] is null or p.type = any($2))
        and ($3::text is null or p.country ilike $3)
        and ($4::text is null or p.region ilike $4)
        and ($5::text is null or exists (select 1 from unnest(p.grapes) g where g ilike $5))
        and ($6::int is null or v.year = $6)
        and ($7::numeric is null or v.price_estimate <= $7)
        and ($8::numeric is null or s.avg_rating >= $8)
      order by
        case when $9 = '' then 0 else greatest(similarity(public.name_key(p.name), $9), similarity(public.name_key(w.name), $9)) end desc,
        coalesce(s.ratings_count, 0) desc, p.name, v.year desc nulls last
      limit least($10, 100)
    ) $q$
    into page_ids
    using hit_ids, types, country_filter, region_filter, grape_filter, vintage_filter, max_price, min_rating, k, lim;

  -- An id array keeps this a primary-key lookup on the view.
  return query
    select wc.* from public.wine_catalog wc
    where wc.id = any(page_ids)
    order by array_position(page_ids, wc.id);
end
$fn$;
