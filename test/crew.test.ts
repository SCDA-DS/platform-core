import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createHash } from 'node:crypto';
import { createTestDb, sqlFiles, uid, type TestDb } from '@orgtools/testing';
import { fileURLToPath } from 'node:url';

const CORE = sqlFiles(fileURLToPath(new URL('../supabase/migrations', import.meta.url)));
const [PILOT, MEDIC, OUTSIDER, OFFICER] = [51, 52, 53, 54].map(uid);
const TOKEN = 'k3y-'.padEnd(43, 'x');
const HASH = createHash('sha256').update(TOKEN).digest('hex');
let t: TestDb;
let org: string;

beforeAll(async () => {
  t = await createTestDb(CORE);
  for (const [u, n] of [[PILOT, 'pilot'], [MEDIC, 'medic'], [OUTSIDER, 'outsider'], [OFFICER, 'officer']] as const) await t.user(u, { name: n });
  [{ id: org }] = await t.as<{ id: string }>(PILOT, `select id from public.create_org('Medical Corp', 'medcorp')`);
  for (const [u, role] of [[MEDIC, 'member'], [OFFICER, 'officer']] as const) {
    const [i] = await t.as<{ c: string }>(PILOT, `select public.create_invite($1, $2::public.org_access) as c`, [org, role]);
    await t.as(u, `select public.accept_invite($1)`, [i.c]);
  }
});
afterAll(() => t.close());

describe('linking a PC', () => {
  it('app starts a link, the player approves it, the app learns it is linked', async () => {
    await t.as(null, `select crew.start_link('ABCD2345', $1, 'Dave-PC')`, [HASH]);
    expect(await t.as(null, `select state from crew.poll_link('ABCD2345', $1)`, [HASH])).toEqual([{ state: 'pending' }]);
    expect(await t.as(PILOT, `select device_name, approved from crew.link_info('abcd2345')`)).toEqual([{ device_name: 'Dave-PC', approved: false }]);
    await t.as(PILOT, `select crew.approve_link('ABCD2345', $1)`, [org]);
    await expect(t.as(MEDIC, `select crew.approve_link('ABCD2345', null)`)).rejects.toThrow(/already been used/);
    // wrong secret learns nothing
    expect(await t.as(null, `select state from crew.poll_link('ABCD2345', $1)`, ['0'.repeat(64)])).toEqual([{ state: 'expired' }]);
    expect(await t.as(null, `select state, display_name, share_org_name from crew.poll_link('ABCD2345', $1)`, [HASH]))
      .toEqual([{ state: 'approved', display_name: 'pilot', share_org_name: 'Medical Corp' }]);
    // the hash is never readable
    await expect(t.as(PILOT, `select token_hash from crew.devices`)).rejects.toThrow(/permission denied/);
    expect(await t.as(PILOT, `select name from crew.devices`)).toEqual([{ name: 'Dave-PC' }]);
  });

  it('you can only share with your own org', async () => {
    await t.as(null, `select crew.start_link('ZZZZ9999', $1)`, ['a'.repeat(64)]);
    await expect(t.as(OUTSIDER, `select crew.approve_link('ZZZZ9999', $1)`, [org])).rejects.toThrow(/org you're in/);
  });
});

describe('live status', () => {
  it('the app reports with its token; org members see it, outsiders do not', async () => {
    const status = { player_name: 'CMDR_Pilot', health: 62, heart_rate: 118, alive: 'downed', ship: 'Cutlass Red' };
    expect(await t.as(null, `select linked_to, share_org_name from crew.report($1, $2::jsonb, $3::jsonb)`,
      [TOKEN, JSON.stringify(status), JSON.stringify([{ kind: 'downed', detail: { where: 'Hurston' } }, { kind: 'hack' }])]))
      .toEqual([{ linked_to: 'pilot', share_org_name: 'Medical Corp' }]);
    const seen = await t.as<{ player_name: string; status: { heart_rate: number } }>(MEDIC, `select player_name, status from crew.live_status`);
    expect(seen).toHaveLength(1);
    expect(seen[0].status.heart_rate).toBe(118);
    expect(await t.as(MEDIC, `select kind from crew.events`)).toEqual([{ kind: 'downed' }]);
    expect(await t.as(OUTSIDER, `select * from crew.live_status`)).toEqual([]);
    await expect(t.as(null, `select * from crew.live_status`)).rejects.toThrow(/permission denied/);
    await expect(t.as(null, `select * from crew.report('wrong-token', '{}'::jsonb)`)).rejects.toThrow(/isn't linked/);
    await expect(t.as(MEDIC, `update crew.live_status set status = '{}'`)).rejects.toThrow(/permission denied/);
  });

  it('going offline removes you from the screen; unlinking stops reports', async () => {
    await t.as(null, `select crew.go_offline($1)`, [TOKEN]);
    expect(await t.as(MEDIC, `select * from crew.live_status`)).toEqual([]);
    await t.as(PILOT, `delete from crew.devices`);
    await expect(t.as(null, `select * from crew.report($1, '{}'::jsonb)`, [TOKEN])).rejects.toThrow(/isn't linked/);
  });
});

describe('squads', () => {
  it('officers manage squads, members read them', async () => {
    await t.as(OFFICER, `insert into crew.squads (org_id, name, members) values ($1, 'Medic Team', array[$2]::uuid[])`, [org, MEDIC]);
    expect(await t.as(MEDIC, `select name from crew.squads`)).toEqual([{ name: 'Medic Team' }]);
    await expect(t.as(MEDIC, `insert into crew.squads (org_id, name) values ($1, 'Mine')`, [org])).rejects.toThrow(/row-level security/);
    expect(await t.as(OUTSIDER, `select * from crew.squads`)).toEqual([]);
  });
});
