#!/usr/bin/env python3
"""
sync_recurring.py
-----------------------
Generic recurrence engine for the Command Center. Reads every active row in
`recurring_tasks` and generates/rolls-forward its occurrences into `tasks`,
replacing what would otherwise be a bespoke script per recurring thing.

Frequencies:
    weekly  — occurs on `weekdays` (0=Sun..6=Sat) every week
    monthly — occurs on `day_of_month` (1-31), or the last day of the month
              if day_of_month = -1
    yearly  — occurs on `month`/`day` every year

Two occurrence styles, chosen per recurring_tasks row via `chained`:
    chained=true  — content-pipeline style (e.g. a recurring posting schedule).
                    Occurrences form one continuous blocked_by chain in order; only the
                    single next one is ever actionable. NOT hidden via
                    not_before by default — once unblocked it's fine to work
                    on early — unless the row's gate_not_before=true, in which
                    case not_before = due_date is applied on top of the chain
                    (e.g. a weekly posting schedule, so a post doesn't
                    surface in Next Up before its scheduled day even once the
                    prior post is done).
    chained=false — independent style (e.g. rent, Amex, birthdays). Each
                    occurrence gets not_before = due_date (the calendar-event
                    convention — see CLAUDE.md), so it stays out of Next Up
                    until its own due date, regardless of neighbors.

Every generated task's `notes` field is `recur:{recurring_task_id}:{date}`,
which is how this script recognizes what it already created (safe to rerun)
and how it detects recurring_tasks rows that were paused/deleted (their
non-done generated tasks get cleaned up).

Finite series: a row's `end_date` and/or `max_occurrences` (both optional,
default null = unbounded) cap how many occurrences ever get generated —
end_date caps by calendar date, max_occurrences caps by total count ever
created for that row. Once either cap is hit, sync_one() just stops
generating further occurrences for that row; nothing else happens (no flag,
no alert — it's a deliberate finite series). An unbounded row instead relies
on this script being run regularly (see the recur-sync-monthly scheduled
cloud agent noted in CLAUDE.md) so its lookahead window keeps moving forward
without a human needing to notice and rerun it manually.

Usage:
    python3 scripts/sync_recurring.py
    python3 scripts/sync_recurring.py --dry-run
"""

import os
import sys
from calendar import monthrange
from datetime import date, timedelta

import requests

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_ANON_KEY")

if not SUPABASE_URL or not SUPABASE_KEY:
    sys.exit("Set SUPABASE_URL and SUPABASE_ANON_KEY env vars first (see SETUP.md).")

HEADERS = {
    "apikey": SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
    "Content-Type": "application/json",
}


def fetch_active_recurring():
    r = requests.get(f"{SUPABASE_URL}/rest/v1/recurring_tasks", headers=HEADERS, params={"active": "eq.true"})
    r.raise_for_status()
    return r.json()


def fetch_all_recurring_ids():
    r = requests.get(f"{SUPABASE_URL}/rest/v1/recurring_tasks", headers=HEADERS, params={"select": "id,active"})
    r.raise_for_status()
    return r.json()


def fetch_existing_tasks(project_id):
    r = requests.get(
        f"{SUPABASE_URL}/rest/v1/tasks",
        headers=HEADERS,
        params={"project_id": f"eq.{project_id}", "notes": "like.recur:*", "select": "id,due_date,notes,status,blocked_by"},
    )
    r.raise_for_status()
    return {row["notes"]: row for row in r.json()}


def last_day_of_month(year, month):
    return monthrange(year, month)[1]


def occurrences_in_window(rt, start, end):
    """All dates in [start, end] on which this recurring_tasks row occurs."""
    dates = []
    if rt["frequency"] == "weekly":
        weekdays = set(rt["weekdays"] or [])
        d = start
        while d <= end:
            js_weekday = (d.weekday() + 1) % 7  # Python Mon=0..Sun=6 -> JS Sun=0..Sat=6
            if js_weekday in weekdays:
                dates.append(d)
            d += timedelta(days=1)
    elif rt["frequency"] == "monthly":
        y, m = start.year, start.month
        while date(y, m, 1) <= end:
            dom = rt["day_of_month"]
            day = last_day_of_month(y, m) if dom == -1 else min(dom, last_day_of_month(y, m))
            occ = date(y, m, day)
            if start <= occ <= end:
                dates.append(occ)
            m += 1
            if m > 12:
                m, y = 1, y + 1
    elif rt["frequency"] == "yearly":
        for y in range(start.year, end.year + 1):
            try:
                occ = date(y, rt["month"], rt["day"])
            except ValueError:
                occ = date(y, 3, 1)  # Feb 29 fallback
            if start <= occ <= end:
                dates.append(occ)
    return sorted(dates)


