-- Crew Link: live player status from the Star Citizen telemetry feed, shared with your org.
-- The desktop app never holds a Supabase login. It gets a random device token that the player approves once in the Hub
-- (signed in with Discord); only a SHA-256 of the token is stored. The app reports with that token through crew.report().

create schema if not exists crew;
grant usage on schema crew to anon, authenticated;

-- ---------------------------------------------------------------- linking a PC
create table crew.link_requests (
  code         text primary key check (code ~ '^[A-Z0-9]{8}$'),
  secret_hash  text not null check (secret_hash ~ '^[0-9a-f]{64}$'),
  device_name  text check (device_name is null or char_length(device_name) <= 60),
  user_id      uuid references public.profiles (id) on delete cascade,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '15 minutes',
  approved_at  timestamptz
);

create table crew.devices (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  token_hash   text not null unique,
  name         text not null default 'My PC' check (char_length(name) <= 60),
  share_org    uuid references public.orgs (id) on delete set null,   -- whose Crew Link screen you appear on
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz
);
create index devices_user_idx on crew.devices (user_id);

-- ---------------------------------------------------------------- live status
create table crew.live_status (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  org_id      uuid references public.orgs (id) on delete cascade,
  device_id   uuid references crew.devices (id) on delete cascade,
  player_name text,
  status      jsonb not null default '{}',
  updated_at  timestamptz not null default now()
);
create index live_status_org_idx on crew.live_status (org_id);

create table crew.events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  org_id     uuid references public.orgs (id) on delete cascade,
  kind       text not null check (kind in ('spawn', 'downed', 'dead', 'respawn', 'enter_seat', 'leave_seat', 'need_medic', 'ok')),
  detail     jsonb not null default '{}',
  at         timestamptz not null default now()
);
create index crew_events_org_idx on crew.events (org_id, at desc);
create index crew_events_user_idx on crew.events (user_id, at desc);

