-- Recruitment: an org's public page (pitch, what it does, when it plays), a directory of recruiting orgs,
-- and applications that officers accept or decline. Applying never needs an invite code.

alter table public.orgs
  add column recruiting  boolean not null default false,
  add column pitch       text check (pitch is null or char_length(pitch) <= 2000),
  add column activities  text[] not null default '{}' check (cardinality(activities) <= 12),
  add column play_times  text check (play_times is null or char_length(play_times) <= 80),
  add column timezone    text check (timezone is null or char_length(timezone) <= 40),
  add column discord_url text check (discord_url is null or discord_url ~ '^https://(discord\.gg|discord\.com/invite)/[A-Za-z0-9-]{2,40}$');

-- Recruiting only makes sense for public orgs.
alter table public.orgs add constraint orgs_recruiting_public check (not recruiting or visibility = 'public');

-- Anyone (even signed out) can browse recruiting orgs, with a member count.
create or replace function public.recruiting_orgs()
returns table (id uuid, slug text, name text, sc_tag text, description text, pitch text, activities text[],
               play_times text, timezone text, discord_url text, members int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, o.slug, o.name, o.sc_tag, o.description, o.pitch, o.activities, o.play_times, o.timezone, o.discord_url,
         (select count(*)::int from public.org_members m where m.org_id = o.id and m.access <> 'guest'), o.created_at
  from public.orgs o where o.visibility = 'public' and o.recruiting
  order by 11 desc, o.name
  limit 500
$$;
revoke all on function public.recruiting_orgs() from public;
grant execute on function public.recruiting_orgs() to anon, authenticated;

-- One public org page by slug (recruiting or not, as long as it's public).
create or replace function public.org_public_page(p_slug text)
returns table (id uuid, slug text, name text, sc_tag text, description text, pitch text, activities text[],
               play_times text, timezone text, discord_url text, members int, recruiting boolean, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, o.slug, o.name, o.sc_tag, o.description, o.pitch, o.activities, o.play_times, o.timezone, o.discord_url,
         (select count(*)::int from public.org_members m where m.org_id = o.id and m.access <> 'guest'), o.recruiting, o.created_at
  from public.orgs o where o.slug = lower(p_slug) and o.visibility = 'public'
$$;
revoke all on function public.org_public_page(text) from public;
grant execute on function public.org_public_page(text) to anon, authenticated;

-- ---------------------------------------------------------------- applications
create table public.org_applications (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  message     text not null check (char_length(message) between 1 and 1000),
  sc_handle   text check (sc_handle is null or char_length(sc_handle) <= 40),
  status      text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'withdrawn')),
  reply       text check (reply is null or char_length(reply) <= 500),
  decided_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  decided_at  timestamptz
);
create unique index org_applications_one_pending on public.org_applications (org_id, user_id) where status = 'pending';
create index org_applications_org_idx on public.org_applications (org_id, status);

alter table public.org_applications enable row level security;
create policy "applications: applicant or officers read" on public.org_applications for select to authenticated
  using (user_id = auth.uid() or public.has_org_access(org_id, 'officer'));
revoke all on public.org_applications from anon, authenticated;
grant select on public.org_applications to authenticated;

create or replace function public.apply_to_org(p_org uuid, p_message text, p_sc_handle text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare o record; me uuid := auth.uid(); new_id uuid; who text; officer uuid;
begin
  if me is null then raise exception 'Sign in with Discord to apply.'; end if;
  if public.is_blocked(me) then raise exception 'Your account is blocked.' using errcode = '42501'; end if;
  select * into o from public.orgs where id = p_org;
  if not found or o.visibility <> 'public' or not o.recruiting then raise exception 'This org isn''t taking applications right now.'; end if;
  if exists (select 1 from public.org_members where org_id = p_org and user_id = me and access <> 'guest') then
    raise exception 'You''re already a member of %.', o.name;
  end if;
  if exists (select 1 from public.org_applications where org_id = p_org and user_id = me and status = 'pending') then
    raise exception 'You''ve already applied — the officers will get back to you.';
  end if;
  if (select count(*) from public.org_applications where user_id = me and created_at > now() - interval '1 day') >= 5 then
    raise exception 'That''s a lot of applications for one day — try again tomorrow.';
  end if;
  if (select count(*) from public.org_applications where org_id = p_org and user_id = me and status = 'declined' and decided_at > now() - interval '7 days') > 0 then
    raise exception 'This org declined your application recently — try again in a week, or talk to them on Discord.';
  end if;
  if coalesce(trim(p_message), '') = '' then raise exception 'Say a little about yourself.'; end if;
  insert into public.org_applications (org_id, user_id, message, sc_handle)
  values (p_org, me, left(trim(p_message), 1000), nullif(left(trim(coalesce(p_sc_handle, '')), 40), ''))
  returning id into new_id;
  select coalesce(display_name, username, 'Someone') into who from public.profiles where id = me;
  for officer in select user_id from public.org_members where org_id = p_org and access in ('officer', 'admin', 'owner') loop
    perform public.notify(officer, 'hub', 'application', who || ' wants to join ' || o.name, left(trim(p_message), 200), '#org=' || p_org || '&tab=members');
  end loop;
  return new_id;
end $$;
revoke all on function public.apply_to_org(uuid, text, text) from public, anon;
grant execute on function public.apply_to_org(uuid, text, text) to authenticated;

create or replace function public.decide_application(p_id uuid, p_accept boolean, p_reply text default null) returns void
language plpgsql security definer set search_path = public as $$
declare a record; oname text;
begin
  select * into a from public.org_applications where id = p_id for update;
  if not found then raise exception 'Application not found.'; end if;
  if not public.has_org_access(a.org_id, 'officer') then raise exception 'Only officers can decide applications.' using errcode = '42501'; end if;
  if a.status <> 'pending' then raise exception 'That application was already %.', a.status; end if;
  update public.org_applications set status = case when p_accept then 'accepted' else 'declined' end,
    reply = nullif(left(trim(coalesce(p_reply, '')), 500), ''), decided_by = auth.uid(), decided_at = now()
  where id = p_id;
  select name into oname from public.orgs where id = a.org_id;
  if p_accept then
    insert into public.org_members (org_id, user_id, access) values (a.org_id, a.user_id, 'member')
    on conflict (org_id, user_id) do update set access = 'member' where public.org_members.access = 'guest';
    perform public.notify(a.user_id, 'hub', 'application_accepted', 'Welcome to ' || oname || '!',
      coalesce(nullif(left(trim(coalesce(p_reply, '')), 300), ''), 'Your application was accepted.'), '#org=' || a.org_id);
  else
    perform public.notify(a.user_id, 'hub', 'application_declined', oname || ' declined your application',
      nullif(left(trim(coalesce(p_reply, '')), 300), ''), '#orgs');
  end if;
end $$;
revoke all on function public.decide_application(uuid, boolean, text) from public, anon;
grant execute on function public.decide_application(uuid, boolean, text) to authenticated;

create or replace function public.withdraw_application(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.org_applications set status = 'withdrawn', decided_at = now()
  where id = p_id and user_id = auth.uid() and status = 'pending';
  if not found then raise exception 'Nothing to withdraw.'; end if;
end $$;
revoke all on function public.withdraw_application(uuid) from public, anon;
grant execute on function public.withdraw_application(uuid) to authenticated;
