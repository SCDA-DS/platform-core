-- Site admins: a searchable list of every account (name, Discord username, email, when they joined and last signed in,
-- their orgs, and whether they're blocked or an admin). Read-only; blocking uses public.block_user / unblock_user.

create or replace function public.admin_users(p_q text default null, p_limit int default 50, p_offset int default 0)
returns table (
  id uuid, display_name text, username text, avatar_url text, email text,
  created_at timestamptz, last_sign_in_at timestamptz, orgs text[],
  is_admin boolean, is_blocked boolean, blocked_reason text, total bigint
)
language plpgsql stable security definer set search_path = public, auth as $$
declare q text := nullif(btrim(coalesce(p_q, '')), '');
begin
  if not public.is_site_admin() then raise exception 'site admin only' using errcode = '42501'; end if;
  return query
    select p.id, p.display_name, p.username, p.avatar_url, u.email::text,
           p.created_at, u.last_sign_in_at,
           coalesce((select array_agg(o.name order by o.name) from public.org_members m join public.orgs o on o.id = m.org_id where m.user_id = p.id), '{}'),
           exists (select 1 from public.site_admins a where a.user_id = p.id),
           b.user_id is not null, b.reason,
           count(*) over ()
    from public.profiles p
    left join auth.users u on u.id = p.id
    left join public.blocked_users b on b.user_id = p.id
    where q is null
       or p.display_name ilike '%' || q || '%' or p.username ilike '%' || q || '%' or u.email ilike '%' || q || '%'
       or p.discord_id = q or p.id::text = q
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 500) offset greatest(coalesce(p_offset, 0), 0);
end $$;
revoke all on function public.admin_users(text, int, int) from public, anon;
grant execute on function public.admin_users(text, int, int) to authenticated;
