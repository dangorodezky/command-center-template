# Command Center

A single personal tracker across whatever projects/ventures/areas of life you're juggling,
with a "Priority Stack" that surfaces the single most urgent open item across all of them —
so you see one screen instead of five separate tools.

This is a template repo: clone it, connect your own free Supabase project, deploy it to your
own free Cloudflare Pages project, and you have your own private instance. No login system,
no shared backend — every instance is fully independent.

## Stack

- **Data:** [Supabase](https://supabase.com) (Postgres) — `schema.sql` defines `projects`,
  `tasks`, `activity_log`, `recurring_tasks`, `goals`, `metrics`, `list_items`. Row-level
  security is set to "allow all," since this is meant for one person's own private instance,
  not a multi-tenant product — see the security note below.
- **Frontend:** `dashboard.html` — a single static file, no build step, no framework. Talks to
  Supabase directly from the browser via `supabase-js` (CDN).
- **Hosting:** [Cloudflare Pages](https://pages.cloudflare.com), free tier. Push to a GitHub
  repo, connect it in Cloudflare, done — every push auto-deploys.
- **Optional AI quick-add:** `functions/parse-task.js`, a Cloudflare Pages Function that turns
  freeform text ("work: run capture rates, by noon") into a structured task via the Claude
  API. Needs your own Anthropic API key as a Cloudflare secret. Skip this entirely if you don't
  want it — the rest of the dashboard works without it.

## Get started

See **[SETUP.md](SETUP.md)** for step-by-step setup instructions — written to be followed
literally (exact commands, exact links), so an AI coding assistant (Claude Code or similar)
can run through it for you and hand you back a working link.

## Customizing

`CLAUDE.md` documents the schema conventions, the priority rubric, and a handful of
code-pattern gotchas worth knowing before you extend `dashboard.html` — read it before making
structural changes, especially if you're pointing an AI assistant at this codebase to add
features.

## Security note

The Supabase anon/publishable key ends up embedded in `dashboard.html`, and RLS is "allow
all" — anyone who has that key has full read/write access to your data. That's an acceptable
tradeoff for a single-user personal tool on an unlisted URL, but:

- Keep your deployed Cloudflare Pages URL unlisted (don't link it publicly).
- If you ever want multiple people using one instance, replace the "allow all" RLS policies
  with real per-user policies first — this template does not include that.
- Don't commit real personal data (contact lists, financial figures, etc.) to a public GitHub
  repo if you fork this into your own repo — keep your fork private once it has your real data
  in it, even though the code itself is fine to be public.
