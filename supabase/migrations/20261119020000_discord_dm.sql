-- Notifications to Discord: players can opt in to get their bell notifications as a Discord DM from the
-- site's bot. Site admins set the bot token (write-only — it is never readable back through the API).
-- Delivery is an outbox worked by pg_cron every minute: open the DM channel (cached), then send.

alter table public.site_settings drop constraint if exists site_settings_key_check;
alter table public.site_settings add constraint site_settings_key_check check (key in ('feedback_webhook', 'discord_app_id', 'tool_urls'));
alter table public.site_settings add constraint site_settings_values_check check (
  (key <> 'discord_app_id' or value ~ '^\d{5,25}$')
  and (key <> 'tool_urls' or jsonb_typeof(value::jsonb) = 'object')
);

-- ---------------------------------------------------------------- secrets (no API access at all)
create table public.private_settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
alter table public.private_settings enable row level security;
revoke all on public.private_settings from anon, authenticated;

create or replace function public.set_discord_bot_token(p_token text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_site_admin() then raise exception 'Only site admins can do that' using errcode = '42501'; end if;
  if p_token is null or trim(p_token) = '' then
    delete from public.private_settings where key = 'discord_bot_token';
  elsif trim(p_token) !~ '^[A-Za-z0-9_.-]{50,100}$' then
    raise exception 'That doesn''t look like a Discord bot token (Developer Portal → your app → Bot → Reset Token).';
  else
    insert into public.private_settings (key, value) values ('discord_bot_token', trim(p_token))
    on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
end $$;
revoke all on function public.set_discord_bot_token(text) from public, anon;
grant execute on function public.set_discord_bot_token(text) to authenticated;

-- Where each tool lives, for links in DMs. Admins can override with site_settings 'tool_urls' (JSON) once there's a custom domain.
create or replace function public.tool_url(p_tool text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select (value::jsonb) ->> p_tool from public.site_settings where key = 'tool_urls' and value ~ '^\s*\{'),
    'https://scda-' || case p_tool when 'cargo' then 'cargo' when 'fleet' then 'fleet' when 'ops' then 'ops'
      when 'trade' then 'trade' when 'market' then 'market' else 'hub' end || '.pages.dev/')
$$;

-- ---------------------------------------------------------------- per-player preferences
create table public.notification_prefs (
  user_id        uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  discord_dm     boolean not null default false,
  -- null = every kind; otherwise only these tools ('ops', 'cargo', 'trade', 'market', 'hub', 'fleet')
  tools          text[] check (tools is null or cardinality(tools) <= 10),
  last_error     text,           -- server-owned: why the last DM failed, shown on the settings page
  last_error_at  timestamptz,
  updated_at     timestamptz not null default now()
);
alter table public.notification_prefs enable row level security;
create policy "prefs: own" on public.notification_prefs for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.notification_prefs from anon, authenticated;
grant select, delete on public.notification_prefs to authenticated;
grant insert (discord_dm, tools) on public.notification_prefs to authenticated;
grant update (discord_dm, tools) on public.notification_prefs to authenticated;

create table public.discord_dm_channels (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  channel_id text not null,
  created_at timestamptz not null default now()
);
alter table public.discord_dm_channels enable row level security;
revoke all on public.discord_dm_channels from anon, authenticated;

-- ---------------------------------------------------------------- outbox
create table public.discord_outbox (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  discord_id  text not null,
  content     text not null,
  step        text not null default 'open' check (step in ('open', 'send')),
  status      text not null default 'pending' check (status in ('pending', 'waiting', 'sent', 'failed')),
  request_id  bigint,
  attempts    int not null default 0,
  error       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index discord_outbox_work_idx on public.discord_outbox (status) where status in ('pending', 'waiting');
alter table public.discord_outbox enable row level security;
revoke all on public.discord_outbox from anon, authenticated;

-- What anyone may know about the bot: whether it's set up, and the app id for the "add the bot" link.
create or replace function public.discord_bot_status()
returns table (configured boolean, app_id text, sent_24h int, failed_24h int)
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.private_settings where key = 'discord_bot_token'),
         (select value from public.site_settings where key = 'discord_app_id'),
         (select count(*)::int from public.discord_outbox where status = 'sent' and updated_at > now() - interval '1 day'),
         (select count(*)::int from public.discord_outbox where status = 'failed' and updated_at > now() - interval '1 day')
