---
description: Start a recurring /review-prs schedule. Cleans up any existing review schedules first, then creates a new one (durable if supported, session-only otherwise) and reports the actual lifetime guarantees.
---

You are setting up a recurring schedule for the `/review-prs` PR review pipeline. Goal: a single recurring cron job that fires `/review-prs` every 15 minutes, with the longest practical lifetime the user's Claude Code build supports.

Steps to follow exactly, in order:

## Step 1 — Inspect existing schedules

Use the `CronList` tool to list every active scheduled task in this session.

## Step 2 — Cancel any existing /review-prs schedules

For each job whose prompt is `/review-prs` (or contains `/review-prs`):

- Tell the user: "Found existing schedule `<id>` for `/review-prs` (`<lifetime>`). Cancelling so we can recreate it cleanly."
- Use `CronDelete` with that job ID.

This avoids piling up duplicate jobs every time the user runs `/start-review-loop`.

## Step 3 — Create a new schedule with `durable: true`

Use `CronCreate` with these parameters:

- `cron`: `*/15 * * * *`
- `prompt`: `/review-prs`
- `recurring`: `true`
- `durable`: `true`

Claude Code may or may not honor `durable: true` — some builds silently ignore it. That's fine; we'll detect what actually happened in Step 4.

## Step 4 — Confirm what was actually created

Use `CronList` again to read the new job's actual lifetime.

If the new job shows `[durable]` (or its description indicates persistence to `.claude/scheduled_tasks.json`):

- Report to the user: "✅ Recurring `/review-prs` schedule active (job `<id>`), every 15 minutes, durable. Will survive Claude Code restarts. Auto-expires after 7 days; rerun `/start-review-loop` before then to refresh."

If the new job shows `[session-only]` (the `durable` flag was accepted but not honored by this build):

- Report to the user: "⚠️ Recurring `/review-prs` schedule active (job `<id>`), every 15 minutes, **but session-only**. Your Claude Code build accepted the `durable: true` flag but did not write the schedule to disk. The schedule will die when this terminal session closes. Run `/start-review-loop` again at the start of your next Claude Code session to recreate it. For genuine cross-session persistence, use a system `crontab` entry (see README §Automation options)."

## Step 5 — Show the final state

Use `CronList` one more time and display the full output to the user, so they can see exactly what's scheduled.

## Notes

- Do NOT call `/review-prs` itself as part of this command. The schedule fires later on its own; this command only sets it up.
- Do NOT modify any other scheduled tasks (those whose prompts are unrelated to `/review-prs`).
- Do NOT touch `.claude/state/`, `.claude/audit/`, `.claude/env`, or `.claude/settings.local.json`.
- If `CronCreate` fails entirely (not "ignored durable" but actual failure), report the error verbatim and stop. Do not retry blindly.
