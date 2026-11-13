import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { PGLiteSocketServer } from '@electric-sql/pglite-socket';
import { execFile } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const RUNNER = fileURLToPath(new URL('../../shared-kit/packages/migrate/bin/migrate.mjs', import.meta.url));
const port = 56000 + Math.floor(Math.random() * 2000);
const URL_ = `postgresql://postgres:postgres@127.0.0.1:${port}/postgres`;
let db: PGlite;
let server: PGLiteSocketServer;

beforeAll(async () => {
  db = await PGlite.create();
  server = new PGLiteSocketServer({ db, port, host: '127.0.0.1' });
  await server.start();
});
afterAll(async () => {
  await server.stop();
  await db.close();
});

function migrations(files: Record<string, string>) {
  const dir = mkdtempSync(path.join(tmpdir(), 'mig-'));
  for (const [f, sql] of Object.entries(files)) writeFileSync(path.join(dir, f), sql);
  return dir;
}
const migrate = (repo: string, dir: string, env: Record<string, string> = { DATABASE_URL: URL_ }) =>
  run(process.execPath, [RUNNER, '--repo', repo, '--dir', dir], { env: { ...process.env, ...env }, cwd: dir });

describe('orgtools-migrate', () => {
  it('applies new files in order and records them per repo', async () => {
    const dir = migrations({ '0002_b.sql': 'insert into t values (2);', '0001_a.sql': 'create table t (n int); insert into t values (1);' });
    const { stdout } = await migrate('repo-a', dir);
    expect(stdout).toContain('2 applied');
    const rows = await db.query<{ n: number }>('select n from t order by n');
    expect(rows.rows.map((r) => r.n)).toEqual([1, 2]);
    const rec = await db.query<{ version: string }>(`select version from platform_meta.migrations where repo = 'repo-a' order by 1`);
    expect(rec.rows.map((r) => r.version)).toEqual(['0001_a.sql', '0002_b.sql']);
  });

  it('is idempotent', async () => {
    const dir = migrations({ '0001_a.sql': 'create table t2 (n int);' });
    await migrate('repo-b', dir);
    const { stdout } = await migrate('repo-b', dir);
    expect(stdout).toContain('up to date');
  });

  it('tracks repos independently even with the same file names', async () => {
    const dir = migrations({ '0001_a.sql': 'create table t3 (n int);' });
    const { stdout } = await migrate('repo-c', dir);
    expect(stdout).toContain('1 applied');
  });

  it('rolls back a failing migration and exits non-zero', async () => {
    const dir = migrations({ '0001_ok.sql': 'create table good (n int);', '0002_bad.sql': 'create table bad (n int); select nope();' });
    await expect(migrate('repo-d', dir)).rejects.toMatchObject({ code: 1 });
    const bad = await db.query(`select to_regclass('public.bad') as r`);
    expect((bad.rows[0] as { r: unknown }).r).toBeNull();
    const rec = await db.query(`select version from platform_meta.migrations where repo = 'repo-d'`);
    expect(rec.rows).toHaveLength(1);
  });

  it('reads DATABASE_URL from a .env file', async () => {
    const dir = migrations({ '0001_a.sql': 'select 1;' });
    writeFileSync(path.join(dir, '.env'), `VITE_X=1\nDATABASE_URL="${URL_}"\n`);
    const { stdout } = await migrate('repo-e', dir, { DATABASE_URL: '' });
    expect(stdout).toContain('1 applied');
  });

  it('explains usage when arguments are missing', async () => {
    await expect(run(process.execPath, [RUNNER], { env: { ...process.env, DATABASE_URL: '' }, cwd: tmpdir() })).rejects.toMatchObject({ code: 1 });
  });
});
