-- Expose the crew schema through the Data API (same list as supabase/config.toml).
-- PostgREST reads this in-database setting; wrapped so a hosting restriction can never fail the migration —
-- if it doesn't take, add "crew" under Data API → Exposed schemas in the dashboard instead.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    execute $q$alter role authenticator set pgrst.db_schemas = 'public, graphql_public, hub, fleet, ops, cargo, trade, market, crew'$q$;
    notify pgrst, 'reload config';
  end if;
exception when others then
  raise notice 'Could not set pgrst.db_schemas (%). Expose "crew" in the dashboard.', sqlerrm;
end $$;
