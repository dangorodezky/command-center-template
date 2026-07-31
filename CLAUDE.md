# Command Center

A single personal tracker across whatever projects you're juggling, with a "Priority Stack"
that surfaces the most urgent open item across all of them. See `README.md` for the stack
overview and `SETUP.md` for initial setup. This file documents the schema conventions and
code patterns worth knowing before extending `dashboard.html` — read it before making
structural changes.

## Stack

- **Data:** Supabase (Postgres), schema in `schema.sql`. RLS is "allow all" — fine for a
  single-user personal instance, not multi-tenant. See the security note in `README.md`.
- **Frontend:** `dashboard.html` — single static file, no build step, no framework. Talks to
  Supabase directly via `supabase-js` (CDN).
- **Hosting:** Cloudflare Pages. Push to `main`, it auto-deploys. `_redirects` routes `/` to
  `/dashboard` since the source file is `dashboard.html`, not `index.html`.
- **Optional backend:** `functions/parse-task.js`, a Cloudflare Pages Function backing the
  freeform quick-add bar. Calls the Claude API server-side using a Cloudflare secret
  (`ANTHROPIC_API_KEY`) — never shipped to the browser.
- **Local preview:** `npx wrangler pages dev . --port 8843` — serves the static file and runs
  the Pages Function locally, matching production. Opening `dashboard.html` directly via
  `file://` also works for quick manual checks that don't touch quick-add.

## Conventions

