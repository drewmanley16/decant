-- Sign in with Apple never asks for a username, so those accounts got bot-like
-- `taster_1a2b3c4d` handles. Derive a handle from the person's name instead.

create or replace function public.handle_from_name(p_name text, p_id uuid) returns text
language plpgsql stable set search_path = public, extensions as $$
declare
  base text := left(regexp_replace(lower(extensions.unaccent(coalesce(p_name, ''))), '[^a-z0-9]', '', 'g'), 24);
  candidate text;
  n int := 1;
begin
  if length(base) < 3 or base like 'taster%' then
    return null;
  end if;
  candidate := base;
  while exists (select 1 from public.profiles where username = candidate::citext and id <> p_id) loop
    n := n + 1;
    candidate := base || n::text;
  end loop;
  return candidate;
end $$;

-- New accounts: use the name when sign-up provides one.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  requested text := nullif(new.raw_user_meta_data ->> 'username', '');
  full_name text := coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', '');
  candidate text;
begin
  candidate := coalesce(requested, public.handle_from_name(full_name, new.id),
                        'taster_' || substr(replace(new.id::text, '-', ''), 1, 8));
  if exists (select 1 from public.profiles where username = candidate::citext) then
    candidate := 'taster_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;
  insert into public.profiles (id, username, display_name)
  values (new.id, candidate, full_name);
  return new;
end $$;

-- Apple shares the name with the app after the account exists; when a placeholder
-- handle's owner first gets a name, give them a handle from it.
create or replace function public.upgrade_placeholder_handle() returns trigger
language plpgsql set search_path = public, extensions as $$
begin
  if old.username::text like 'taster\_%' and new.username = old.username
     and new.display_name is distinct from old.display_name then
    new.username := coalesce(public.handle_from_name(new.display_name, new.id), new.username);
  end if;
  return new;
end $$;

drop trigger if exists profiles_upgrade_handle on public.profiles;
create trigger profiles_upgrade_handle before update of display_name on public.profiles
  for each row execute function public.upgrade_placeholder_handle();

-- Existing placeholder handles (none are referenced by @mentions).
do $$
declare r record; h text;
begin
  for r in select id, display_name from public.profiles where username::text like 'taster\_%' order by created_at loop
    h := public.handle_from_name(r.display_name, r.id);
    if h is not null then
      update public.profiles set username = h where id = r.id;
    end if;
  end loop;
end $$;
