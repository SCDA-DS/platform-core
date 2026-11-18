-- Site-wide moderation: site admins and blocked users. Tools check public.is_site_admin() / public.is_blocked().
-- The first admin claims the role once (public.claim_site_admin works only while there are none); after that,
-- admins add and remove each other.

create table public.site_admins (
  user_id  uuid primary key references public.profiles (id) on delete cascade,
  added_by uuid references public.profiles (id) on delete set null,
  added_at timestamptz not null default now()
);

create table public.blocked_users (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  reason     text check (reason is null or char_length(reason) <= 300),
  blocked_by uuid references public.profiles (id) on delete set null,
  blocked_at timestamptz not null default now()
);

alter table public.site_admins enable row level security;
alter table public.blocked_users enable row level security;
revoke all on public.site_admins, public.blocked_users from anon, authenticated;

create or replace function public.is_site_admin(p_user uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public as $$
  select p_user is not null and exists (select 1 from public.site_admins where user_id = p_user)
$$;
create or replace function public.is_blocked(p_user uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public as $$
  select p_user is not null and exists (select 1 from public.blocked_users where user_id = p_user)
$$;
create or replace function public.site_admin_exists() returns boolean
language sql stable security definer set search_path = public as $$ select exists (select 1 from public.site_admins) $$;

-- Admins can see the lists through the API.
create policy "site admins: admins read" on public.site_admins for select using (public.is_site_admin());
create policy "blocked: admins read" on public.blocked_users for select using (public.is_site_admin());
grant select on public.site_admins, public.blocked_users to authenticated;

create or replace function public.claim_site_admin() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  lock table public.site_admins in exclusive mode;
  if exists (select 1 from public.site_admins) then raise exception 'there is already a site admin' using errcode = '42501'; end if;
  insert into public.site_admins (user_id, added_by) values (auth.uid(), auth.uid());
end $$;

create or replace function public.add_site_admin(p_username text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not public.is_site_admin() then raise exception 'site admin only' using errcode = '42501'; end if;
  select id into v from public.profiles where lower(username) = lower(trim(p_username));
  if v is null then raise exception 'no user with Discord username %', p_username using errcode = 'P0002'; end if;
  insert into public.site_admins (user_id, added_by) values (v, auth.uid()) on conflict do nothing;
  delete from public.blocked_users where user_id = v;
  return v;
end $$;

create or replace function public.remove_site_admin(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'site admin only' using errcode = '42501'; end if;
  if (select count(*) from public.site_admins) <= 1 then raise exception 'the last site admin cannot be removed' using errcode = '42501'; end if;
  delete from public.site_admins where user_id = p_user;
end $$;

create or replace function public.block_user(p_user uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'site admin only' using errcode = '42501'; end if;
  if public.is_site_admin(p_user) then raise exception 'site admins cannot be blocked' using errcode = '42501'; end if;
  insert into public.blocked_users (user_id, reason, blocked_by) values (p_user, left(p_reason, 300), auth.uid())
  on conflict (user_id) do update set reason = excluded.reason, blocked_by = excluded.blocked_by, blocked_at = now();
end $$;

create or replace function public.unblock_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'site admin only' using errcode = '42501'; end if;
  delete from public.blocked_users where user_id = p_user;
end $$;

revoke all on function public.claim_site_admin(), public.add_site_admin(text), public.remove_site_admin(uuid),
  public.block_user(uuid, text), public.unblock_user(uuid) from public, anon;
grant execute on function public.claim_site_admin(), public.add_site_admin(text), public.remove_site_admin(uuid),
  public.block_user(uuid, text), public.unblock_user(uuid) to authenticated;
grant execute on function public.is_site_admin(uuid), public.is_blocked(uuid), public.site_admin_exists() to anon, authenticated;
