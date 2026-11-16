-- Who an invite code belongs to, so the app can say "Jaden invited you" before sign-up
-- and suggest following them. Returns only public display fields, and nothing for
-- codes that couldn't be redeemed.
create or replace function public.invite_preview(p_code text)
returns table (id uuid, username text, display_name text, avatar_url text)
language sql
stable security definer
set search_path to 'public'
as $$
  select owner.id, owner.username, owner.display_name, owner.avatar_url
  from public.invite_codes c
  join public.profiles owner on owner.id = c.user_id and owner.member_since is not null
  where c.code = upper(trim(p_code))
    and (select count(*) from public.profiles p where p.invited_by = c.user_id) < c.max_uses;
$$;

grant execute on function public.invite_preview(text) to anon, authenticated;
