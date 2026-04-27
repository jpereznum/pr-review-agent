# Detailed flow

The orchestrator (`.claude/commands/review-prs.md`) implements this flow when invoked.

## Per-run flow

```
/review-prs
    ↓
Step 0: Pre-flight
  - Source env file → load $FORGEJO_PASSWORD
  - cloudflared access token → fresh CF_TOKEN
  - codex exec --version
  - read .claude/settings.local.json
  ↓ (any failure → STOP, ask user)

Step 1: Load state
  - Read .claude/state/pr-reviews.json (or create {})
  ↓

Step 2: List pending PRs
  - GET /api/v1/repos/{repo}/pulls?state=open&limit=50
  - Filter: not draft, $REVIEWER_USERNAME in requested_reviewers
  - Capture: number, title, head_sha, author, base
  ↓

For each PR:

  Step 3: Decide action
  ┌──────────────────────────────────────────────────────────────┐
  │ State condition                          │ Action            │
  ├──────────────────────────────────────────┼───────────────────┤
  │ No state entry                           │ Round 1 (full)    │
  │ last_reviewed_sha == current_sha         │ Skip              │
  │ SHA changed AND round < 2                │ Re-review (incr)  │
  │ SHA changed AND round >= 2 AND           │ Round-3 handoff:  │
  │   last_verdict == "request_changes"      │ DM, no review     │
  │ last_verdict == "approve"                │ Delete entry,skip │
  └──────────────────────────────────────────────────────────────┘
  ↓

  Step 4: Adversarial debate
  4a. Get diff
      - Round 1: GET .../pulls/{n}.diff
      - Re-review: git diff <last_sha>..FETCH_HEAD
      - Save to .claude/audit/YYYY-MM-DD/{run_id}.diff
  4b. Round 1: pr-reviewer subagent → claude_r1
      - Save to /tmp/audit_{run_id}_claude_r1.json
  4c. Round 2: codex exec → codex_r2
      - Run codex, capture stdout, parse last balanced JSON object
      - Save to /tmp/audit_{run_id}_codex_r2.json
      - On parse failure → goto 5c
  4d. Round 3: pr-reviewer subagent (with codex_r2) → claude_r3
      - Save to /tmp/audit_{run_id}_claude_r3.json
  4e. Convergence check
      - Same verdict?
      - All blocking issues match (file + intent)?
      ↓

  Step 5: Act
  ┌─────────────────────────────────────────────────────────────┐
  │ Outcome           │ Action                                  │
  ├───────────────────┼─────────────────────────────────────────┤
  │ Converged         │ 5a: POST review to Forgejo, DM Slack,   │
  │                   │     update state                        │
  │ Not converged     │ 5b: nothing posted, increment retries.  │
  │   (1st failure)   │     Next run will retry.                │
  │ Not converged     │ 5b: DM "no consensus", stand down.      │
  │   (2nd failure)   │                                         │
  │ Step 4 errored    │ 5c: nothing posted, no state change,    │
  │                   │     log error, continue to next PR.     │
  └─────────────────────────────────────────────────────────────┘
  ↓

  Step 6: Round-3 handoff (only if Step 3 chose this path)
  - DM the user. No state change.
  ↓

  Step 7: Finalize audit record
  - Assemble full JSON record from /tmp/audit_{run_id}_*.json files
  - Write to .claude/audit/YYYY-MM-DD/{run_id}.json
  - Append summary line to .claude/audit/index.jsonl
  - For posted_* outcomes: write {run_id}.posted.json with the body POSTed
  - Clean up /tmp/audit_{run_id}_*.json

End-of-run summary printed to user.
```

## State machine for a single PR (across multiple `/review-prs` invocations)

```
[no state]
    │
    ↓ (first /review-prs run)
[round=1, last_verdict=request_changes, last_reviewed_sha=A]
    │
    ↓ (author pushes B; next run)
[round=2, last_verdict=request_changes, last_reviewed_sha=B]
    │
    ↓ (author pushes C; next run)
ROUND-3 HANDOFF — DM, no review, no state change
    │
    ↓ (user manually deletes state entry, or reviews in Forgejo)
[no state]    ← cycle restarts


Alternative path: approve

[no state]
    │
    ↓ (first /review-prs run)
[round=1, last_verdict=approve]
    │
    ↓ (any subsequent run)
[entry deleted]    ← approved PRs are done


Alternative path: no consensus

[no state]
    │
    ↓ (first /review-prs run, no consensus)
[no_consensus_retries=1, no other state changes]
    │
    ↓ (next run, same SHA, no consensus again)
[no_consensus_retries=2]    ← agent DMs user, stands down on this SHA
    │
    ↓ (author pushes new SHA)
treated as new (retries reset to 0)
```

## Audit record lifecycle

A single audit record is built up across the flow:

```
4a: open record, fill .pr.*, .internal_round, .is_re_review, .diff_file, .diff_stats
4b: fill .debate.claude_r1
4c: fill .debate.codex_r2 (or set .errors[] and .outcome="error")
4d: fill .debate.claude_r3
4e: fill .convergence
5a: fill .actions.forgejo_post.*, .actions.slack_dm.*, set .outcome
5b: fill .actions.slack_dm.* (if standdown), set .outcome
5c: append to .errors[], set .outcome="error"
6:  fill .actions.slack_dm.*, set .outcome="round3_handoff"
7:  finalize, write to disk, append index line
```

Always written, never overwritten. Each run produces a new record with a unique `run_id`.