def js_weekday_name(d):
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(d.weekday() + 1) % 7]


def insert_task(payload, dry_run):
    if dry_run:
        print(f"    + INSERT {payload['description']} due {payload['due_date']} blocked_by={payload.get('blocked_by')}")
        return "DRYRUN-ID"
    r = requests.post(f"{SUPABASE_URL}/rest/v1/tasks", headers={**HEADERS, "Prefer": "return=representation"}, json=payload)
    r.raise_for_status()
    return r.json()[0]["id"]


def delete_task(task_id, dry_run):
    if dry_run:
        print(f"    - DELETE {task_id}")
        return
    r = requests.delete(f"{SUPABASE_URL}/rest/v1/tasks", headers=HEADERS, params={"id": f"eq.{task_id}"})
    r.raise_for_status()


def sync_one(rt, today, dry_run):
    label = rt["description"]
    print(f"  [{rt['frequency']}] {label}")
    existing = fetch_existing_tasks(rt["project_id"])
    mine_keys = {k for k in existing if k.startswith(f"recur:{rt['id']}:")}
    generated_so_far = len(mine_keys)

    window_end = today + timedelta(days=rt["lookahead_days"])
    if rt.get("end_date"):
        window_end = min(window_end, date.fromisoformat(rt["end_date"]))
    occurrences = occurrences_in_window(rt, today, window_end)

    n_insert = n_skip = n_capped = 0
    prev_task_id = None
    # for chained rows, find the tail of the existing chain to link onward from
    if rt["chained"]:
        mine = [row for key, row in existing.items() if key in mine_keys]
        if mine:
            prev_task_id = max(mine, key=lambda r: r["due_date"])["id"]

    max_occ = rt.get("max_occurrences")

    for occ in occurrences:
        key = f"recur:{rt['id']}:{occ.isoformat()}"
        if key in existing:
            if rt["chained"]:
                prev_task_id = existing[key]["id"]
            n_skip += 1
            continue
        if max_occ is not None and generated_so_far >= max_occ:
            n_capped += 1
            continue
        desc = f"{label} ({js_weekday_name(occ)} {occ.month}/{occ.day})" if rt["frequency"] == "weekly" else label + f" ({occ.isoformat()})"
        payload = {
            "project_id": rt["project_id"],
            "description": desc,
            "due_date": occ.isoformat(),
            "due_time": rt["due_time"],
            "priority": rt["priority"],
            "notes": key,
        }
        if rt["chained"]:
            payload["blocked_by"] = prev_task_id
            if rt.get("gate_not_before"):
                payload["not_before"] = occ.isoformat()
        else:
            payload["not_before"] = occ.isoformat()
        new_id = insert_task(payload, dry_run)
        if rt["chained"]:
            prev_task_id = new_id
        n_insert += 1
        generated_so_far += 1

    # clean up tasks for occurrences no longer in window (shouldn't normally happen
    # since we only ever extend forward, but covers a shortened lookahead_days)
    valid_keys = {f"recur:{rt['id']}:{o.isoformat()}" for o in occurrences}
    n_delete = 0
    for key, row in existing.items():
        if key.startswith(f"recur:{rt['id']}:") and key not in valid_keys and row["status"] != "done":
            delete_task(row["id"], dry_run)
            n_delete += 1

    capped_note = f"  capped: {n_capped}" if n_capped else ""
    print(f"    insert: {n_insert}  unchanged: {n_skip}  delete: {n_delete}{capped_note}")


def cleanup_orphaned(dry_run):
    """Delete non-done generated tasks whose recurring_tasks row was paused or deleted."""
    all_ids = {row["id"] for row in fetch_all_recurring_ids() if row["active"]}
    r = requests.get(
        f"{SUPABASE_URL}/rest/v1/tasks",
        headers=HEADERS,
        params={"notes": "like.recur:*", "select": "id,notes,status"},
    )
    r.raise_for_status()
    n = 0
    for row in r.json():
        rt_id = row["notes"].split(":")[1]
        if rt_id not in all_ids and row["status"] != "done":
            delete_task(row["id"], dry_run)
            n += 1
    if n:
        print(f"  cleaned up {n} tasks from paused/deleted recurring_tasks rows")


def main():
    dry_run = "--dry-run" in sys.argv
    today = date.today()

    recurring = fetch_active_recurring()
    print(f"{len(recurring)} active recurring_tasks rows")
    for rt in recurring:
        sync_one(rt, today, dry_run)

    cleanup_orphaned(dry_run)
    print("Dry run — nothing written." if dry_run else "Sync complete.")


if __name__ == "__main__":
    main()
