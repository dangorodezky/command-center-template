#!/usr/bin/env python3
"""
sync_birthdays.py
-----------------------
Syncs data/birthdays.csv into the shared Command Center tracker (Supabase) as
`tasks` rows in the Life project: one reminder per person, due on their next
upcoming birthday. Safe to rerun any time — idempotent (matches on a stable
key in `tasks.notes`), and rolls each reminder forward to next year once its
date has passed (whether or not it was marked done).

Calendar-event convention: `not_before` is always set equal to `due_date`, so
a birthday reminder never clutters Next Up — it only appears, once, in
Today's Checklist on the actual day. See CLAUDE.md's Conventions section.

If a birth year is known (not blank in the CSV), the description includes
the age they're turning.

Setup: copy data/birthdays.example.csv to data/birthdays.csv (gitignored) and
fill in your own contacts — name, month, day, optional birth year.

Usage:
    SUPABASE_URL=... SUPABASE_ANON_KEY=... PROJECT_ID=... python3 scripts/sync_birthdays.py
    python3 scripts/sync_birthdays.py --dry-run
"""

import csv
import os
import re
import sys
from datetime import date

import requests

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_ANON_KEY")
PROJECT_ID = os.environ.get("PROJECT_ID")  # the project these reminders belong to, e.g. a "Life" project
BIRTHDAYS_CSV = "data/birthdays.csv"

if not SUPABASE_URL or not SUPABASE_KEY or not PROJECT_ID:
    sys.exit("Set SUPABASE_URL, SUPABASE_ANON_KEY, and PROJECT_ID env vars first (see SETUP.md).")

HEADERS = {
    "apikey": SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
    "Content-Type": "application/json",
}


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def load_people():
    people = []
    with open(BIRTHDAYS_CSV, newline="") as f:
        for row in csv.DictReader(f):
            month, day = int(row["month"]), int(row["day"])
            year = int(row["year"]) if row["year"].strip() else None
            people.append({"name": row["name"].strip(), "month": month, "day": day, "year": year})
    return people


def next_occurrence(month, day, today):
    try:
        this_year = date(today.year, month, day)
    except ValueError:
        this_year = date(today.year, 3, 1)  # Feb 29 fallback in non-leap years
    if this_year >= today:
        return this_year
    try:
        return date(today.year + 1, month, day)
    except ValueError:
        return date(today.year + 1, 3, 1)


def fetch_existing():
    resp = requests.get(
        f"{SUPABASE_URL}/rest/v1/tasks",
        headers=HEADERS,
        params={
            "project_id": f"eq.{PROJECT_ID}",
            "notes": "like.bday:*",
            "select": "id,description,due_date,not_before,notes,status",
        },
    )
    resp.raise_for_status()
    return {row["notes"]: row for row in resp.json()}


def insert_task(payload, dry_run):
    if dry_run:
        print(f"  + INSERT {payload['description']} due {payload['due_date']}")
        return
    r = requests.post(f"{SUPABASE_URL}/rest/v1/tasks", headers=HEADERS, json=payload)
    r.raise_for_status()


def update_task(task_id, fields, dry_run):
    if dry_run:
        print(f"  ~ UPDATE {task_id} -> {fields}")
        return
    r = requests.patch(f"{SUPABASE_URL}/rest/v1/tasks", headers=HEADERS, params={"id": f"eq.{task_id}"}, json=fields)
    r.raise_for_status()


def delete_task(task_id, description, dry_run):
    if dry_run:
        print(f"  - DELETE {task_id} ({description})")
        return
    r = requests.delete(f"{SUPABASE_URL}/rest/v1/tasks", headers=HEADERS, params={"id": f"eq.{task_id}"})
    r.raise_for_status()


def main():
    dry_run = "--dry-run" in sys.argv
    today = date.today()

    people = load_people()
    existing = fetch_existing()
    valid_keys = {f"bday:{slug(p['name'])}" for p in people}

    to_delete = [
        (row["id"], row["description"])
        for key, row in existing.items()
        if key not in valid_keys and row["status"] != "done"
    ]
    for tid, desc in to_delete:
        delete_task(tid, desc, dry_run)

    n_insert = n_update = n_skip = 0
    for p in people:
        key = f"bday:{slug(p['name'])}"
        occurrence = next_occurrence(p["month"], p["day"], today)
        due_str = occurrence.isoformat()
        desc = f"{p['name']}'s birthday"
        if p["year"]:
            desc += f" (turns {occurrence.year - p['year']})"

        if key in existing:
            row = existing[key]
            needs_rollover = row["due_date"] < due_str or row["status"] == "done"
            if needs_rollover:
                update_task(row["id"], {"description": desc, "due_date": due_str, "not_before": due_str, "status": "open"}, dry_run)
                n_update += 1
            else:
                n_skip += 1
        else:
            insert_task(
                {
                    "project_id": PROJECT_ID,
                    "description": desc,
                    "due_date": due_str,
                    "not_before": due_str,
                    "priority": 3,
                    "notes": key,
                },
                dry_run,
            )
            n_insert += 1

    print(f"{len(people)} people -> insert: {n_insert}  update/rollover: {n_update}  unchanged: {n_skip}  delete (removed): {len(to_delete)}")
    print("Dry run — nothing written." if dry_run else "Sync complete.")


if __name__ == "__main__":
    main()
