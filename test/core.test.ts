import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createTestDb, sqlFiles, uid, type TestDb } from '@orgtools/testing';
import { fileURLToPath } from 'node:url';

const CORE = sqlFiles(fileURLToPath(new URL('../supabase/migrations', import.meta.url)));
const [DAVE, BOB, CARL, ANNA] = [1, 2, 3, 4].map(uid);

let t: TestDb;
let orgId: string;

beforeAll(async () => {
  t = await createTestDb(CORE);
  await t.user(DAVE, { provider_id: '1001', name: 'dave', custom_claims: { global_name: 'Dave' }, avatar_url: 'https://cdn/a.png' });
  await t.user(BOB, { name: 'bob' });
  await t.user(CARL, { full_name: 'Carl C' });
  await t.user(ANNA, {});
  const [org] = await t.as<{ id: string }>(DAVE, `select * from public.create_org('Test Org', 'test-org', 'tst')`);
  orgId = org.id;
});
afterAll(() => t.close());

const fails = async (p: Promise<unknown>, msg: RegExp) => {
  await expect(p).rejects.toThrow(msg);
};

describe('profiles', () => {
  it('are created from Discord metadata on sign-up', async () => {
    const [p] = await t.as(DAVE, `select discord_id, username, display_name, avatar_url from public.profiles where id = $1`, [DAVE]);
    expect(p).toEqual({ discord_id: '1001', username: 'dave', display_name: 'Dave', avatar_url: 'https://cdn/a.png' });
  });
  it('fall back gracefully when metadata is missing', async () => {
    const [p] = await t.as(DAVE, `select username, display_name from public.profiles where id = $1`, [CARL]);
    expect(p).toEqual({ username: null, display_name: 'Carl C' });
    const [a] = await t.as(DAVE, `select count(*)::int as n from public.profiles where id = $1`, [ANNA]);
    expect(a.n).toBe(1);
  });
  it('are readable by signed-in users but not anon', async () => {
    expect((await t.as(BOB, `select id from public.profiles`)).length).toBe(4);
    expect(await t.as(null, `select id from public.profiles`)).toHaveLength(0);
  });
  it('can only be updated by their owner', async () => {
    await t.as(BOB, `update public.profiles set display_name = 'Hacked' where id = $1`, [DAVE]);
    const [p] = await t.as(DAVE, `select display_name from public.profiles where id = $1`, [DAVE]);
    expect(p.display_name).toBe('Dave');
    await t.as(BOB, `update public.profiles set display_name = 'Bobby' where id = $1`, [BOB]);
    const [b] = await t.as(BOB, `select display_name from public.profiles where id = $1`, [BOB]);
    expect(b.display_name).toBe('Bobby');
  });
});

describe('orgs', () => {
  it('create_org makes the caller owner and normalises slug/tag', async () => {
    const [m] = await t.as(DAVE, `select access from public.org_members where org_id = $1 and user_id = $2`, [orgId, DAVE]);
    expect(m.access).toBe('owner');
    const [o] = await t.as(DAVE, `select slug, sc_tag, visibility from public.orgs where id = $1`, [orgId]);
    expect(o).toEqual({ slug: 'test-org', sc_tag: 'TST', visibility: 'private' });
  });
  it('rejects bad slugs, duplicate slugs and anonymous callers', async () => {
    await fails(t.as(BOB, `select public.create_org('X', 'No Spaces!')`), /check constraint/);
    await fails(t.as(BOB, `select public.create_org('Dup', 'test-org')`), /duplicate key/);
    await fails(t.as(null, `select public.create_org('Anon', 'anon-org')`), /permission denied/);
  });
  it('private orgs are hidden from non-members; public orgs are visible', async () => {
    expect(await t.as(BOB, `select id from public.orgs where id = $1`, [orgId])).toHaveLength(0);
    const [pub] = await t.as<{ id: string }>(CARL, `select id from public.create_org('Open Org', 'open-org', null, 'public')`);
    expect(await t.as(BOB, `select id from public.orgs where id = $1`, [pub.id])).toHaveLength(1);
    expect(await t.as(null, `select id from public.orgs where id = $1`, [pub.id])).toHaveLength(1);
  });
  it('cannot be inserted directly (only via create_org)', async () => {
    await fails(t.as(BOB, `insert into public.orgs (slug, name) values ('sneaky', 'Sneaky')`), /row-level security/);
  });
  it('only admins can rename; only owners can delete', async () => {
    await t.as(BOB, `update public.orgs set name = 'Pwned' where id = $1`, [orgId]);
    const [o] = await t.as(DAVE, `select name from public.orgs where id = $1`, [orgId]);
    expect(o.name).toBe('Test Org');
  });
});

