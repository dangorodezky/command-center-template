-- ============================================================
-- Command Center schema
-- Run this in Supabase: Project → SQL Editor → New Query → paste → Run
-- ============================================================

create extension if not exists "pgcrypto";

create table if not exists projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null default 'business',   -- 'business' | 'personal'
  color text not null default '#4C8BF5',        -- hex accent used as the project's tab color
  status text not null default 'active',        -- 'active' | 'paused' | 'done'
  priority int not null default 3,               -- 1 (highest) .. 5 (lowest)
  next_deadline date,
  blocker text,                                  -- free text; null/empty = no current blocker
  notes text,
    -- short ~1-3 line on-card summary — rendered on the project card (clamped via CSS).
    -- Real detail, history, and links belong in `detail` instead, same split as
    -- tasks.description/detail. See the `detail` column below.
  detail text,
    -- optional freeform long-form text, never shown on the card itself — only in the
    -- project edit modal. Added 2026-07-30 once several projects' `notes` had grown into
    -- full paragraphs, which broke the "equal footprint, scan at a glance" card design.
  parent_id uuid references projects(id) on delete set null,
    -- optional: another row in this table that this project is a sub-project of
    -- (e.g. sub-projects under a shared parent). Null for
    -- top-level projects. One level of nesting only — sufficient for every case
    -- so far, same reasoning as tasks.blocked_by.
  completed_at timestamptz,   -- auto-set/cleared by trg_*_completed_at when status changes to/from 'done'
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  description text not null,
    -- Keep this SHORT — a verb-phrase, ideally 4-6 words, well under 10. No embedded
    -- sentences, " — " asides, or parentheticals longer than 2-3 words. Rationale,
    -- numbers, addresses, links, and "not X but Y" reasoning belong in `detail`
    -- instead, even if `detail` ends up much longer than this field. See the `detail`
    -- writing rule below and the CLAUDE.md "Writing rule" convention for worked examples.
  status text not null default 'open',           -- 'open' | 'doing' | 'blocked' | 'done'
  priority int not null default 3,               -- 1 (highest) .. 5 (lowest)
  due_date date,
  due_time time,   -- optional time-of-day for due_date, e.g. an event at 4pm
  notes text,
    -- internal/machine use only — e.g. recur:{recurring_task_id}:{date}, the idempotency key
    -- sync_recurring.py writes on every generated occurrence (see CLAUDE.md). Not shown in the
    -- UI and not a place for freeform human notes — that's `detail`, below.
  detail text,
    -- optional freeform long-form text a human can add when editing a task — meant for real
    -- detail (context, links, a checklist) that doesn't belong in `description`, which stays a
    -- short summary. Hidden on task rows; only shown/editable in the task edit modal. Added
    -- Null means no detail, never an empty string.
  blocked_by uuid references tasks(id) on delete set null,
    -- optional: another task in this table that must be 'done' before this one
    -- is actionable. Structural gating (e.g. "can't write next preview until
    -- previous recap is done") — distinct from status='blocked', which means
    -- "externally stuck, needs attention now". The dashboard hides tasks with
    -- an unresolved blocked_by from the Priority Stack until it clears.
  not_before date,
    -- optional: a date before which this task isn't relevant yet, even though
    -- it can be created (and given a due_date) far in advance. E.g. "reservations
    -- open Aug 5" can be logged today with not_before=2026-08-05 and stays out
    -- of the way until that date arrives — no dependency on another task, just
    -- a calendar trigger. Self-resolving: nothing needs to update this row when
    -- the date passes, the dashboard just compares against today at render time.
  estimate_minutes int,
    -- optional: rough effort estimate in minutes. Exists so a task can be ranked
    -- by "does this fit in the time I actually have right now" rather than by
    -- priority alone — a 5-minute email and a 6-hour build otherwise sort
    -- identically. Deliberately coarse: use round numbers (15/30/60/120/240),
    -- it's for bucketing, not for scheduling. Null = unestimated, which the
    -- dashboard must treat as "unknown", never as zero.
  completed_at timestamptz,   -- auto-set/cleared by trg_*_completed_at when status changes to/from 'done'
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists recurring_tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  description text not null,
  frequency text not null,        -- 'weekly' | 'monthly' | 'yearly'
  weekdays int[],                 -- weekly: days of week, 0=Sun..6=Sat (JS Date.getDay() convention)
  day_of_month int,               -- monthly: 1-31, or -1 meaning "last day of the month"
  month int,                      -- yearly: 1-12
  day int,                        -- yearly: 1-31
  due_time time,
  chained boolean not null default false,
    -- true: each occurrence is blocked_by the previous one (content-pipeline style,
    --   e.g. a recurring content posting schedule) -- only the single next occurrence is ever actionable,
    --   and it's NOT hidden via not_before (once unblocked, it's fine to work on early).
    -- false: occurrences are independent (bill/appointment style, e.g. rent, birthdays)
    --   and use not_before = due_date instead, so each stays out of Next Up until its
    --   own due date, regardless of whether the previous occurrence was completed.
  lookahead_days int not null default 60,  -- how far ahead to generate occurrences
  priority int not null default 3,
  active boolean not null default true,   -- set false to pause without losing history
  created_at timestamptz not null default now()
);

