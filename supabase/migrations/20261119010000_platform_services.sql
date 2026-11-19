-- Shared services every tool uses: in-app notifications, user feedback, and browser error reports.

-- ---------------------------------------------------------------- notifications
create table public.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  tool       text not null check (char_length(tool) <= 20),
  kind       text not null check (char_length(kind) <= 40),
  title      text not null check (char_length(title) <= 140),
  body       text check (body is null or char_length(body) <= 500),
  link       text check (link is null or link ~ '^(https?://|#|/)'),
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;
create policy "notifications: own" on public.notifications for select using (user_id = auth.uid());
create policy "notifications: mark own" on public.notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "notifications: clear own" on public.notifications for delete using (user_id = auth.uid());
revoke all on public.notifications from anon, authenticated;
grant select, delete on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

-- Tools call this from their own (security definer) triggers and functions. Not callable through the API.
create or replace function public.notify(p_user uuid, p_tool text, p_kind text, p_title text, p_body text default null, p_link text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null then return; end if;
  -- don't flood: identical unread notification in the last 10 minutes → skip
  if exists (select 1 from public.notifications where user_id = p_user and kind = p_kind and title = left(p_title, 140)
             and read_at is null and created_at > now() - interval '10 minutes') then return; end if;
  insert into public.notifications (user_id, tool, kind, title, body, link)
  values (p_user, left(p_tool, 20), left(p_kind, 40), left(p_title, 140), left(p_body, 500),
          case when p_link ~ '^(https?://|#|/)' then p_link end);
  -- keep the newest 200 per person
  delete from public.notifications where user_id = p_user and id in (
    select id from public.notifications where user_id = p_user order by created_at desc offset 200);
end $$;
revoke all on function public.notify(uuid, text, text, text, text, text) from public, anon, authenticated;

create or replace function public.mark_notifications_read(p_ids bigint[] default null) returns void
language sql security definer set search_path = public as $$
  update public.notifications set read_at = now()
  where user_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids))
$$;
revoke all on function public.mark_notifications_read(bigint[]) from public, anon;
grant execute on function public.mark_notifications_read(bigint[]) to authenticated;

-- Org access changes are worth telling people about.
create or replace function public.notify_access_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare o text;
begin
  if new.access is distinct from old.access and new.user_id is distinct from auth.uid() then
    select name into o from public.orgs where id = new.org_id;
    perform public.notify(new.user_id, 'hub', 'org_access', 'You are now ' || new.access || ' in ' || coalesce(o, 'your org'), null, '#org=' || new.org_id);
  end if;
  return new;
end $$;
create trigger org_members_notify after update on public.org_members for each row execute function public.notify_access_change();

-- ---------------------------------------------------------------- site settings (admins)
create table public.site_settings (
  key        text primary key check (key in ('feedback_webhook')),
  value      text,
  updated_at timestamptz not null default now()
);
alter table public.site_settings enable row level security;
create policy "settings: admins" on public.site_settings for all using (public.is_site_admin()) with check (public.is_site_admin());
revoke all on public.site_settings from anon, authenticated;
grant select, insert, update, delete on public.site_settings to authenticated;

-- ---------------------------------------------------------------- feedback
create table public.feedback (
  id         bigint generated always as identity primary key,
  user_id    uuid references public.profiles (id) on delete set null,
  tool       text not null check (char_length(tool) <= 20),
  kind       text not null check (kind in ('bug', 'idea', 'other')),
  message    text not null check (char_length(message) between 3 and 2000),
  page       text check (page is null or char_length(page) <= 500),
  user_agent text check (user_agent is null or char_length(user_agent) <= 300),
  status     text not null default 'new' check (status in ('new', 'seen', 'done')),
  created_at timestamptz not null default now()
);
alter table public.feedback enable row level security;
create policy "feedback: admins read" on public.feedback for select using (public.is_site_admin());
create policy "feedback: admins triage" on public.feedback for update using (public.is_site_admin()) with check (public.is_site_admin());
revoke all on public.feedback from anon, authenticated;
grant select on public.feedback to authenticated;
grant update (status) on public.feedback to authenticated;