describe('invites and membership', () => {
  let code: string;
  it('only admins can create invites', async () => {
    await fails(t.as(BOB, `select public.create_invite($1)`, [orgId]), /admin access required/);
    const [r] = await t.as<{ c: string }>(DAVE, `select public.create_invite($1) as c`, [orgId]);
    code = r.c;
    expect(code).toMatch(/^[0-9a-f]{12}$/);
  });
  it('accepting an invite joins with its access level, once', async () => {
    const [r] = await t.as<{ o: string }>(BOB, `select public.accept_invite($1) as o`, [code.toUpperCase()]);
    expect(r.o).toBe(orgId);
    await t.as(BOB, `select public.accept_invite($1)`, [code]);
    const [inv] = await t.as(DAVE, `select uses from public.org_invites where code = $1`, [code]);
    expect(inv.uses).toBe(1);
    const [m] = await t.as(BOB, `select access from public.org_members where org_id = $1 and user_id = $2`, [orgId, BOB]);
    expect(m.access).toBe('member');
  });
  it('rejects unknown, expired and used-up invites', async () => {
    await fails(t.as(CARL, `select public.accept_invite('nope')`), /invite not found/);
    const [x] = await t.as<{ c: string }>(DAVE, `select public.create_invite($1, 'member', 1, 7) as c`, [orgId]);
    await t.as(CARL, `select public.accept_invite($1)`, [x.c]);
    await fails(t.as(ANNA, `select public.accept_invite($1)`, [x.c]), /used up/);
    const [y] = await t.as<{ c: string }>(DAVE, `select public.create_invite($1) as c`, [orgId]);
    await t.db.query(`update public.org_invites set expires_at = now() - interval '1 day' where code = $1`, [y.c]);
    await fails(t.as(ANNA, `select public.accept_invite($1)`, [y.c]), /expired/);
  });
  it('invites cannot grant admin', async () => {
    await fails(t.as(DAVE, `select public.create_invite($1, 'admin')`, [orgId]), /check constraint/);
  });
  it('members see their org and its members; outsiders see nothing', async () => {
    expect(await t.as(BOB, `select id from public.orgs where id = $1`, [orgId])).toHaveLength(1);
    expect((await t.as(BOB, `select user_id from public.org_members where org_id = $1`, [orgId])).length).toBe(3);
    expect(await t.as(ANNA, `select user_id from public.org_members where org_id = $1`, [orgId])).toHaveLength(0);
    expect(await t.as(BOB, `select id from public.org_invites`)).toHaveLength(0);
  });
  it('has_org_access respects the access ladder', async () => {
    const [r] = await t.as(BOB, `select public.has_org_access($1, 'member') as m, public.has_org_access($1, 'officer') as o`, [orgId]);
    expect(r).toEqual({ m: true, o: false });
  });
});

