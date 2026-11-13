# platform-core

Owns the shared Supabase setup and the **core schema** every tool depends on:

- `public.profiles` — one row per user, filled from Discord on first sign-in
- `public.orgs`, `public.org_members` (access: guest < member < officer < admin < owner), `public.org_invites`
- RPCs: `create_org`, `accept_invite`, `create_invite`, `set_member_access`
- helper `public.has_org_access(org_id, min_access)` used by every tool's row-level security
- reserves the tool schemas: `hub, fleet, ops, cargo, trade, market`

## How the database is deployed

| What | Where the SQL lives | How it reaches Supabase |
|---|---|---|
| Core schema (this repo) | `supabase/migrations/<timestamp>_name.sql` | **Supabase GitHub integration** on push to `main` |
| Each tool's schema | `<tool>/db/migrations/*.sql` | That tool's **Deploy database** GitHub Action (secret `SUPABASE_DB_URL`) |

Supabase records core migrations in `supabase_migrations.schema_migrations`; tool migrations
are recorded per repo in `platform_meta.migrations`. Never edit an applied file — add a new one.
New core migration: `npx supabase migration new <name>`.

### Connect the GitHub integration (once)
Supabase dashboard → Project Settings → Integrations → GitHub → Authorize →
repository `SCDA-DS/platform-core`, working directory `.`, production branch `main`,
turn on **Deploy to production**.

Auth settings (Discord provider, site URL, redirect URLs) and **exposed schemas** are set in the
dashboard, not deployed from `config.toml` — that keeps the Discord secret out of git.
`supabase/config.toml` is for the local Docker stack.

## Commands
| | |
|---|---|
| `npm run db:start` | start local Supabase (Docker) — applies core migrations, prints URL + anon key |
| `npm run db:push` | apply core migrations to `DATABASE_URL` (manual / no integration) |
| `npm run db:migrate:tools` | apply every tool repo's migrations to its own `DATABASE_URL` |
| `npm run db:migrate:all` | both of the above |
| `npm run db:reset` | rebuild the local database from scratch |
| `npm test` | core schema + RLS tests and migration-runner tests (in-process Postgres) |

## Discord login (local)
`supabase/config.toml` enables Discord for the local stack and reads `DISCORD_CLIENT_ID` /
`DISCORD_CLIENT_SECRET` from `platform-core/.env`. Discord redirect for local:
`http://127.0.0.1:54321/auth/v1/callback`.
