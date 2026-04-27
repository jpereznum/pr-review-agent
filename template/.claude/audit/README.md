# Audit logs

Every `/review-prs` run writes one record per PR processed.

## Layout

```
.claude/audit/
├── 2026-04-26/
│   ├── 1808_abc12345_round1_143022.json    ← the audit record
│   ├── 1808_abc12345_round1_143022.diff    ← raw diff that was reviewed
│   └── 1808_abc12345_round1_143022.posted.json  ← exact body POSTed (only on posted_*)
├── 2026-04-27/
│   └── ...
└── index.jsonl  ← one line per run, append-only, used by the monitoring UI
```

Filename format: `{pr_number}_{first_8_chars_of_sha}_round{N}_{HHMMSS}` where N is the agent's internal round counter (not the debate round inside one run).

## What goes in the JSON

See the "Audit logging" section in `.claude/commands/review-prs.md` for the full schema. Key fields:

- `outcome` — `posted_approve` | `posted_request_changes` | `no_consensus_retry` | `no_consensus_standdown` | `round3_handoff` | `error`
- `debate.claude_r1` / `codex_r2` / `claude_r3` — full JSON outputs from each model in the debate
- `convergence` — what they agreed on, or why they didn't
- `actions` — what was actually posted to Forgejo and Slack
- `errors` — any failures, with redacted secrets

## Privacy

Diffs may contain secrets if developers accidentally commit them. **This folder must not be pushed to a public repo.** Either keep it local-only via `.gitignore`, or commit it only to a private audit repo with controlled access.

The orchestrator is instructed to redact Forgejo passwords and Cloudflare tokens from error messages, but human inspection of records is still wise before sharing them outside your team.

## Retention

Records grow indefinitely. A reasonable cleanup pattern (run manually or via cron):

```bash
# Archive anything older than 90 days
find .claude/audit -type d -name '20*' -mtime +90 -exec tar czf {}.tar.gz {} \; -exec rm -rf {} \;
```

## Querying without the UI

The index is jsonl, so:

```bash
# All no-consensus runs in the last week
jq -c 'select(.outcome | startswith("no_consensus"))' .claude/audit/index.jsonl

# All runs for a specific PR
jq -c 'select(.pr_number == 1808)' .claude/audit/index.jsonl

# Convergence rate
jq -s '[.[].converged] | (map(select(.)) | length) / length * 100' .claude/audit/index.jsonl
```
