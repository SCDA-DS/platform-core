import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createTestDb, sqlFiles, uid, type TestDb } from '@orgtools/testing';
import { fileURLToPath } from 'node:url';

const CORE = sqlFiles(fileURLToPath(new URL('../supabase/migrations', import.meta.url)));
const [OWNER, OFFICER, APPLICANT, OTHER] = [21, 22, 23, 24].map(uid);
let t: TestDb;
let org: string;
const notes = async (u: string) => t.as<{ kind: string; title: string; link: string }>(u, `select kind, title, link from public.notifications order by id`);

beforeAll(async () => {
  t = await createTestDb(CORE);
  await t.user(OWNER, { name: 'owner' });
  await t.user(OFFICER, { name: 'officer' });
  await t.user(APPLICANT, { name: 'newbie', custom_claims: { global_name: 'Newbie' } });
  await t.user(OTHER, { name: 'other' });
  [{ id: org }] = await t.as<{ id: string }>(OWNER, `select id from public.create_org('Rock Hounds', 'rock-hounds', 'ROCK')`);
  await t.db.query(`insert into public.org_members (org_id, user_id, access) values ($1, $2, 'officer')`, [org, OFFICER]);
});
afterAll(() => t.close());

describe('recruitment', () => {
  it('only public orgs can recruit, and only admins set it up', async () => {
    await expect(t.as(OWNER, `update public.orgs set recruiting = true where id = $1`, [org])).rejects.toThrow(/orgs_recruiting_public/);
    await t.as(OFFICER, `update public.orgs set recruiting = true, visibility = 'public' where id = $1`, [org]); // officers: no effect
    expect((await t.as<{ recruiting: boolean }>(OWNER, `select recruiting from public.orgs where id = $1`, [org]))[0].recruiting).toBe(false);
    await t.as(OWNER, `update public.orgs set visibility = 'public', recruiting = true, pitch = 'Chill miners, AU evenings', activities = '{Mining,Trading}',
      play_times = 'Weeknights 7–10pm', timezone = 'AWST', discord_url = 'https://discord.gg/rockhounds' where id = $1`, [org]);
    await expect(t.as(OWNER, `update public.orgs set discord_url = 'https://evil.example/x' where id = $1`, [org])).rejects.toThrow(/discord_url/);
  });

  it('anyone can browse recruiting orgs and open a public page', async () => {
    const list = await t.as<{ name: string; members: number; activities: string[] }>(null, `select name, members, activities from public.recruiting_orgs()`);
    expect(list).toEqual([{ name: 'Rock Hounds', members: 2, activities: ['Mining', 'Trading'] }]);
    const [page] = await t.as<{ pitch: string; recruiting: boolean }>(null, `select pitch, recruiting from public.org_public_page('ROCK-HOUNDS')`);
    expect(page).toEqual({ pitch: 'Chill miners, AU evenings', recruiting: true });
  });

  it('applying notifies the officers; members and repeat applicants are turned away', async () => {
    await expect(t.as(null, `select public.apply_to_org($1, 'hi')`, [org])).rejects.toThrow(/permission denied/);
    await expect(t.as(OFFICER, `select public.apply_to_org($1, 'hi')`, [org])).rejects.toThrow(/already a member/);
    await t.as(APPLICANT, `select public.apply_to_org($1, 'I mine every night', 'Newbie_SC')`, [org]);
    await expect(t.as(APPLICANT, `select public.apply_to_org($1, 'again')`, [org])).rejects.toThrow(/already applied/);
    expect((await notes(OFFICER)).at(-1)).toEqual({ kind: 'application', title: 'Newbie wants to join Rock Hounds', link: `#org=${org}&tab=members` });
    expect((await notes(OWNER)).at(-1)?.kind).toBe('application');
    expect(await t.as(OTHER, `select * from public.org_applications`)).toEqual([]);
    expect(await t.as(APPLICANT, `select sc_handle from public.org_applications`)).toEqual([{ sc_handle: 'Newbie_SC' }]);
  });

  it('officers accept: the applicant becomes a member and is welcomed', async () => {
    const [a] = await t.as<{ id: string }>(OFFICER, `select id from public.org_applications where status = 'pending'`);
    await expect(t.as(APPLICANT, `select public.decide_application($1, true)`, [a.id])).rejects.toThrow(/Only officers/);
    await t.as(OFFICER, `select public.decide_application($1, true, 'Welcome aboard — ping me on Discord')`, [a.id]);
    expect(await t.as(APPLICANT, `select access from public.org_members where org_id = $1 and user_id = $2`, [org, APPLICANT])).toEqual([{ access: 'member' }]);
    expect((await notes(APPLICANT)).at(-1)).toEqual({ kind: 'application_accepted', title: 'Welcome to Rock Hounds!', link: `#org=${org}` });
    await expect(t.as(OFFICER, `select public.decide_application($1, false)`, [a.id])).rejects.toThrow(/already accepted/);
  });

  it('declines block re-applying for a week; applicants can withdraw', async () => {
    const [{ apply_to_org: id }] = await t.as<{ apply_to_org: string }>(OTHER, `select public.apply_to_org($1, 'hello')`, [org]);
    await t.as(OTHER, `select public.withdraw_application($1)`, [id]);
    const [{ apply_to_org: id2 }] = await t.as<{ apply_to_org: string }>(OTHER, `select public.apply_to_org($1, 'hello again')`, [org]);
    await t.as(OWNER, `select public.decide_application($1, false, 'Full for now')`, [id2]);
    expect((await notes(OTHER)).at(-1)?.title).toBe('Rock Hounds declined your application');
    await expect(t.as(OTHER, `select public.apply_to_org($1, 'please')`, [org])).rejects.toThrow(/declined your application recently/);
  });

  it('stopping recruiting closes applications', async () => {
    await t.as(OWNER, `update public.orgs set recruiting = false where id = $1`, [org]);
    expect(await t.as(null, `select * from public.recruiting_orgs()`)).toEqual([]);
    await t.user(uid(25), {});
    await expect(t.as(uid(25), `select public.apply_to_org($1, 'hi')`, [org])).rejects.toThrow(/isn't taking applications/);
  });
});
