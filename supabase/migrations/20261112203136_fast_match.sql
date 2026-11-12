-- Same fix as search_wines: plan each label match for its actual text so the
-- trigram indexes are used (was 1.7-6.7s per scan).
create or replace function public.match_wines(producer text, wine_name text, vintage integer default null, lim integer default 5)
returns table(vintage_id uuid, score real)
language plpgsql stable
set search_path to 'public', 'extensions'
as $fn$
declare
  name_q text := public.name_key(coalesce(wine_name, producer, ''));
  producer_q text := public.name_key(coalesce(producer, wine_name, ''));
  full_q text := public.name_key(coalesce(producer, '') || ' ' || coalesce(wine_name, ''));
begin
  return query execute $q$
    with hits as (
      select p.id from public.wine_products p
      where public.name_key(p.name) % $1 or public.name_key(p.name) % $3
      union
      select p.id from public.wineries w join public.wine_products p on p.winery_id = w.id
      where public.name_key(w.name) % $2
    ), scored as (
      select v.id, v.year, p.vintage_config,
        greatest(similarity(public.name_key(p.name), $1), similarity(public.name_key(p.name), $3)) * 0.6
        + similarity(public.name_key(w.name), $2) * 0.4 as base
      from hits
      join public.wine_products p on p.id = hits.id
      join public.wineries w on w.id = p.winery_id
      join public.wine_vintages v on v.product_id = p.id
    )
    select id, (base * case
       when $4::int is null then 0.9
       when year = $4 then 1.0
       -- An "any vintage" row for a vintage wine is the right wine; ensure_vintage() fills in the year.
       when year is null and coalesce(vintage_config, 'vintage') = 'vintage' then 0.97
       else 0.75 end)::real as score
    from scored
    order by score desc
    limit least($5, 20) $q$
  using name_q, producer_q, full_q, vintage, lim;
end
$fn$;