- `priority`: 1 (highest) .. 5 (lowest), used on both `projects` and `tasks`.
  - **Projects** — *"how much of my attention does this deserve right now?"*
    `1` committed with a closing window (hard external date, real cost if missed) ·
    `2` active push (what I'm deliberately trying to move) ·
    `3` steady state (real and maintained) ·
    `4` held option (deliberately alive, not being pushed) ·
    `5` parked.
  - **Tasks** — *"if I never do this, what breaks?"*
    `1` today (overdue, due today, or a closing external window) ·
    `2` this week (time-sensitive, or unblocks a p1/p2 project) ·
    `3` this month (real progress, no external clock) ·
    `4` whenever (no goal linkage, low cost of never doing it) ·
    `5` someday.
  - The discipline that makes this work: **p1 must be earned by a date, not by enthusiasm.**
    If everything important is p1, the field is decoration again.
- `estimate_minutes` (int, optional, on `tasks`): rough effort in minutes, for ranking tasks by
  "does this fit the time I have" rather than priority alone. Use round buckets (15/30/60/
  120/240) — it's for bucketing, not scheduling. Null means *unestimated*, never zero.
- `detail` (text, optional, on both `projects` and `tasks`) vs. the short summary field
  (`description` on tasks, `notes` on projects): **the short field is what the thing IS,
  `detail` is everything else** — why it matters, rationale, sub-steps, links, numbers,
  exact addresses, "not X but Y" reasoning. The short field should read as a tight verb-phrase
  or 1-3 line summary, no embedded sentences or " — " asides. If it needs a semicolon, an em
  dash, or a parenthetical longer than 2-3 words, that content belongs in `detail` instead.
  - **Bad:** `"Batch-produce the ~28 missing player cutouts (7 of 35 done today - this is THE
    bottleneck). Source photos, remove backgrounds, add as Smart Objects."`
  - **Good:** `description: "Batch-produce missing player cutouts"`, `detail: "~28 missing;
    7 of 35 done today, this is THE bottleneck. Source photos, remove backgrounds, add as
    Smart Objects."`
  - `tasks.notes` is a **separate field**, internal/machine use only (the
    `recur:{recurring_task_id}:{date}` idempotency key `scripts/sync_recurring.py` writes) —
    never a place for human text.
- `status` on tasks: `open` | `doing` | `blocked` | `done`. `status='blocked'` means
  *externally stuck, needs attention now* — boosted to the top of the Priority Stack. This is
  distinct from the two gating fields below, which mean *not actionable yet* and are hidden
  from the stack instead:
  - `blocked_by` (uuid, self-referential): this task can't start until another task is `done`.
    Set once at creation, never mutated — "is it unblocked" is a live read of the referenced
    task's status. One parent only (no multi-task dependencies).
  - `not_before` (date): can be created and given a `due_date` far in advance, but shouldn't
    surface until a calendar date arrives (e.g. "reservations open Aug 5," logged months
    ahead). Self-resolving — the dashboard just compares against today at render time.
  - See `gateFor()` in `dashboard.html` — checks `blocked_by` first, then `not_before`.
  - **If a task turns out to have no real external blocker of its own, don't leave it
    self-flagged `status='blocked'` with nothing backing the claim** — check whether it should
    instead be `blocked_by` another task or gated with `not_before`.
- `is_event` (boolean, default false, on `tasks`): marks a calendar event — something that
  happens at a fixed time and is attended/observed (an appointment, a reservation, a wedding)
  — as opposed to an ordinary task (book something, write something, decide something). A
  check constraint enforces `due_date is not null` whenever `is_event` is true. Kept out of
  Next Up (it isn't a to-do); still shown in Today's Checklist on its actual due date; surfaced
  ahead of time via the Calendar Look-ahead section (30-day fixed window, see
  `calendarLookahead()`).
- `due_time` (time, optional): time-of-day for `due_date`. Sort tiebreaker after `due_date`.
- `status` on projects: `active` | `paused` | `done`. An `active` project renders with no
  status badge (the default/expected state); only `paused`/`done` show a pill and dim the card.
- `parent_id` on projects (uuid, self-referential, optional): one level of nesting for
  sub-projects under a shared parent project. Not used by default.
- `is_default` on projects (boolean): marks the one project new tasks fall back to when
  nothing else fits. Toggle it via a checkbox in the project edit modal
  (`renderProjectEditForm()`/`saveProjectEdit()` in `dashboard.html`) — checking it clears the
  flag from every other project first, since only one project can hold it (also enforced by a
  partial unique index in `schema.sql`). Two consumers: the freeform quick-add parser
  (`functions/parse-task.js`) assigns the default project's id when the model can't confidently
  pick one, and the blank "New task" modal pre-selects it instead of leaving the picker unset.
  No project is marked default out of the box — set it on whichever project should be the
  catch-all once you've created one.
- `completed_at` (timestamptz, on both tables): auto-set/cleared by a Postgres trigger when
  `status` transitions to/from `'done'`. Never write to this column directly — just change
  `status`.
- `goals` table: standalone from `projects`/`tasks`. Optional `project_id` links a goal to a
  project's context (null for standalone goals). Optional `target_value`/`current_value`/
  `unit` (leave all three null for abstract goals — the dashboard only renders a progress bar
  when `target_value` is set). `current_value` is manual — nothing updates it automatically.
  - **Decomposing abstract goals:** a vague goal ("get better at X") should get a small
    dedicated project as soon as it needs concrete next actions — link the goal to that
    project via `goals.project_id`, and ordinary `tasks` rows under it become the action items.
- `list_items` table: low-priority reference lists (a buy list, a watch list) — `list_name`
  (free text) distinguishes lists, no schema change needed for a new one. `priority` here is
  pure manual ordering (drag-to-reorder rewrites it sequentially), not a 1-5 urgency signal
  like on `projects`/`tasks`.
- `metrics` table: append-only time series — `metric_name`, `value`, `unit`, `recorded_at`.
  One row per observation.

## Recurring tasks (`recurring_tasks` + `scripts/sync_recurring.py`)

One row per recurring thing. The script generates/rolls-forward occurrences into `tasks`.
Every generated task's `notes` is `recur:{recurring_task_id}:{date}` — the idempotency key,
and how the script detects a paused/deleted `recurring_tasks` row (cleans up its non-`done`
generated tasks).

**`chained` decides the gating mechanism:**
- `chained=true`: content-pipeline style (e.g. a recurring posting schedule). Occurrences form
  one `blocked_by` chain in order; only the single next one is ever actionable. No `not_before`
  by default — once unblocked it's fine to work on early.
- `chained=false`: independent style (habits, bills — anything where a missed occurrence
  shouldn't hide the next one). Each occurrence gets `not_before = due_date`, invisible until
  its own due date regardless of neighbors.

`frequency` rule fields: `weekly` uses `weekdays` (JS convention, 0=Sun..6=Sat); `monthly` uses
`day_of_month` (1-31, or -1 for "last day of the month"); `yearly` uses `month` + `day`.

The sync script isn't on any scheduler by default — run it manually, or wire up your own cron/
scheduled task. `end_date`/`max_occurrences` (both optional) cap a row to a finite series
instead of running forever.

The Habits section (`renderHabits()` in `dashboard.html`) groups every independent weekly
`recurring_tasks` row into one progress ring per `project_id` — e.g. several gym-day habits
under one "Fitness" project automatically roll up into a single Fitness ring. No separate
config needed: a new habit just needs the right `project_id` and it joins (or starts) that
project's ring on its own.

## Code patterns worth knowing

- **`render()` replaces `#app`'s `innerHTML` on every call**, including every 60s data
  refresh. Any event listener attached to a node inside `#app` at page-load time (outside
  `render()`) goes dead the next time `render()` runs, silently — no console error, the
  listener just never fires again. Attach such listeners *inside* `render()` itself (see
  `initDragReorder()` for the pattern), not once at boot.
- **`jsArg()`/`escapeAttr()`** (near `expandedLists` in `dashboard.html`): use these whenever
  splicing free-text (not a uuid) into an inline `onclick="..."` handler or a `data-*`
  attribute. `JSON.stringify` produces a correctly-escaped JS string literal; `escapeAttr`
  HTML-escapes that for the surrounding double-quoted attribute. Don't interpolate free text
  raw into a template literal even if it looks safe in a quick test.
- **Editing happens in a centered modal, not inline.** `editingTaskId`/`editingProjectId`/
  `openTasksProjectId` (module-level) are checked in priority order by `renderModal()`.
  `closeModal()` clears all modal state variables at once.
- **Checking a task off** (`toggleTicketDone()`) mutates the local `tasks` array directly and
  re-renders, rather than triggering a full reload — `justCompleted` (a session-only Set) keeps
  the row visible (grayed, struck through) instead of yanking it out of view immediately.

## Adding a new recurring habit/bill/event

1. Insert a row into `recurring_tasks` with the right `frequency` fields and `chained` value
   (see above).
2. Run `scripts/sync_recurring.py` to generate the first occurrences.
3. If it's a habit you want a progress ring for, just make sure it has a `project_id` set — it
   automatically joins that project's Habits ring (see above), grouped with any other
   independent weekly habits already on that project.
