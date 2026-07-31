# Setup

Written as a literal runbook — exact links, exact steps, exact files to edit. If you're an AI
assistant (Claude Code or similar) running this on someone's behalf: follow these steps in
order, and at the end give them the live URL plus the two accounts (Supabase, Cloudflare) they
now own. Every account created below is free-tier and owned entirely by the person running
this, not by anyone else.

## 1. Get your own copy of this repo

If you're using the GitHub "Use this template" button on this repo, do that now and clone your
new repo locally. Otherwise:

```
git clone <this-repo-url> command-center
cd command-center
git remote remove origin
```

Then create a new (private is fine) repo under your own GitHub account and push this to it —
you'll connect Cloudflare Pages to this new repo in step 4.

## 2. Create a Supabase project

1. Go to https://supabase.com/dashboard → sign in (GitHub login is fastest) → **New project**.
2. Name it anything (e.g. `command-center`), pick any region, and let it generate/confirm a
   database password — you won't need this password again for anything in this setup, Supabase
   only uses it internally.
3. Wait ~2 minutes for provisioning.

## 3. Run the schema

1. In the new project, open **SQL Editor** (left sidebar) → **New query**.
2. Open `schema.sql` from this repo, copy its full contents, paste into the editor, click
   **Run**.
3. This creates all the tables (`projects`, `tasks`, `recurring_tasks`, `goals`, `metrics`,
   `list_items`, `activity_log`), the triggers, and permissive RLS policies. No seed data is
   inserted — you start empty.

## 4. Get your API credentials

1. In the Supabase project, go to **Settings → API**.
2. Copy the **Project URL** (looks like `https://xxxxx.supabase.co`).
3. Copy the **anon / public** key (a long string, NOT the `service_role` key — never use the
   service_role key in this file, it bypasses RLS entirely).

## 5. Connect the dashboard to Supabase

Open `dashboard.html` in this repo and find this block near the top of the `<script>` tag:

```js
const SUPABASE_URL = "YOUR_SUPABASE_URL_HERE";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY_HERE";

const USER_NAME = "there";
```

Replace the first two values with what you copied in step 4, and set `USER_NAME` to whatever
name you want in the greeting ("Good morning, *\<name\>*."). Save, commit, and push:

```
git add dashboard.html
git commit -m "Configure Supabase connection"
git push
```

## 6. Deploy to Cloudflare Pages

1. Go to https://dash.cloudflare.com → **Workers & Pages** (left sidebar, NOT "Domains" — this
   project won't have a custom domain) → **Create** → **Pages** → **Connect to Git**.
2. Authorize Cloudflare to access your GitHub account, pick the repo from step 1.
3. Build settings: **no build command needed**, output directory is `/` (repo root) — this is
   a static file, not a build. Deploy.
4. Once deployed, Cloudflare gives you a URL like `https://<project-name>.pages.dev`. The
   `_redirects` file already in this repo routes `/` to `/dashboard`, so that URL alone works.
5. Every future `git push` to this repo auto-deploys — no manual redeploy step ever again.

At this point you have a working, empty dashboard at your `.pages.dev` URL. Everything below
is optional.

## 7. (Optional) Enable the freeform quick-add bar

The text bar under the topbar that parses "work: run capture rates, by noon" into a real task
needs a Claude API key.

1. Get a key at https://console.anthropic.com/settings/keys (you'll need to add billing —
   costs are small; each quick-add call is one cheap Haiku request).
2. In the Cloudflare Pages project (from step 6) → **Settings → Variables and secrets** → add
   a secret named `ANTHROPIC_API_KEY` with that value. This key stays server-side — it's never
   sent to the browser.
3. Reload the dashboard; quick-add now works. If you skip this step, the rest of the dashboard
   is unaffected — quick-add will just show an error if someone tries to use it.

## 8. (Optional) Local development

To preview changes locally with the Function working (not just the static file):

```
npm install -g wrangler   # if you don't have it
npx wrangler pages dev . --port 8843
```

Create a `.dev.vars` file (already gitignored) with `ANTHROPIC_API_KEY=sk-...` if you want
quick-add to work locally too.

## 9. (Optional) Recurring tasks

`scripts/sync_recurring.py` generates/rolls-forward occurrences of anything you add to the
`recurring_tasks` table (weekly habits, monthly bills, yearly events — see `CLAUDE.md` for the
full field reference). It's not on a schedule by default — run it manually whenever, or set up
your own cron/scheduled task to run it periodically:

```
export SUPABASE_URL="https://xxxxx.supabase.co"
export SUPABASE_ANON_KEY="your anon key"
python3 scripts/sync_recurring.py
```

## 10. (Optional) Birthday reminders

`scripts/sync_birthdays.py` turns a CSV of contacts into recurring birthday reminder tasks.

1. Copy `data/birthdays.example.csv` to `data/birthdays.csv` (already gitignored — this file
   can contain real names/dates without ever being committed) and fill in your own contacts.
2. Find or create the `projects` row you want these reminders attached to, and copy its `id`
   (Supabase → Table Editor → `projects`, or query it via the REST API).
3. Run:

```
export SUPABASE_URL="https://xxxxx.supabase.co"
export SUPABASE_ANON_KEY="your anon key"
export PROJECT_ID="the project id from step 2"
python3 scripts/sync_birthdays.py
```

## You're done

Live URL: your `https://<project-name>.pages.dev` address from step 6. Bookmark it, add it to
your phone's home screen (the icons in `icons/` already cover Apple touch icon / favicons), and
start adding projects via the dashboard's own "+ Add project" card.
