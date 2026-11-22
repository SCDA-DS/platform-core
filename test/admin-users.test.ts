import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createTestDb, sqlFiles, uid, type TestDb } from '@orgtools/testing';
import { fileURLToPath } from 'node:url';

const CORE = sqlFiles(fileURLToPath(new URL('../supabase/migrations', import.meta.url)));
const [ADMIN, PILOT, TROLL] = [31, 32, 33].map(uid);
let t: TestDb;

beforeAll(async () => {
  t = await createTestDb(CORE);
  await t.user(ADMIN, { name: 'dave' });
  await t.user(PILOT, { name: 'pilot' });
  await t.user(TROLL, { name: 'troll' });
  await t.db.query(`update auth.users set email = 'pilot@example.com', last_sign_in_at = '2026-11-20T10:00:00Z' where id = $1`, [PILOT]);
  await t.as(ADMIN, `select public.claim_site_admin()`);
  await t.as(PILOT, `select public.create_org('Rock Hounds', 'rock-hounds', 'ROCK')`);
  await t.as(ADMIN, `select public.block_user($1, 'spam')`, [TROLL]);
});
afterAll(() => t.close());

describe('admin user list', () => {
  it('site admins see every account with orgs and status', async () => {
    const rows = await t.as<{ username: string; email: string | null; orgs: string[]; is_admin: boolean; is_blocked: boolean; blocked_reason: string | null; total: string }>(
      ADMIN, `select username, email, orgs, is_admin, is_blocked, blocked_reason, total from public.admin_users() order by username`);
    expect(rows.map((r) => r.username)).toEqual(['dave', 'pilot', 'troll']);
    expect(rows[1]).toMatchObject({ email: 'pilot@example.com', orgs: ['Rock Hounds'], is_admin: false, is_blocked: false });
    expect(rows[0].is_admin).toBe(true);
    expect(rows[2]).toMatchObject({ is_blocked: true, blocked_reason: 'spam' });
    expect(Number(rows[0].total)).toBe(3);
  });

  it('searches by name or email and pages', async () => {
    expect((await t.as(ADMIN, `select username from public.admin_users('EXAMPLE.com')`)).map((r) => r.username)).toEqual(['pilot']);
    expect(await t.as(ADMIN, `select username from public.admin_users(null, 1, 0)`)).toHaveLength(1);
  });

  it('nobody else can list users', async () => {
    await expect(t.as(PILOT, `select * from public.admin_users()`)).rejects.toThrow(/site admin only/);
    await expect(t.as(null, `select * from public.admin_users()`)).rejects.toThrow();
  });
});
