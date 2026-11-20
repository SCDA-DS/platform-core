import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createTestDb, sqlFiles, uid, type TestDb } from '@orgtools/testing';
import { fileURLToPath } from 'node:url';

const CORE = sqlFiles(fileURLToPath(new URL('../supabase/migrations', import.meta.url)));
const [ADMIN, PLAYER, QUIET] = [11, 12, 13].map(uid);
const TOKEN = 'MTA' + 'x'.repeat(60) + '.abc_DEF-1';

// Stand-in for pg_net: requests are recorded; tests write the "responses".
const NET_STUB = `
create schema net;
create table net.requests (id bigserial primary key, url text, body jsonb, headers jsonb);
create table net._http_response (id bigint primary key, status_code int, content text, error_msg text);
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000)
returns bigint language sql as $$ insert into net.requests (url, body, headers) values (url, body, headers) returning id $$;
`;

let t: TestDb;
const q = async <T = Record<string, unknown>>(sql: string, p: unknown[] = []) => (await t.db.query<T>(sql, p)).rows;
const tick = () => q(`select public.discord_dm_tick()`);
const lastReq = async () => (await q<{ id: number; url: string; body: Record<string, unknown>; headers: Record<string, string> }>(`select * from net.requests order by id desc limit 1`))[0];
const answer = (id: number, status: number, content: unknown = {}) => q(`insert into net._http_response values ($1, $2, $3, null)`, [id, status, JSON.stringify(content)]);
const notify = (u: string, title: string) => q(`select public.notify($1, 'ops', 'seat', $2, 'Sat 20:00 UTC', '#op=abc')`, [u, title]);

beforeAll(async () => {
  t = await createTestDb(CORE);
  await t.db.exec(NET_STUB);
  await t.user(ADMIN, { provider_id: '5550001', name: 'admin' });
  await t.user(PLAYER, { provider_id: '5550002', name: 'player' });
  await t.user(QUIET, { provider_id: '5550003', name: 'quiet' });
  await t.as(ADMIN, `select public.claim_site_admin()`);
});
afterAll(() => t.close());