create or replace function public.submit_feedback(p_tool text, p_kind text, p_message text, p_page text default null, p_user_agent text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  hook text;
  who text;
begin
  if public.is_blocked() then raise exception 'blocked' using errcode = '42501'; end if;
  -- rate limits: 10/hour per person, 30/hour from signed-out visitors in total
  if auth.uid() is not null and (select count(*) from public.feedback where user_id = auth.uid() and created_at > now() - interval '1 hour') >= 10
     or auth.uid() is null and (select count(*) from public.feedback where user_id is null and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too much feedback for now — please try again later' using errcode = '54000';
  end if;
  insert into public.feedback (user_id, tool, kind, message, page, user_agent)
  values (auth.uid(), left(p_tool, 20), p_kind, trim(p_message), left(p_page, 500), left(p_user_agent, 300));
  -- optional: forward to the site's Discord channel
  select value into hook from public.site_settings where key = 'feedback_webhook';
  if hook ~ '^https://(discord|discordapp)\.com/api/webhooks/' and to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null then
    select coalesce(display_name, username) into who from public.profiles where id = auth.uid();
    perform net.http_post(url := hook, headers := '{"Content-Type": "application/json"}'::jsonb, body := jsonb_build_object(
      'username', 'SC Org Tools feedback',
      'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb),
      'content', left(case p_kind when 'bug' then '🐞 **Bug**' when 'idea' then '💡 **Idea**' else '💬 **Feedback**' end
        || ' in ' || p_tool || ' from ' || coalesce(who, 'a visitor') || E'\n' || trim(p_message) || coalesce(E'\n' || p_page, ''), 1900)));
  end if;
end $$;
revoke all on function public.submit_feedback(text, text, text, text, text) from public;
grant execute on function public.submit_feedback(text, text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------- browser errors
create table public.client_errors (
  id          bigint generated always as identity primary key,
  fingerprint text not null unique,
  tool        text not null,
  message     text not null,
  stack       text,
  page        text,
  user_agent  text,
  count       int not null default 1,
  users       int not null default 1,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  resolved    boolean not null default false
);
alter table public.client_errors enable row level security;
create policy "errors: admins" on public.client_errors for select using (public.is_site_admin());
create policy "errors: admins resolve" on public.client_errors for update using (public.is_site_admin()) with check (public.is_site_admin());
revoke all on public.client_errors from anon, authenticated;
grant select on public.client_errors to authenticated;
grant update (resolved) on public.client_errors to authenticated;

create or replace function public.report_client_error(p_tool text, p_message text, p_stack text default null, p_page text default null, p_user_agent text default null)
returns void language plpgsql security definer set search_path = public as $$
declare fp text := md5(coalesce(p_tool, '') || '|' || left(coalesce(p_message, ''), 300));
begin
  if coalesce(trim(p_message), '') = '' then return; end if;
  -- global cap so a broken release can't flood the table
  if (select count(*) from public.client_errors where last_seen > now() - interval '1 minute') > 60 then return; end if;
  insert into public.client_errors (fingerprint, tool, message, stack, page, user_agent)
  values (fp, left(p_tool, 20), left(p_message, 500), left(p_stack, 4000), left(p_page, 500), left(p_user_agent, 300))
  on conflict (fingerprint) do update set count = public.client_errors.count + 1, last_seen = now(), resolved = false,
    stack = coalesce(excluded.stack, public.client_errors.stack), page = excluded.page;
end $$;
revoke all on function public.report_client_error(text, text, text, text, text) from public;
grant execute on function public.report_client_error(text, text, text, text, text) to anon, authenticated;

-- housekeeping (where pg_cron exists): drop read notifications after 60 days, resolved errors after 30
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('platform-housekeeping', '33 3 * * *', $c$
      delete from public.notifications where read_at < now() - interval '60 days';
      delete from public.client_errors where resolved and last_seen < now() - interval '30 days';
    $c$);
  end if;
end $$;
