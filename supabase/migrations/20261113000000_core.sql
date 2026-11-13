-- platform-core 0001: profiles, orgs, membership, invites, shared helpers.

-- Tool schemas are reserved here so the API can expose them from day one.
-- Each tool repo creates its own tables inside its schema.
create schema if not exists hub;
create schema if not exists fleet;
create schema if not exists ops;
create schema if not exists cargo;
create schema if not exists trade;
create schema if not exists market;

grant usage on schema hub, fleet, ops, cargo, trade, market to anon, authenticated, service_role;
alter default privileges in schema hub, fleet, ops, cargo, trade, market
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema hub, fleet, ops, cargo, trade, market
  grant select on tables to anon;
alter default privileges in schema hub, fleet, ops, cargo, trade, market
  grant all on tables to service_role;

-- ---------------------------------------------------------------- types
create type public.org_access as enum ('guest', 'member', 'officer', 'admin', 'owner');
create type public.org_visibility as enum ('public', 'private');

-- ---------------------------------------------------------------- profiles
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  discord_id   text unique,
  username     text,
  display_name text,
  avatar_url   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, discord_id, username, display_name, avatar_url)
  values (
    new.id,
    m ->> 'provider_id',
    coalesce(m ->> 'name', m ->> 'user_name'),
    coalesce(m -> 'custom_claims' ->> 'global_name', m ->> 'full_name', m ->> 'name'),
    m ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------- orgs
create table public.orgs (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{2,31}$'),
  name        text not null check (char_length(name) between 2 and 64),
  sc_tag      text check (sc_tag is null or sc_tag ~ '^[A-Z0-9]{1,10}$'),
  description text,
  visibility  public.org_visibility not null default 'private',
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);

create table public.org_members (
  org_id    uuid not null references public.orgs (id) on delete cascade,
  user_id   uuid not null references public.profiles (id) on delete cascade,
  access    public.org_access not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index org_members_user_idx on public.org_members (user_id);

create table public.org_invites (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.orgs (id) on delete cascade,
  code       text not null unique default replace(left(gen_random_uuid()::text, 13), '-', ''),
  access     public.org_access not null default 'member' check (access in ('guest', 'member', 'officer')),
  max_uses   int check (max_uses is null or max_uses > 0),
  uses       int not null default 0,
  expires_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- helpers
-- True when the signed-in user is in the org with at least p_min access.
-- SECURITY DEFINER so RLS policies can call it without recursion.
create or replace function public.has_org_access(p_org uuid, p_min public.org_access default 'member')
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.org_members m
    where m.org_id = p_org and m.user_id = auth.uid() and m.access >= p_min
  );
$$;

-- ---------------------------------------------------------------- RLS
alter table public.profiles    enable row level security;
alter table public.orgs        enable row level security;
alter table public.org_members enable row level security;
alter table public.org_invites enable row level security;

create policy "profiles: signed-in users can read" on public.profiles
  for select to authenticated using (true);
create policy "profiles: update own" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "orgs: public or member can read" on public.orgs
  for select using (visibility = 'public' or public.has_org_access(id, 'guest'));
create policy "orgs: admins update" on public.orgs
  for update to authenticated using (public.has_org_access(id, 'admin')) with check (public.has_org_access(id, 'admin'));
create policy "orgs: owner deletes" on public.orgs
  for delete to authenticated using (public.has_org_access(id, 'owner'));

create policy "members: org members and self can read" on public.org_members
  for select to authenticated using (user_id = auth.uid() or public.has_org_access(org_id, 'guest'));
create policy "members: leave, or admin removes non-owner" on public.org_members
  for delete to authenticated using (
    access <> 'owner' and (user_id = auth.uid() or public.has_org_access(org_id, 'admin'))
  );

create policy "invites: admins read" on public.org_invites
  for select to authenticated using (public.has_org_access(org_id, 'admin'));
create policy "invites: admins delete" on public.org_invites
  for delete to authenticated using (public.has_org_access(org_id, 'admin'));

-- ---------------------------------------------------------------- RPCs
create or replace function public.create_org(
  p_name text, p_slug text, p_sc_tag text default null, p_visibility public.org_visibility default 'private'
) returns public.orgs language plpgsql security definer set search_path = public as $$
declare o public.orgs;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into public.orgs (name, slug, sc_tag, visibility, created_by)
  values (trim(p_name), lower(trim(p_slug)), nullif(upper(trim(coalesce(p_sc_tag, ''))), ''), p_visibility, auth.uid())
  returning * into o;
  insert into public.org_members (org_id, user_id, access) values (o.id, auth.uid(), 'owner');
  return o;
end $$;

create or replace function public.create_invite(
  p_org uuid, p_access public.org_access default 'member', p_max_uses int default null, p_days int default 7
) returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if not public.has_org_access(p_org, 'admin') then raise exception 'admin access required'; end if;
  insert into public.org_invites (org_id, access, max_uses, expires_at, created_by)
  values (p_org, p_access, p_max_uses, case when p_days is null then null else now() + make_interval(days => p_days) end, auth.uid())
  returning code into c;
  return c;
end $$;

create or replace function public.accept_invite(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare inv public.org_invites;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into inv from public.org_invites where code = lower(trim(p_code)) for update;
  if not found then raise exception 'invite not found'; end if;
  if inv.expires_at is not null and inv.expires_at < now() then raise exception 'invite expired'; end if;
  if inv.max_uses is not null and inv.uses >= inv.max_uses then raise exception 'invite used up'; end if;
  insert into public.org_members (org_id, user_id, access) values (inv.org_id, auth.uid(), inv.access)
  on conflict (org_id, user_id) do nothing;
  if found then update public.org_invites set uses = uses + 1 where id = inv.id; end if;
  return inv.org_id;
end $$;

-- Admins manage access below admin; only owners can grant/revoke admin or owner.
create or replace function public.set_member_access(p_org uuid, p_user uuid, p_access public.org_access)
returns void language plpgsql security definer set search_path = public as $$
declare cur public.org_access;
begin
  select access into cur from public.org_members where org_id = p_org and user_id = p_user;
  if cur is null then raise exception 'not a member'; end if;
  if (p_access >= 'admin' or cur >= 'admin') then
    if not public.has_org_access(p_org, 'owner') then raise exception 'owner access required'; end if;
  elsif not public.has_org_access(p_org, 'admin') then
    raise exception 'admin access required';
  end if;
  if cur = 'owner' and p_access <> 'owner'
     and (select count(*) from public.org_members where org_id = p_org and access = 'owner') = 1 then
    raise exception 'an org needs at least one owner';
  end if;
  update public.org_members set access = p_access where org_id = p_org and user_id = p_user;
end $$;

revoke execute on function public.create_org, public.create_invite, public.accept_invite, public.set_member_access from anon, public;
grant execute on function public.create_org, public.create_invite, public.accept_invite, public.set_member_access to authenticated;