describe('Discord DMs', () => {
  it('only site admins set the bot token, and nobody can read it back', async () => {
    await expect(t.as(PLAYER, `select public.set_discord_bot_token($1)`, [TOKEN])).rejects.toThrow(/site admins/);
    await expect(t.as(ADMIN, `select public.set_discord_bot_token('nope')`)).rejects.toThrow(/doesn't look like/);
    expect((await t.as<{ configured: boolean }>(null, `select * from public.discord_bot_status()`))[0].configured).toBe(false);
    await t.as(ADMIN, `select public.set_discord_bot_token($1)`, [TOKEN]);
    expect((await t.as<{ configured: boolean }>(null, `select * from public.discord_bot_status()`))[0].configured).toBe(true);
    await expect(t.as(ADMIN, `select * from public.private_settings`)).rejects.toThrow(/permission denied/);
    await expect(t.as(ADMIN, `select * from public.discord_outbox`)).rejects.toThrow(/permission denied/);
  });

  it('nothing is queued for players who have not opted in', async () => {
    await notify(QUIET, 'Hello quiet');
    expect(await q(`select * from public.discord_outbox`)).toEqual([]);
    await expect(t.as(QUIET, `select public.test_discord_dm()`)).rejects.toThrow(/Turn on Discord DMs first/);
  });

  it('opens a DM channel, caches it, then sends — with a full link back to the tool', async () => {
    await t.as(PLAYER, `insert into public.notification_prefs (discord_dm) values (true)`);
    await expect(t.as(PLAYER, `update public.notification_prefs set last_error = 'x'`)).rejects.toThrow(/permission denied/);
    await notify(PLAYER, "You're Pilot for Salvage night");
    await tick();
    const open = await lastReq();
    expect(open.url).toBe('https://discord.com/api/v10/users/@me/channels');
    expect(open.body).toEqual({ recipient_id: '5550002' });
    expect(open.headers.Authorization).toBe(`Bot ${TOKEN}`);
    await answer(open.id, 200, { id: '900' });
    await tick();
    const send = await lastReq();
    expect(send.url).toBe('https://discord.com/api/v10/channels/900/messages');
    expect(send.body.content).toBe("🔔 **You're Pilot for Salvage night**\nSat 20:00 UTC\n<https://scda-ops.pages.dev/#op=abc>");
    expect(send.body.allowed_mentions).toEqual({ parse: [] });
    await answer(send.id, 204);
    await tick();
    expect(await q(`select status from public.discord_outbox`)).toEqual([{ status: 'sent' }]);
    // next one goes straight to the cached channel
    await notify(PLAYER, 'Second');
    await tick();
    expect((await lastReq()).url).toBe('https://discord.com/api/v10/channels/900/messages');
  });

  it('respects the per-tool filter and links can be pointed at a custom domain', async () => {
    await t.as(ADMIN, `insert into public.site_settings (key, value) values ('tool_urls', '{"ops": "https://ops.example.org/"}')`);
    await t.as(PLAYER, `update public.notification_prefs set tools = array['trade']`);
    const before = (await q<{ n: number }>(`select count(*)::int as n from public.discord_outbox`))[0].n;
    await notify(PLAYER, 'Filtered out');
    expect((await q<{ n: number }>(`select count(*)::int as n from public.discord_outbox`))[0].n).toBe(before);
    await t.as(PLAYER, `update public.notification_prefs set tools = null`);
    expect((await q<{ m: string }>(`select public.discord_message('ops', 'T', null, '#op=1') as m`))[0].m).toBe('🔔 **T**\n<https://ops.example.org/#op=1>');
  });

  it("explains when Discord won't let the bot DM someone, and retries rate limits", async () => {
    await q(`delete from public.discord_dm_channels`);
    await notify(PLAYER, 'Third');
    await tick();
    await tick(); // the "Second" send is still waiting; this one opens
    const reqs = await q<{ id: number; url: string }>(`select id, url from net.requests order by id desc limit 2`);
    for (const r of reqs) await answer(r.id, r.url.includes('@me') ? 403 : 429);
    await tick();
    const [prefs] = await t.as<{ last_error: string }>(PLAYER, `select last_error from public.notification_prefs`);
    expect(prefs.last_error).toMatch(/share a server with the bot/);
    expect((await q<{ status: string }>(`select status from public.discord_outbox order by id`)).map((r) => r.status)).toEqual(['sent', 'waiting', 'failed']);
  });

  it('players can send themselves a test', async () => {
    await t.as(PLAYER, `select public.test_discord_dm()`);
    expect((await q<{ content: string }>(`select content from public.discord_outbox order by id desc limit 1`))[0].content).toMatch(/^🔔 \*\*Test from SC Org Tools/);
    await expect(t.as(PLAYER, `select public.test_discord_dm()`)).rejects.toThrow(/give it a minute/);
  });
});

describe('donate link', () => {
  it('admins set a donation-site link that anyone can read; other sites are refused', async () => {
    expect((await t.as<{ l: { donate_url: string | null } }>(null, `select public.site_links() as l`))[0].l).toEqual({ donate_url: null });
    await expect(t.as(ADMIN, `insert into public.site_settings (key, value) values ('donate_url', 'https://evil.example/pay')`)).rejects.toThrow(/site_settings_values_check/);
    await expect(t.as(PLAYER, `insert into public.site_settings (key, value) values ('donate_url', 'https://ko-fi.com/scorgtools')`)).rejects.toThrow();
    await t.as(ADMIN, `insert into public.site_settings (key, value) values ('donate_url', 'https://ko-fi.com/scorgtools')`);
    expect((await t.as<{ l: { donate_url: string } }>(null, `select public.site_links() as l`))[0].l.donate_url).toBe('https://ko-fi.com/scorgtools');
  });
});
