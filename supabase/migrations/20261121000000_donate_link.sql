-- Optional donate link shown in every tool's footer. Admins set it (Hub → Site moderation → Settings);
-- anyone can read it through public.site_links(). Only well-known donation sites are accepted.
alter table public.site_settings drop constraint if exists site_settings_key_check;
alter table public.site_settings add constraint site_settings_key_check
  check (key in ('feedback_webhook', 'discord_app_id', 'tool_urls', 'donate_url'));
alter table public.site_settings drop constraint if exists site_settings_values_check;
alter table public.site_settings add constraint site_settings_values_check check (
  (key <> 'discord_app_id' or value ~ '^\d{5,25}$')
  and (key <> 'tool_urls' or jsonb_typeof(value::jsonb) = 'object')
  and (key <> 'donate_url' or value ~ '^https://(www\.)?(ko-fi\.com|buymeacoffee\.com|paypal\.me|paypal\.com/donate|github\.com/sponsors|patreon\.com|liberapay\.com|opencollective\.com)/[A-Za-z0-9_./?=&%-]{1,200}$')
);

create or replace function public.site_links() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('donate_url', (select value from public.site_settings where key = 'donate_url'))
$$;
revoke all on function public.site_links() from public;
grant execute on function public.site_links() to anon, authenticated;
