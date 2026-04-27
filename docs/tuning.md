# Tuning

After a few real runs you'll have opinions. Here's how to act on them.

## Severity calibration

If Claude (or Codex) consistently overcalls or undercalls severity, edit the rules in `.claude/agents/pr-reviewer.md` (the reviewer subagent) and the inline Codex prompt in `.claude/commands/review-prs.md` Step 4c.

Current rules (Option A defaults):

- `blocking` — real bug with concrete failure mode, security issue, broken test, removed test coverage, breaking change without migration.
- `non-blocking` — worth raising, PR can still merge.
- `nit` — pure preference.

Common adjustments:

- **Tighten `blocking`** if too many `request_changes` outcomes feel pedantic. Add: "An issue is only `blocking` if you can name a user-visible consequence in one sentence."
- **Loosen `blocking`** for a security-critical codebase. Add specific paths or change types that should always be `blocking` regardless of failure mode.
- **Add a project-specific rule.** E.g., "Any change to files under `migrations/` requires manual review — never auto-approve, downgrade `approve` to `comment`."

## Round count (Option A → Option B)

Default is **3 internal rounds total** (Claude → Codex → Claude). To switch to **6 rounds** (full back-and-forth pairs):

1. In `review-prs.md` Step 4, add Round 4 (Codex sees Claude's r3 and revises) and Round 5 (Claude sees Codex's r4 and revises) and Round 6 (Codex sees Claude's r5 and finalizes).
2. Update the convergence check to compare the *last* outputs from each side (not r2 vs r3).
3. Update audit schema to store all six rounds.

When to consider Option B:

- Convergence rate is below ~60%.
- Frequent no-consensus runs where the divergence looks resolvable with one more pass.
- You don't mind ~2x token cost.

## Auto-approve guardrails

By default, a converged `approve` verdict immediately posts to Forgejo. To prevent auto-approval on risky changes:

In `review-prs.md` Step 5a, before posting, add a guard:

```
If verdict is "approve":
  - Check diff stats. If lines_added > 200, downgrade to "comment".
  - Check changed files. If any match: auth/**, crypto/**, .env*, package-lock.json,
    yarn.lock, Cargo.lock, requirements.txt, pyproject.toml, .github/**, .gitea/**,
    .ci/**, ci/** — downgrade to "comment".
  - Check for deleted test files. If any test_*.py or *.test.* file was removed,
    downgrade to "comment".
  - When downgrading, explain in the Slack DM why: "Auto-approve guardrail
    triggered: <reason>. Posting as comment instead."
```

This trades coverage for safety. You can manually approve in Forgejo after reviewing the agent's comment.

## PR size threshold

Big PRs are expensive (each model call scales with diff size) and harder to review well. To skip them:

In Step 2, after listing PRs, filter by size:

```python
# Skip PRs over N lines changed
if pr['additions'] + pr['deletions'] > 1500:
    audit_skip(pr, reason="oversized")
    continue
```

DM the user about skipped PRs so they don't go silently unreviewed.

## Codex output format changes

The orchestrator's parser in Step 4c handles Codex 0.125.0's banner-and-tokens output format. If a Codex update changes that:

- Run `codex exec "Reply with only this JSON: {\"test\":1}"` and inspect output.
- Update the `find_last_json_object` heuristic in Step 4c if needed.
- The current heuristic looks for the *last* balanced top-level `{...}` block containing a `verdict` field — this is robust against most format changes as long as the model still emits a JSON object somewhere.

## Slack message format

DMs are summary-only by design. To customize the format:

- Edit the templates in Step 5a (approve, request changes) and Step 6 (round-3 handoff).
- Keep them short — full detail belongs in the audit log, not in Slack.
- If you want richer messages (Slack blocks, attachments), the Slack connector likely supports it; check its docs.

## Multi-repo

The current install is single-repo. To run on multiple repos:

- Option 1: install separately in each project, run `/review-prs` in each session.
- Option 2: change `REPO` to a list in the orchestrator's Configuration section, loop over it in Step 2. Audit records and state file already key on `owner/repo#number`, so this works without schema changes.

Option 2 is more convenient for one team reviewing many repos, but harder to scope a permission allowlist to (you'd need to either widen the URL pattern or list each repo's pattern explicitly).

## Convergence rule

The default convergence rule:

- Same verdict.
- For every issue tagged `blocking` in either review, the other has a corresponding issue with the same `file` and overlapping intent.

To tighten (more no-consensus, fewer false agreements):

- Require severity match on every issue, not just blocking.
- Require line numbers within ±5 lines.

To loosen (more agreement, more risk of false positives slipping through):

- Allow `approve` if neither side has any blocking issues, even if they disagree on non-blocking items.
- Allow line-level mismatch if file matches.

The convergence rule lives in Step 4e of the orchestrator. Edit it carefully — this is the single most important knob for the agent's behavior.
