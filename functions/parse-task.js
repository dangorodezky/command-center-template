// Cloudflare Pages Function — POST /parse-task
// Turns a freeform note ("work: run capture rates, by noon") into structured
// task fields via Claude. The Anthropic API key lives only as a Cloudflare
// secret (env.ANTHROPIC_API_KEY) — never shipped to the browser, unlike the
// Supabase anon key which is already public in dashboard.html by design.
//
// Request body:  { text: string, today: "YYYY-MM-DD", projects: [{id, name, is_default}] }
// Response body: { parsed: { project_id, description, detail, due_date, due_time,
//                             priority, not_before, estimate_minutes, is_event } }
// All parsed fields except description/priority may be null. The model
// returns project_id=null when it isn't confident which project fits; this
// handler then defaults that to whichever project has is_default=true (set via
// the checkbox in the project edit modal — see the projects.is_default column
// note in schema.sql) rather than leaving it empty, since an unassigned task is
// easy to lose track of. Falls back to true null only if no project is marked
// default, in which case the frontend still forces the user to pick one.
// description/detail follow the tight-description convention (see the `detail`
// column note in schema.sql / CLAUDE.md) — description is a short verb-phrase,
// detail carries rationale/numbers/links the note might have included.
// is_event marks a calendar event (a game, appointment, reservation — something
// that happens at a fixed time, not a to-do) — see the is_event column note in
// schema.sql. Always paired with a real due_date; the frontend re-validates this
// before saving rather than trusting the model unconditionally.

const CREATE_TASK_TOOL = {
  name: "create_task",
  description: "Create one task from the freeform note.",
  input_schema: {
    type: "object",
    properties: {
      project_id: {
        type: ["string", "null"],
        description: "id of the best-matching project from the provided list, or null if no project clearly fits",
      },
      description: {
        type: "string",
        description:
          "Tight verb-phrase, ideally 4-6 words, well under 10 — never the raw note verbatim. No embedded sentences, em-dash asides, or parentheticals longer than 2-3 words. If the note carries rationale, numbers, an address, a link, or 'not X but Y' reasoning, that goes in `detail` instead, not here.",
      },
      detail: {
        type: ["string", "null"],
        description:
          "Everything from the note that doesn't belong in the tight description — context, rationale, exact numbers/addresses/links, sub-steps. Null if the note is already a short clean action with nothing left over.",
      },
      due_date: { type: ["string", "null"], description: "YYYY-MM-DD or null" },
      due_time: { type: ["string", "null"], description: "24-hour HH:MM or null" },
      priority: { type: "integer", minimum: 1, maximum: 5 },
      not_before: {
        type: ["string", "null"],
        description: "YYYY-MM-DD — set only if the note implies this shouldn't surface until a future date",
      },
      estimate_minutes: {
        type: ["integer", "null"],
        enum: [15, 30, 60, 120, 240, null],
        description: "Rough effort bucket if the note implies a duration, otherwise null",
      },
      is_event: {
        type: "boolean",
        description:
          "true only if the note describes a calendar event you attend/observe at a fixed time (a game, appointment, reservation, wedding) rather than a to-do you complete. Must be paired with a real due_date — if you can't pin down a specific date, use false instead.",
      },
    },
    required: ["description", "priority", "is_event"],
  },
};

function buildSystemPrompt(today, projects) {
  const projectList = projects.length
    ? projects.map((p) => `${p.id}: ${p.name}`).join("\n")
    : "(no projects available)";

  return `You turn a short freeform note into one structured task for a personal tracker called Command Center.

Today's date is ${today} (YYYY-MM-DD).

Available projects (pick the closest match by id; if nothing clearly fits, use null rather than guessing):
${projectList}

Priority rubric for tasks — "if I never do this, what breaks?":
1 = today (overdue, due today, or a closing external window — a booking, ticket release, deadline)
2 = this week (time-sensitive but not today, or it unblocks other work)
3 = this month (real progress, no external clock)
4 = whenever (no urgency, low cost of never doing it)
5 = someday
Default to 3 if the note gives no urgency signal — don't inflate priority just because something was typed in a hurry.

Resolve relative dates/times against today's date (e.g. "by noon" -> due_date=today, due_time=12:00; "next Tuesday" -> the coming Tuesday's date). Use not_before only when the note implies the task shouldn't be actionable until a future date. Round estimate_minutes to 15/30/60/120/240 only if the note implies a rough duration, otherwise leave it null.

Keep description short and detail long, not the other way around. Example: note = "renew driver's license, DMV online opens renewal about 60 days before it expires, need to check the exact window on my renewal notice" -> description = "Renew driver's license", detail = "DMV online — opens renewal ~60 days before expiration; confirm exact window via DMV notice." A short parenthetical that disambiguates *which* thing this is (not *why* it matters) can stay in description, e.g. "Book rental car, El Calafate (Jan 10-14)".

Set is_event=true only for something the user attends/observes at a fixed time — a game, an appointment, a dinner reservation, a wedding — as opposed to an action they complete (booking something, writing something, deciding something, texting someone). A calendar event always needs a real due_date; if you can't pin one down, use is_event=false instead. Note: birthday reminders and recurring content posts are NOT events even though they're date-driven — they're actions (text someone, publish something), so leave is_event=false for those.

Always call the create_task tool exactly once with your best-effort guess for every field — never ask a clarifying question back, the user will review and correct the result before it's saved.`;
}

export async function onRequestPost(context) {
  const { request, env } = context;

  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const text = (body.text || "").trim();
  if (!text) return jsonResponse({ error: "text is required" }, 400);

  const today = body.today || new Date().toISOString().slice(0, 10);
  const projects = Array.isArray(body.projects) ? body.projects : [];

  if (!env.ANTHROPIC_API_KEY) {
    return jsonResponse({ error: "ANTHROPIC_API_KEY is not configured on this deployment" }, 500);
  }

  let anthropicResp;
  try {
    anthropicResp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 512,
        system: buildSystemPrompt(today, projects),
        messages: [{ role: "user", content: text }],
        tools: [CREATE_TASK_TOOL],
        tool_choice: { type: "tool", name: "create_task" },
      }),
    });
  } catch (err) {
    return jsonResponse({ error: `Could not reach Anthropic API: ${err.message || err}` }, 502);
  }

  if (!anthropicResp.ok) {
    const errText = await anthropicResp.text();
    return jsonResponse({ error: `Anthropic API error (${anthropicResp.status}): ${errText}` }, 502);
  }

  const data = await anthropicResp.json();
  const toolUse = (data.content || []).find((block) => block.type === "tool_use");
  if (!toolUse) {
    return jsonResponse({ error: "Model did not return a structured task" }, 502);
  }

  const parsed = toolUse.input;
  if (!parsed.project_id) {
    const defaultProject = projects.find((p) => p.is_default);
    if (defaultProject) parsed.project_id = defaultProject.id;
  }

  return jsonResponse({ parsed });
}

function jsonResponse(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