$$;
revoke all on function public.discord_bot_status() from public;
grant execute on function public.discord_bot_status() to anon, authenticated;

create or replace function public.discord_message(p_tool text, p_title text, p_body text, p_link text) returns text
language sql stable security definer set search_path = public as $$
  select left('🔔 **' || p_title || '**' || coalesce(E'\n' || p_body, '') ||
    case when p_link is null then '' when p_link ~ '^https?://' then E'\n' || p_link
         else E'\n<' || public.tool_url(p_tool) || p_link || '>' end, 1900)
$$;

-- New notification → queue a DM if the player opted in (and the bot is set up).
create or replace function public.queue_discord_dm() returns trigger
language plpgsql security definer set search_path = public as $$
declare d text;
begin
  if not exists (select 1 from public.private_settings where key = 'discord_bot_token') then return null; end if;
  if not exists (select 1 from public.notification_prefs p where p.user_id = new.user_id and p.discord_dm
                 and (p.tools is null or new.tool = any (p.tools))) then return null; end if;
  select discord_id into d from public.profiles where id = new.user_id;
  if d is null or d !~ '^\d{5,25}$' then return null; end if;
  -- don't let one person's flood build up: at most 30 queued per hour
  if (select count(*) from public.discord_outbox where user_id = new.user_id and created_at > now() - interval '1 hour') >= 30 then return null; end if;
  insert into public.discord_outbox (user_id, discord_id, content)
  values (new.user_id, d, public.discord_message(new.tool, new.title, new.body, new.link));
  return null;
end $$;
create trigger notifications_discord after insert on public.notifications for each row execute function public.queue_discord_dm();

-- Send yourself a test DM (also how players check it works).
create or replace function public.test_discord_dm() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not exists (select 1 from public.private_settings where key = 'discord_bot_token') then
    raise exception 'Discord DMs aren''t set up on this site yet — ask a site admin.';
  end if;
  if not exists (select 1 from public.notification_prefs where user_id = auth.uid() and discord_dm) then
    raise exception 'Turn on Discord DMs first.';
  end if;
  if exists (select 1 from public.discord_outbox where user_id = auth.uid() and created_at > now() - interval '1 minute' and content like '🔔 **Test%') then
    raise exception 'Test sent — give it a minute.';
  end if;
  perform public.notify(auth.uid(), 'hub', 'test', 'Test from SC Org Tools', 'Discord notifications are working.', null);
  -- notify() de-duplicates; make sure a repeat test still queues
  if not exists (select 1 from public.discord_outbox where user_id = auth.uid() and created_at > now() - interval '5 seconds') then
    insert into public.discord_outbox (user_id, discord_id, content)
    select auth.uid(), discord_id, public.discord_message('hub', 'Test from SC Org Tools', 'Discord notifications are working.', null)
    from public.profiles where id = auth.uid() and discord_id ~ '^\d{5,25}$';
  end if;
end $$;
revoke all on function public.test_discord_dm() from public, anon;
grant execute on function public.test_discord_dm() to authenticated;

-- The worker. Called every minute; also safe to call any time.
create or replace function public.discord_dm_tick() returns int
language plpgsql security definer set search_path = public as $$
declare
  tok text;
  hdr jsonb;
  o record;
  resp record;
  ch text;
  n int := 0;
  why text;
