-- Self-service account deletion (privacy). Removes the auth user; profiles and every tool's rows cascade
-- (personal data deleted; shared records like op slots keep the seat but lose the name).
-- Refuses while you're the only owner of an org that still has other members — hand it over first.
-- Orgs where you're the only member are deleted with you.
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare
  me uuid := auth.uid();
  blocking text;
begin
  if me is null then raise exception 'not signed in' using errcode = '42501'; end if;

  select string_agg(o.name, ', ' order by o.name) into blocking
  from public.org_members m
  join public.orgs o on o.id = m.org_id
  where m.user_id = me and m.access = 'owner'
    and not exists (select 1 from public.org_members x where x.org_id = m.org_id and x.access = 'owner' and x.user_id <> me)
    and exists (select 1 from public.org_members x where x.org_id = m.org_id and x.user_id <> me);
  if blocking is not null then
    raise exception 'Make someone else an owner of % first', blocking using errcode = '42501';
  end if;

  delete from public.orgs o
  where exists (select 1 from public.org_members m where m.org_id = o.id and m.user_id = me)
    and not exists (select 1 from public.org_members m where m.org_id = o.id and m.user_id <> me);

  delete from auth.users where id = me;
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
