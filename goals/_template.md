<!--
Template for a goal-strategy file. Use this for any goal that needs more than a
one-line description + optional number in Supabase — real strategy, contacts,
research, or a progress log worth keeping around.

How this links to Command Center:
- The goal still gets a normal row in Supabase `goals` (project_id, description,
  optional target_value/current_value/unit/target_date, status).
- Reference this file in that row's `description` text, e.g.:
  "Get sideline photography access at a San Diego FC game (see
  goals/sideline-photography-sdfc.md)". There's no separate file-link column —
  this is the whole mechanism, kept lightweight on purpose.
- File naming: kebab-case, matching the goal's subject, e.g.
  `sideline-photography-sdfc.md`. One file per goal.
- Don't duplicate the live task list here — tasks live in Supabase `tasks`
  (linked via the same project_id) and can change status/priority/dates on
  their own. This file is for the stuff that doesn't fit a task row: context,
  strategy, contacts, dead ends, decisions.

If a Claude chat elsewhere already has useful context on this goal (research,
a contact name, a prior plan), consolidate it into this file's Progress Log or
Strategy section rather than leaving it stuck in that chat's history.

Delete this comment block when using the template.
-->

# GOAL NAME

**Status:** active | done | abandoned
**Target:** optional — a date, number, or plain description of "done"
**Command Center project(s):** which project_id(s) this goal is linked to

## Strategy

The current plan/approach. What's the angle, who do you need to talk to, what
needs to happen for this to succeed. Update this section as the plan evolves —
it's the current best plan, not a history of every plan considered.

## Progress Log

Dated bullets, newest first. Short entries — what happened, what was learned,
what changed.

- **YYYY-MM-DD:** ...

## Open Questions / Blockers

Things that need an answer or a decision before progress continues.

## Resources / Contacts

Names, links, reference material relevant to this specific goal.