begin
  select value into tok from public.private_settings where key = 'discord_bot_token';
  if tok is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return 0; end if;
  hdr := jsonb_build_object('Authorization', 'Bot ' || tok, 'Content-Type', 'application/json');

  -- 1. collect answers to requests already sent
  for o in select * from public.discord_outbox where status = 'waiting' order by id limit 200 loop
    execute 'select status_code, content::text as content, error_msg from net._http_response where id = $1' into resp using o.request_id;
    if resp is null then
      if o.updated_at < now() - interval '10 minutes' then
        update public.discord_outbox set status = 'pending', request_id = null, attempts = attempts + 1, updated_at = now() where id = o.id;
      end if;
      continue;
    end if;
    if resp.status_code between 200 and 299 then
      if o.step = 'open' then
        ch := (resp.content::jsonb) ->> 'id';
        insert into public.discord_dm_channels (user_id, channel_id) values (o.user_id, ch)
        on conflict (user_id) do update set channel_id = excluded.channel_id, created_at = now();
        update public.discord_outbox set step = 'send', status = 'pending', request_id = null, updated_at = now() where id = o.id;
      else
        update public.discord_outbox set status = 'sent', request_id = null, updated_at = now() where id = o.id;
        update public.notification_prefs set last_error = null, last_error_at = null where user_id = o.user_id and last_error is not null;
        n := n + 1;
      end if;
    elsif resp.status_code in (429) or resp.status_code >= 500 or resp.status_code is null then
      update public.discord_outbox set status = case when attempts >= 4 then 'failed' else 'pending' end,
        request_id = null, attempts = attempts + 1, error = coalesce(resp.error_msg, 'HTTP ' || resp.status_code), updated_at = now() where id = o.id;
    else
      why := case
        when resp.status_code = 401 then 'The site''s Discord bot token is wrong or was reset.'
        when resp.status_code = 403 then 'Discord wouldn''t let the bot DM you. Make sure you share a server with the bot and allow DMs from server members.'
        when resp.status_code = 404 and o.step = 'send' then 'Your DM channel went away — will reopen it next time.'
        else 'Discord said HTTP ' || resp.status_code || '.' end;
      if resp.status_code = 404 and o.step = 'send' then
        delete from public.discord_dm_channels where user_id = o.user_id;
        update public.discord_outbox set step = 'open', status = case when attempts >= 2 then 'failed' else 'pending' end,
          request_id = null, attempts = attempts + 1, error = why, updated_at = now() where id = o.id;
      else
        update public.discord_outbox set status = 'failed', request_id = null, error = why, updated_at = now() where id = o.id;
        update public.notification_prefs set last_error = why, last_error_at = now() where user_id = o.user_id;
      end if;
    end if;
  end loop;

  -- 2. send what's ready (oldest first; Discord's limits are generous at this size)
  for o in select * from public.discord_outbox where status = 'pending' order by id limit 50 loop
    if o.created_at < now() - interval '6 hours' then
      update public.discord_outbox set status = 'failed', error = 'Too old to send', updated_at = now() where id = o.id;
      continue;
    end if;
    select channel_id into ch from public.discord_dm_channels where user_id = o.user_id;
    if ch is not null then
      update public.discord_outbox set step = 'send', status = 'waiting', updated_at = now(),
        request_id = net.http_post(
          url := 'https://discord.com/api/v10/channels/' || ch || '/messages',
          body := jsonb_build_object('content', o.content, 'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb)),
          headers := hdr, timeout_milliseconds := 15000)
      where id = o.id;
    else
      update public.discord_outbox set step = 'open', status = 'waiting', updated_at = now(),
        request_id = net.http_post(
          url := 'https://discord.com/api/v10/users/@me/channels',
          body := jsonb_build_object('recipient_id', o.discord_id),
          headers := hdr, timeout_milliseconds := 15000)
      where id = o.id;
    end if;
  end loop;

  delete from public.discord_outbox where status in ('sent', 'failed') and updated_at < now() - interval '14 days';
  return n;
end $$;
revoke all on function public.discord_dm_tick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('platform-discord-dm', '* * * * *', 'select public.discord_dm_tick()');
  else
    raise warning 'pg_cron not available — Discord DMs NOT scheduled';
  end if;
end $$;
