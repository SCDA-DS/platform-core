// Apply platform-core's Supabase migrations (supabase/migrations) to the database in DATABASE_URL.
// Normally the Supabase GitHub integration does this on push to main; use this for local/manual runs.
//   npm run db:push            (reads DATABASE_URL from the environment or ./.env)
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';

let url = process.env.DATABASE_URL;
if (!url && existsSync('.env')) {
  const m = readFileSync('.env', 'utf8').match(/^\s*DATABASE_URL\s*=\s*(.+?)\s*$/m);
  if (m) url = m[1].replace(/^["']|["']$/g, '');
}
if (!url) {
  console.error('Set DATABASE_URL (env or .env) to your Supabase session-pooler connection string.');
  process.exit(1);
}
const win = process.platform === 'win32';
const args = ['supabase', 'db', 'push', win ? `"--remote=${url}"` : `--remote=${url}`, '--yes'];
const r = spawnSync('npx', args, { stdio: 'inherit', shell: win });
process.exit(r.status ?? 1);
