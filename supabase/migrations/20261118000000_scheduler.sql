-- Scheduled jobs and outbound HTTP inside the database, for tools that need them (hourly price sync,
-- Discord reminders). Supabase provides both extensions; elsewhere (local tests) this is skipped.
do $$
begin
  begin
    create extension if not exists pg_net with schema extensions;
  exception when others then
    raise warning 'pg_net not available: %', sqlerrm;
  end;
  begin
    create extension if not exists pg_cron with schema pg_catalog;
    grant usage on schema cron to postgres;
  exception when others then
    raise warning 'pg_cron not available: %', sqlerrm;
  end;
end $$;