describe('member access management', () => {
  it('admins manage below admin; only owners grant admin', async () => {
    await t.as(DAVE, `select public.set_member_access($1, $2, 'admin')`, [orgId, BOB]);
    await t.as(BOB, `select public.set_member_access($1, $2, 'officer')`, [orgId, CARL]);
    const [c] = await t.as(DAVE, `select access from public.org_members where org_id = $1 and user_id = $2`, [orgId, CARL]);
    expect(c.access).toBe('officer');
    await fails(t.as(BOB, `select public.set_member_access($1, $2, 'admin')`, [orgId, CARL]), /owner access required/);
    await fails(t.as(BOB, `select public.set_member_access($1, $2, 'member')`, [orgId, DAVE]), /owner access required/);
    await fails(t.as(CARL, `select public.set_member_access($1, $2, 'guest')`, [orgId, BOB]), /owner access required/);
  });
  it('an org always keeps an owner', async () => {
    await fails(t.as(DAVE, `select public.set_member_access($1, $2, 'admin')`, [orgId, DAVE]), /at least one owner/);
  });
  it('members can leave, owners cannot be removed, admins remove non-owners', async () => {
    await t.as(DAVE, `delete from public.org_members where org_id = $1 and user_id = $2`, [orgId, DAVE]);
    expect(await t.as(DAVE, `select 1 from public.org_members where org_id = $1 and user_id = $2`, [orgId, DAVE])).toHaveLength(1);
    await t.as(BOB, `delete from public.org_members where org_id = $1 and user_id = $2`, [orgId, CARL]);
    expect(await t.as(DAVE, `select 1 from public.org_members where org_id = $1 and user_id = $2`, [orgId, CARL])).toHaveLength(0);
    await t.as(BOB, `delete from public.org_members where org_id = $1 and user_id = $2`, [orgId, BOB]);
    expect(await t.as(DAVE, `select 1 from public.org_members where org_id = $1 and user_id = $2`, [orgId, BOB])).toHaveLength(0);
  });
});

describe('tool schemas', () => {
  it('reserves every tool schema with usage for signed-in users', async () => {
    const rows = await t.db.query<{ nspname: string }>(
      `select nspname from pg_namespace where nspname in ('hub','fleet','ops','cargo','trade','market') order by 1`,
    );
    expect(rows.rows.map((r) => r.nspname)).toEqual(['cargo', 'fleet', 'hub', 'market', 'ops', 'trade']);
    const [u] = await t.as(BOB, `select has_schema_privilege('cargo', 'usage') as ok`);
    expect(u.ok).toBe(true);
  });
});

describe('account deletion', () => {
  const [SOLO, HEIR, LONER] = [11, 12, 13].map(uid);

  it('refuses while you are the only owner of an org with other members', async () => {
    await t.user(SOLO, { name: 'solo' });
    await t.user(HEIR, { name: 'heir' });
    const [{ id: shared }] = await t.as<{ id: string }>(SOLO, `select id from public.create_org('Shared Org', 'shared-org', null)`);
    await t.db.query(`insert into public.org_members (org_id, user_id) values ($1, $2)`, [shared, HEIR]);
    await fails(t.as(SOLO, `select public.delete_my_account()`), /Make someone else an owner of Shared Org first/);
    await t.as(SOLO, `select public.set_member_access($1, $2, 'owner')`, [shared, HEIR]);
    await t.as(SOLO, `select public.delete_my_account()`);
    expect(await t.as(HEIR, `select id from public.profiles where id = $1`, [SOLO])).toHaveLength(0);
    expect((await t.as(HEIR, `select user_id from public.org_members where org_id = $1`, [shared])).map((r) => r.user_id)).toEqual([HEIR]);
  });

  it('deletes orgs where you were the only member, and needs you signed in', async () => {
    await t.user(LONER, { name: 'loner' });
    const [{ id: lonely }] = await t.as<{ id: string }>(LONER, `select id from public.create_org('Lonely Org', 'lonely-org', null)`);
    await t.as(LONER, `select public.delete_my_account()`);
    expect((await t.db.query(`select id from public.orgs where id = $1`, [lonely])).rows).toHaveLength(0);
    expect((await t.db.query(`select id from auth.users where id = $1`, [LONER])).rows).toHaveLength(0);
    await fails(t.as(null, `select public.delete_my_account()`), /permission denied/);
  });
});