create table if not exists goals (
  id uuid primary key default gen_random_uuid(),
  description text not null,
  project_id uuid references projects(id) on delete set null,
    -- optional: links this goal to a project (e.g. a social-media follower-count
    -- goal). Null for standalone/abstract goals ("get better at golf").
  target_value numeric,
  current_value numeric,
    -- optional pair, for measurable goals only (e.g. target=5000, current=3200
    -- followers). Leave both null for abstract goals — the dashboard renders a
    -- progress bar only when target_value is set.
  unit text,             -- e.g. 'followers', 'lbs' — display label alongside the values
  target_date date,
  status text not null default 'active',   -- 'active' | 'done' | 'abandoned'
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists metrics (
  id uuid primary key default gen_random_uuid(),
  metric_name text not null,   -- e.g. 'weight', 'net_worth', 'claude_usage_weekly'
  value numeric not null,
  unit text,                  -- e.g. 'lbs', 'usd', 'percent'
  recorded_at timestamptz not null default now()
    -- one row per observation (time series) — no update/delete pattern, just
    -- append new readings. Latest row per metric_name is "current"; older rows
    -- are history for a trend. Age isn't stored here — it's derived from a
    -- hardcoded birthdate constant in dashboard.html.
);

create table if not exists activity_log (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references projects(id) on delete cascade,
  entry text not null,
  created_at timestamptz not null default now()
);

-- Keep updated_at fresh automatically
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_projects_updated_at on projects;
create trigger trg_projects_updated_at before update on projects
  for each row execute function set_updated_at();

drop trigger if exists trg_tasks_updated_at on tasks;
create trigger trg_tasks_updated_at before update on tasks
  for each row execute function set_updated_at();

drop trigger if exists trg_goals_updated_at on goals;
create trigger trg_goals_updated_at before update on goals
  for each row execute function set_updated_at();

-- Log when a row's status transitions to/from 'done', on both projects and tasks
create or replace function set_completed_at()
returns trigger as $$
begin
  if new.status = 'done' and (old.status is distinct from 'done') then
    new.completed_at = now();
  elsif new.status is distinct from 'done' then
    new.completed_at = null;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_projects_completed_at on projects;
create trigger trg_projects_completed_at before update on projects
  for each row execute function set_completed_at();

drop trigger if exists trg_tasks_completed_at on tasks;
create trigger trg_tasks_completed_at before update on tasks
  for each row execute function set_completed_at();

-- ============================================================
-- Migration: blocked_by column (run once if `tasks` already existed
-- before this column was added — `create table if not exists` above
-- won't add columns to an existing table)
-- ============================================================
alter table tasks add column if not exists blocked_by uuid references tasks(id) on delete set null;
alter table tasks add column if not exists not_before date;
alter table tasks add column if not exists due_time time;
alter table tasks add column if not exists completed_at timestamptz;
alter table projects add column if not exists completed_at timestamptz;
alter table projects add column if not exists parent_id uuid references projects(id) on delete set null;

-- ============================================================
-- Migration: recurring_tasks table (run once if it didn't already exist)
-- ============================================================
create table if not exists recurring_tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id) on delete cascade,
  description text not null,
  frequency text not null,
  weekdays int[],
  day_of_month int,
  month int,
  day int,
  due_time time,
  chained boolean not null default false,
  lookahead_days int not null default 60,
  priority int not null default 3,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ============================================================
-- Migration: goals table (run once if it didn't already exist)
-- ============================================================
create table if not exists goals (
  id uuid primary key default gen_random_uuid(),
  description text not null,
  project_id uuid references projects(id) on delete set null,
  target_value numeric,
  current_value numeric,
  unit text,
  target_date date,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- Migration: metrics table (run once if it didn't already exist)
-- ============================================================
create table if not exists metrics (
  id uuid primary key default gen_random_uuid(),
  metric_name text not null,
  value numeric not null,
  unit text,
  recorded_at timestamptz not null default now()
);

-- ============================================================
-- Migration: list_items table (run once if it didn't already exist)
-- Generic low-priority reference lists (want-to-buy, watch list, etc.) —
-- list_name distinguishes them so a new list needs no schema change.
-- ============================================================
create table if not exists list_items (
  id uuid primary key default gen_random_uuid(),
  list_name text not null,               -- 'buy' | 'watch' | ... free text
  title text not null,
  notes text,                             -- price, edition, why, etc.
  status text not null default 'open',    -- 'open' | 'done'
  priority int not null default 3,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- Row Level Security
-- This is a single-user personal tool, so we allow the anon key
-- full read/write access. Do NOT reuse this anon key for anything
-- multi-user — it has no per-row access control.
-- ============================================================
alter table projects enable row level security;
alter table tasks enable row level security;
alter table activity_log enable row level security;
alter table recurring_tasks enable row level security;
alter table goals enable row level security;
alter table metrics enable row level security;
alter table list_items enable row level security;

drop policy if exists "allow all - projects" on projects;
create policy "allow all - projects" on projects for all using (true) with check (true);

drop policy if exists "allow all - tasks" on tasks;
create policy "allow all - tasks" on tasks for all using (true) with check (true);

drop policy if exists "allow all - activity_log" on activity_log;
create policy "allow all - activity_log" on activity_log for all using (true) with check (true);

drop policy if exists "allow all - recurring_tasks" on recurring_tasks;
create policy "allow all - recurring_tasks" on recurring_tasks for all using (true) with check (true);

drop policy if exists "allow all - goals" on goals;
create policy "allow all - goals" on goals for all using (true) with check (true);

drop policy if exists "allow all - list_items" on list_items;
create policy "allow all - list_items" on list_items for all using (true) with check (true);

drop policy if exists "allow all - metrics" on metrics;
create policy "allow all - metrics" on metrics for all using (true) with check (true);

-- ============================================================
-- Migration: recurring_tasks.gate_not_before (run once if it didn't already exist)
-- ============================================================
alter table recurring_tasks add column if not exists gate_not_before boolean not null default false;
-- For chained=true rows only: normally a chained occurrence has no not_before (once
-- unblocked via the previous occurrence's blocked_by, it's fine to work on early — see the
-- chained comment above). Setting gate_not_before=true overrides that for a specific chain,
-- also applying not_before = due_date so the occurrence stays out of Next Up until its own
-- due date even once unblocked. Useful for a recurring content chain (e.g. a weekly posting schedule)
-- No effect on chained=false rows (they already always get not_before = due_date).

-- ============================================================
-- Migration: recurring_tasks.end_date / max_occurrences (run once if they
-- didn't already exist)
-- ============================================================
alter table recurring_tasks add column if not exists end_date date;
alter table recurring_tasks add column if not exists max_occurrences int;
-- Both optional and independent — a row can set either, both, or neither:
--   end_date: stop generating occurrences with due dates past this date.
--   max_occurrences: stop once this many total occurrences have ever been
--     generated for this row (counted across all time, not just the current
--     lookahead window — sync_recurring.py counts existing recur:{id}:* tasks
--     to determine how many remain).
-- Both null (the default) means the series has no defined end — it recurs
-- forever, kept topped up by the recur-sync-monthly scheduled cloud agent
-- (see CLAUDE.md) rather than requiring a human to notice and rerun the
-- generator. Added 2026-07-28 so finite series (e.g. a 6-week challenge) can
-- be expressed directly instead of just letting lookahead_days quietly stop
-- being extended.

-- ============================================================
-- Migration: tasks.detail (run once if it didn't already exist)
-- ============================================================
alter table tasks add column if not exists detail text;
-- Freeform long-form note field, distinct from the existing `notes` column
-- (which is internal/machine use — the recurring-task idempotency key, see
-- above) and from `description` (a short summary). Added 2026-07-29 so a
-- task can carry real detail — context, links, a checklist — without
-- bloating the one-line description shown everywhere else. Hidden by
-- default in the UI, shown/editable only in the task edit modal.
--
-- Writing rule: `description` is what the task IS; `detail` is everything
-- else (why it matters, sub-steps, links, exact numbers/addresses, "not X
-- but Y" reasoning). If writing a `description` requires a semicolon, an
-- em dash, or a parenthetical longer than 2-3 words to make sense, that
-- content belongs in `detail` instead — even if `detail` ends up much
-- longer than `description`. Example:
--   bad:  description = "Renew driver's license (DMV online - CA typically
--         opens online renewal ~60 days before expiration, confirm exact
--         window via DMV notice/account)"
--   good: description = "Renew driver's license"
--         detail = "DMV online — CA typically opens online renewal ~60
--         days before expiration; confirm exact window via DMV
--         notice/account."
-- A short parenthetical that disambiguates *which* item this is (not why
-- it matters) is fine to leave in description, e.g. "Book rental car, El
-- Calafate (Jan 10-14)". See CLAUDE.md's `detail` convention entry for
-- more worked examples and the 2026-07-29 cleanup pass that applied this
-- retroactively to ~25 pre-existing tasks.

-- ============================================================
-- Migration: tasks.is_event (run once if it didn't already exist)
-- ============================================================
alter table tasks add column if not exists is_event boolean not null default false;
alter table tasks drop constraint if exists tasks_event_requires_due_date;
alter table tasks add constraint tasks_event_requires_due_date check (not is_event or due_date is not null);
-- Distinguishes a calendar event (something that happens at a fixed time —
-- a game, an appointment, a dinner reservation — you attend/observe rather
-- than a to-do you complete ahead of time) from an ordinary task. Added
-- 2026-07-29. No relational/anchor column: a task created "N days before
-- project X's deadline" just gets its due_date computed once at creation
-- time (see the "Compute date" helper in dashboard.html) and stored as a
-- plain date — if the anchor date later changes, this due_date does NOT
-- follow it. The check constraint enforces that an event always has a real
-- due_date (never null) since the whole point is a fixed date/time.
--   - Kept OUT of Next Up (dashboard.html's renderStacks() filters
--     is_event out of nextUpAll) since it's not an actionable to-do.
--   - Still shown in Today's Checklist on its actual due date, same as any
--     other task — an event happening today shouldn't be invisible today.
--   - Surfaced ahead of time in the dedicated "Calendar Look-ahead" section
--     instead (dashboard.html's calendarLookahead()): shows every upcoming
--     event within a fixed 30-day window (LOOKAHEAD_MAX_DAYS).
-- Recurring-generated content (Instagram posts, match previews/recaps) and
-- birthdays are deliberately NOT events — they stay ordinary tasks (an
-- action you take: post it, write it, text someone), even though they're
-- also date-driven and already used the not_before=due_date convention.

-- ============================================================
-- Migration: projects.detail (run once if it didn't already exist)
-- ============================================================
alter table projects add column if not exists detail text;
-- Same idea as tasks.detail (added 2026-07-30): `notes` stays a short
-- ~1-3 line on-card summary (rendered on the project card, clamped via
-- CSS), while `detail` is the long-form overflow — full context, history,
-- links — shown only in the project edit modal, never on the card itself.
-- Added because several projects' `notes` had grown into full paragraphs
-- (seen in practice with long-running projects), which broke the "equal
-- footprint, scan at a glance" design the Projects section redesign was
-- built around (see CLAUDE.md's Projects section redesign entry) — rather
-- than re-clamping harder and losing content, the overflow moves to
-- `detail` instead. Same writing rule as tasks.detail: `notes` is the
-- short status/identity summary, `detail` is everything else.

-- ============================================================
-- Seed data — none by default. The dashboard's "+ Add project" card
-- handles creating your first project once it's connected. Uncomment
-- and edit this to seed one from SQL instead, e.g.:
--
-- insert into projects (name, category, color, status, priority, next_deadline, blocker) values
--   ('My First Project', 'personal', '#4C8BF5', 'active', 3, null, null)
-- on conflict do nothing;