-- Officer-made squads, for sub-team views.
create table crew.squads (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.orgs (id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 40),
  color      text not null default '#3fd0c9' check (color ~ '^#[0-9a-fA-F]{6}$'),
  members    uuid[] not null default '{}',
  sort       int not null default 0,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index squads_org_idx on crew.squads (org_id);

-- ---------------------------------------------------------------- access
alter table crew.link_requests enable row level security;
alter table crew.devices       enable row level security;
alter table crew.live_status   enable row level security;
alter table crew.events        enable row level security;
alter table crew.squads        enable row level security;

revoke all on all tables in schema crew from anon, authenticated;
grant select (id, user_id, name, share_org, created_at, last_seen_at) on crew.devices to authenticated;
grant delete on crew.devices to authenticated;
grant select on crew.live_status, crew.events to authenticated;
grant select, insert, update, delete on crew.squads to authenticated;

create policy "devices: own" on crew.devices for select to authenticated using (user_id = auth.uid());
create policy "devices: remove own" on crew.devices for delete to authenticated using (user_id = auth.uid());
create policy "live: me and my org" on crew.live_status for select to authenticated
  using (user_id = auth.uid() or (org_id is not null and public.has_org_access(org_id, 'member')));
create policy "events: me and my org" on crew.events for select to authenticated
  using (user_id = auth.uid() or (org_id is not null and public.has_org_access(org_id, 'member')));
create policy "squads: members read" on crew.squads for select to authenticated using (public.has_org_access(org_id, 'member'));
create policy "squads: officers add" on crew.squads for insert to authenticated with check (public.has_org_access(org_id, 'officer'));
create policy "squads: officers edit" on crew.squads for update to authenticated using (public.has_org_access(org_id, 'officer')) with check (public.has_org_access(org_id, 'officer'));
create policy "squads: officers remove" on crew.squads for delete to authenticated using (public.has_org_access(org_id, 'officer'));

create or replace function crew.token_hash(p_token text) returns text language sql immutable as $$
  select encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex')
$$;

-- ---------------------------------------------------------------- linking RPCs
-- 1. The app picks a code and a random token, and registers the code with the token's hash.
create or replace function crew.start_link(p_code text, p_secret_hash text, p_device_name text default null)
returns timestamptz language plpgsql security definer set search_path = crew, public as $$
declare exp timestamptz;
begin
  delete from crew.link_requests where expires_at < now() - interval '1 hour';
  if (select count(*) from crew.link_requests where approved_at is null and expires_at > now()) > 500 then
    raise exception 'Too many people linking right now — try again in a minute.';
  end if;
  insert into crew.link_requests (code, secret_hash, device_name)
  values (upper(p_code), lower(p_secret_hash), left(nullif(btrim(coalesce(p_device_name, '')), ''), 60))
  returning expires_at into exp;
  return exp;
end $$;

-- 2. The player opens the Hub link, signs in, sees which PC is asking, and approves.
create or replace function crew.link_info(p_code text)
returns table (device_name text, expires_at timestamptz, approved boolean)
language sql stable security definer set search_path = crew, public as $$
  select r.device_name, r.expires_at, r.approved_at is not null
  from crew.link_requests r where r.code = upper(p_code) and r.expires_at > now() and auth.uid() is not null
$$;

create or replace function crew.approve_link(p_code text, p_share_org uuid default null)
returns uuid language plpgsql security definer set search_path = crew, public as $$
declare me uuid := auth.uid(); r crew.link_requests; dev uuid;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if public.is_blocked(me) then raise exception 'Your account is blocked.' using errcode = '42501'; end if;
  select * into r from crew.link_requests where code = upper(p_code) for update;
  if r.code is null or r.expires_at < now() then raise exception 'That code has expired — start linking again from the app.'; end if;
  if r.approved_at is not null then raise exception 'That code has already been used.'; end if;
  if p_share_org is not null and not exists (select 1 from public.org_members where org_id = p_share_org and user_id = me) then
    raise exception 'You can only share with an org you''re in.';
  end if;
  if (select count(*) from crew.devices where user_id = me) >= 10 then raise exception 'You already have 10 PCs linked — remove one first.'; end if;
  insert into crew.devices (user_id, token_hash, name, share_org) values (me, r.secret_hash, coalesce(r.device_name, 'My PC'), p_share_org)
  returning id into dev;
  update crew.link_requests set user_id = me, approved_at = now() where code = r.code;
  return dev;
end $$;

-- 3. The app polls with the code and the token hash; once approved it learns who it's linked to.
create or replace function crew.poll_link(p_code text, p_secret_hash text)
returns table (state text, display_name text, share_org_name text)
language plpgsql security definer set search_path = crew, public as $$
declare r crew.link_requests;
begin
  select * into r from crew.link_requests where code = upper(p_code) and secret_hash = lower(p_secret_hash);
  if r.code is null or (r.approved_at is null and r.expires_at < now()) then
    return query select 'expired'::text, null::text, null::text; return;
  end if;
  if r.approved_at is null then return query select 'pending'::text, null::text, null::text; return; end if;
  delete from crew.link_requests where code = r.code;
  return query
    select 'approved'::text, coalesce(p.display_name, p.username), o.name
    from crew.devices d join public.profiles p on p.id = d.user_id left join public.orgs o on o.id = d.share_org
    where d.token_hash = r.secret_hash;
end $$;

-- ---------------------------------------------------------------- reporting
-- The app sends its current status (only the parts the player switched on) about once a second, plus any new events.
create or replace function crew.report(p_token text, p_status jsonb, p_events jsonb default '[]')
returns table (linked_to text, share_org_name text)
language plpgsql security definer set search_path = crew, public as $$
declare d crew.devices; e jsonb; n int := 0;
begin
  select * into d from crew.devices where token_hash = crew.token_hash(p_token);
  if d.id is null then raise exception 'This PC isn''t linked any more — link it again from the app.' using errcode = '28000'; end if;
  if public.is_blocked(d.user_id) then raise exception 'Account blocked.' using errcode = '42501'; end if;
  if jsonb_typeof(p_status) <> 'object' or pg_column_size(p_status) > 16000 then raise exception 'Status too large.'; end if;
  if jsonb_typeof(coalesce(p_events, '[]')) <> 'array' then raise exception 'Events must be a list.'; end if;

  insert into crew.live_status (user_id, org_id, device_id, player_name, status, updated_at)
  values (d.user_id, d.share_org, d.id, left(p_status->>'player_name', 60), p_status, now())
  on conflict (user_id) do update set org_id = excluded.org_id, device_id = excluded.device_id,
    player_name = coalesce(excluded.player_name, crew.live_status.player_name), status = excluded.status, updated_at = now();

  for e in select * from jsonb_array_elements(coalesce(p_events, '[]')) loop
    exit when n >= 20;
    if e->>'kind' in ('spawn', 'downed', 'dead', 'respawn', 'enter_seat', 'leave_seat', 'need_medic', 'ok') then
      insert into crew.events (user_id, org_id, kind, detail)
      values (d.user_id, d.share_org, e->>'kind', case when pg_column_size(e->'detail') < 2000 then coalesce(e->'detail', '{}') else '{}' end);
      n := n + 1;
    end if;
  end loop;

  update crew.devices set last_seen_at = now() where id = d.id and (last_seen_at is null or last_seen_at < now() - interval '1 minute');
  -- keep two days of events
  delete from crew.events where user_id = d.user_id and at < now() - interval '2 days';

  return query select coalesce(p.display_name, p.username), o.name
    from public.profiles p left join public.orgs o on o.id = d.share_org where p.id = d.user_id;
end $$;

-- The app calls this when the game closes or sharing is paused: you drop off the screen straight away.
create or replace function crew.go_offline(p_token text) returns void
language sql security definer set search_path = crew, public as $$
  delete from crew.live_status where device_id = (select id from crew.devices where token_hash = crew.token_hash(p_token))
$$;

-- In the web tool: change which org a PC shares with.
create or replace function crew.set_device_org(p_device uuid, p_share_org uuid) returns void
language plpgsql security definer set search_path = crew, public as $$
begin
  if not exists (select 1 from crew.devices where id = p_device and user_id = auth.uid()) then raise exception 'Not your PC.'; end if;
  if p_share_org is not null and not exists (select 1 from public.org_members where org_id = p_share_org and user_id = auth.uid()) then
    raise exception 'You can only share with an org you''re in.';
  end if;
  update crew.devices set share_org = p_share_org where id = p_device;
  update crew.live_status set org_id = p_share_org where device_id = p_device;
  update crew.events set org_id = p_share_org where user_id = auth.uid() and at > now() - interval '2 days';
end $$;

revoke all on function crew.start_link(text, text, text), crew.poll_link(text, text), crew.report(text, jsonb, jsonb), crew.go_offline(text),
  crew.link_info(text), crew.approve_link(text, uuid), crew.set_device_org(uuid, uuid), crew.token_hash(text) from public;
grant execute on function crew.start_link(text, text, text), crew.poll_link(text, text), crew.report(text, jsonb, jsonb), crew.go_offline(text) to anon, authenticated;
grant execute on function crew.link_info(text), crew.approve_link(text, uuid), crew.set_device_org(uuid, uuid) to authenticated;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table crew.live_status, crew.events;
  end if;
end $$;
