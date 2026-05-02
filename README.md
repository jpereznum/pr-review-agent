# Adversarial PR Review Agent for Claude Code

A Claude Code agent that reviews Forgejo pull requests through an adversarial debate between Claude and OpenAI Codex. When the two reviewers converge on a verdict, the agent posts the review to Forgejo (`approve` or `request_changes`) and DMs a designated person on Slack. When they don't converge, it stays silent and asks for human review.

Built around five principles:

1. **Silence until consensus.** No verdict is posted unless both reviewers agree on the verdict and on which issues are blocking.
2. **Bounded debate.** Three internal rounds: Claude reviews → Codex critiques → Claude rebuts. No further iteration on a single SHA.
3. **Round-3 handoff.** After two rounds of `request_changes` on a PR (i.e., the author has pushed twice and the agent has twice asked for changes), the agent stands down on a third push and hands off to a human.
4. **Full audit trail.** Every PR processed produces a structured JSON record containing the full debate, the convergence decision, what was posted, and what was DM'd.
5. **Tight permission allowlist.** A `.claude/settings.local.json` whitelist limits which command shapes the agent can run without prompting.

## What's in this repo

```
.
├── README.md                                    ← this file
├── LICENSE
├── install/install.sh                           ← interactive installer
├── template/
│   └── .claude/
│       ├── agents/pr-reviewer.md                ← the reviewer subagent
│       ├── commands/review-prs.md.template      ← the orchestrator (with placeholders)
│       ├── settings.local.json.template         ← permission allowlist
│       ├── state/pr-reviews.json                ← empty seed
│       └── audit/README.md                      ← audit folder docs
└── docs/
    ├── security.md                              ← threat model & mitigations
    ├── flow.md                                  ← detailed flow diagram
    └── tuning.md                                ← how to adjust severity rules, rounds, etc.
```

## Requirements

- **Claude Code CLI** installed and authenticated.
- **Codex CLI** installed and authenticated against your OpenAI account (`codex exec --version` should succeed). Tested with v0.125.0.
- **Forgejo instance** with a Personal Access Token (PAT) for the reviewer account. The agent uses HTTP Basic Auth where the PAT is supplied as the password value — Forgejo accepts this for API calls. A real account password may also work but many Forgejo instances disable basic-auth-with-password for the API; **PATs are the recommended path** and avoid 2FA, lockout, and revocation issues. See `.claude/env.example` after install for PAT setup steps.
- **Cloudflare Access** is optional — supported if your Forgejo is behind it (the agent fetches a token via `cloudflared` on each run), skipped otherwise.
- **Slack** connector for Claude Code (or comparable) if you want DM notifications.
- **Bash, Python 3, curl, git.** The agent uses small `/tmp/*.sh` and `/tmp/*.py` scripts for JSON manipulation rather than inline heredocs (Hard Rule 9 — avoids Claude Code's content-based safety prompts).

## Install

```bash
git clone https://github.com/<your-org>/pr-review-agent.git
cd /path/to/your/project           # the project where you want the agent installed
/path/to/pr-review-agent/install/install.sh
```

The installer prompts for:

| Variable | Example | Notes |
|----------|---------|-------|
| `FORGEJO_BASE_URL` | `https://git.example.com` | No trailing slash. |
| `REPO` | `myorg/myproject` | The single repo this install will review. |
| `REVIEWER_USERNAME` | `alice` | Your Forgejo username — the one PRs are assigned to AND the one whose PAT you'll put in `.claude/env`. These must match: Forgejo refuses self-reviews, so a PAT belonging to the PR author can't be used to review their own PRs. |
| `SLACK_RECIPIENT_NAME` | `Bob` | Person who receives DMs. The agent looks them up via the Slack connector. |

The installer writes:

- `.claude/agents/pr-reviewer.md`
- `.claude/commands/review-prs.md`
- `.claude/settings.local.json` (created only if missing — won't overwrite existing settings)
- `.claude/state/pr-reviews.json` (created empty only if missing)
- `.claude/env.example` — template for your env file
- `.claude/audit/README.md` and `.gitkeep`
- Adds `.claude/audit/` and `.claude/env` to `.gitignore`.

## Set up your env file

Before first run, you need to provide the agent with a Forgejo credential. Use a Personal Access Token (PAT), not your account password.

### 1. Mint a PAT in Forgejo

Sign in as the reviewer user (e.g. `alice`), then:

1. Go to `<your-forgejo>/user/settings/applications`.
2. Under **Manage Access Tokens**, click **Generate New Token**.
3. Name: `claude-pr-review` (or similar).
4. Scopes: `read:repository`, `read:issue`, `write:issue`. (`repo` full access is fine if you want headroom.)
5. Click **Generate Token** and copy the value immediately — Forgejo only shows it once.

### 2. Drop it into `.claude/env`

```bash
cp .claude/env.example .claude/env
chmod 600 .claude/env
# Edit .claude/env, paste the PAT as the FORGEJO_PASSWORD value.
# The variable name stays FORGEJO_PASSWORD — Forgejo accepts a PAT
# as the basic-auth password value, so the agent's curl shapes work
# unchanged whether the value is a PAT or a real password. PAT is
# strongly recommended.
```

### 3. Verify the identity

After the agent's first run, the pre-flight will hit `/api/v1/user` and confirm the token authenticates as the username you configured. If the `login` field doesn't match (e.g. you generated the PAT while logged into the wrong account), the run halts and tells you. **Forgejo refuses self-reviews**, so identity matters: the PAT must belong to the reviewer, not the PR author.

`.claude/env` is gitignored. The agent reads it on every run via Step 0 (pre-flight) and refuses to proceed if `FORGEJO_PASSWORD` isn't set. **Hard Rule 7** prevents the agent from substituting a literal value seen elsewhere — env-loaded or halt.

## Usage

After install, in the project root:

```bash
claude
```

Then in the session:

```
/review-prs
```

The agent will:

1. **Pre-flight:** source `.claude/env` to load `FORGEJO_PASSWORD`, optionally fetch a Cloudflare Access token via `cloudflared`, confirm Codex is reachable.
2. **List PRs:** open non-draft PRs in the configured repo where the reviewer username is in `requested_reviewers`.
3. **For each PR with a new HEAD SHA:** run the 3-round debate, write an audit record, post the verdict if converged, DM Slack.
4. **Print an end-of-run summary.**

If no PRs are assigned to you, the agent reports "nothing to do" and exits without writing audit records.

## Automation options

Three ways to run `/review-prs`, in increasing order of autonomy:

### 1. Manual (default)

You run `/review-prs` in Claude Code when you want a review pass. Best for first-time use and infrequent reviews.

### 2. In-session scheduler (Claude Code's built-in cron)

Claude Code provides scheduling primitives (`CronCreate` / `CronList` / `CronDelete`) that can fire `/review-prs` on a cron expression while a Claude Code session is open. Useful during your work day to pick up review requests automatically without remembering to trigger them.

In any Claude Code session, ask:

```
Schedule /review-prs to run every 15 minutes, durable so it survives restarts.
```

Claude Code creates a recurring job. To inspect: *"List active cron jobs."* To cancel: *"Delete cron job <id>."*

Important caveats:

- **Session-bound by default.** The job dies when the terminal closes unless you ask for `durable: true`, which persists it to `.claude/scheduled_tasks.json` and survives Claude Code restarts.
- **Auto-expires after 7 days.** Cron jobs are intentionally short-lived; reschedule as needed.
- **Fires only when the Claude Code REPL is idle.** A long-running review delays the next tick. Jobs do not run concurrently.
- **Approval prompts still apply.** If a run hits a permission prompt at 3am, it waits at the prompt until you return — the next tick won't help. Build out your allowlist (via Claude Code's "Yes, and don't ask again" option) before depending on the schedule for real coverage.
- **Your machine must stay on** with Claude Code running. This is not headless cron.
- **Built into Claude Code, not this agent.** The capability comes from the Claude Code runtime; this repo just documents how to use it with `/review-prs`. Refer to the Claude Code docs for full scheduler semantics.

### 3. Headless via system cron (advanced, not yet documented end-to-end)

For true unattended operation — runs while you're asleep, logged out, or away — Claude Code can run headlessly (`claude --dangerously-skip-permissions`, or `auto` mode on Team/Enterprise plans) from a real `crontab` entry. The skeleton looks like:

```cron
*/15 * * * * cd /path/to/project && claude --dangerously-skip-permissions -p "/review-prs" >> /tmp/pr-review.log 2>&1
```

**This path is not yet validated in this repo.** Running it safely requires real work that isn't built into the install:

- A tightened deny list specifically scoped for unattended use (the default deny rules here are calibrated for interactive sessions where a human can catch missed cases).
- Pre-flight validation that fails the run before any Forgejo/Codex/Slack call if env, identity, or connectivity look wrong.
- Log capture and alerting on errors, since no human sees the output in real time.
- An understanding that a prompt-injection attack inside a PR's content bypasses the per-prompt human gate that interactive mode provides.

If you need full unattended operation, treat it as a separate hardening project. The in-session scheduler (option 2) covers most "reviews fire automatically while I'm working" needs without the additional risk surface.

## How the debate works

Per PR:

```
                ┌──────────────────────────┐
                │  Round 1: Claude review  │
                │  (full diff, JSON out)   │
                └────────────┬─────────────┘
                             ↓
                ┌──────────────────────────┐
                │  Round 2: Codex critique │
                │  (gets Claude's review)  │
                └────────────┬─────────────┘
                             ↓
                ┌──────────────────────────┐
                │  Round 3: Claude rebuts  │
                │  (sees Codex's critique) │
                └────────────┬─────────────┘
                             ↓
                ┌──────────────────────────┐
                │   Convergence check      │
                │  same verdict + same     │
                │  blocking issues?        │
                └──┬─────────────────────┬─┘
                   │                     │
                  yes                   no
                   │                     │
                   ↓                     ↓
            ┌───────────┐         ┌─────────────┐
            │  POST to  │         │  Stay silent│
            │  Forgejo  │         │  Retry next │
            │  + DM     │         │  run; after │
            │  Slack    │         │  2 fails,   │
            └───────────┘         │  DM human   │
                                  └─────────────┘
```

**Convergence definition:** same verdict (`approve` vs `request_changes`), AND for every issue tagged `blocking` in either review, the other has a corresponding issue with the same `file` and overlapping intent. Non-blocking and nit issues do not need to match.

**Round 3 handoff (separate from internal rounds):** the agent counts how many times it has posted `request_changes` on a PR. After two such posts, if the author pushes again, the agent does not run a third internal debate — it just DMs the human and stands down.

## Audit logs

Every processed PR writes a JSON record to `.claude/audit/YYYY-MM-DD/`. Each record contains:

- PR metadata (ref, title, author, SHA, URL).
- The internal round counter and whether this is a re-review.
- Full JSON output from Claude r1, Codex r2, Claude r3.
- The convergence decision, including divergence notes when convergence failed.
- What was posted to Forgejo (with the exact request body in a sidecar file).
- The Slack DM that was sent.
- Errors and timing.

A summary line per run is appended to `.claude/audit/index.jsonl`.

The audit folder is `.gitignore`'d by default because diffs may contain accidentally-committed secrets. Treat audit data as sensitive.

See `template/.claude/audit/README.md` for the schema and `jq` query examples.

## Security model

This agent processes attacker-influenced input (PR diffs, titles, commit messages) and has Forgejo credentials in scope. The threat model and mitigations are in [docs/security.md](docs/security.md). Highlights:

- **Prompt injection in PR content** is the main attack vector. The orchestrator instructs Claude and Codex to treat all PR content as untrusted data; the permission allowlist limits blast radius if injection succeeds.
- **The Forgejo credential lives in an env file** (PAT recommended over password), never in commands or audit logs. Hard Rule 7 in the orchestrator forbids inlining literal credentials into bash commands.
- **The permission allowlist** in `.claude/settings.local.json` whitelists specific command shapes (Forgejo API calls to your repo, git on the project, Codex, restricted file ops). Anything outside that list prompts you. Deny rules block obviously dangerous patterns even if the allowlist would otherwise match.

## Common gotchas

Hard-won lessons from the first deployment. Read these before your first run.

### Identity mismatch (PAT for the wrong user)

The PAT you put in `.claude/env` must belong to the **reviewer** account, not the PR author. Forgejo refuses self-reviews. If you generate a PAT while logged in as user A, then configure the agent with `REVIEWER_USERNAME=B`, every Forgejo POST will fail. The pre-flight checks `/api/v1/user` and the `login` field — if it doesn't match `REVIEWER_USERNAME`, halt and regenerate the PAT under the correct account.

### `requested_reviewers` vs `assignees`

Forgejo distinguishes between **requested reviewers** (people whose review is formally requested on the PR) and **assignees** (people responsible for the PR). The agent filters on `requested_reviewers` by default. If your team uses `assignees` instead, the agent will report "nothing to do" even when work exists. Either change your team's convention or modify Step 2 of the orchestrator to check both fields.

### Cloudflare Access vs Forgejo auth

These are two layers, and a 401 vs HTML-redirect tells you which is broken:

- **HTML login page returned** → CF Access token missing/expired. Run `cloudflared access login <base-url>`.
- **JSON `{"message": "user's password is invalid"}`** → Forgejo PAT is wrong or expired. Regenerate at `/user/settings/applications`.
- **HTTP 200 with normal JSON** → both layers are happy.

### PRs containing live secrets

If a PR's diff includes secret values (e.g., a "remove leaked secrets" PR — the agent has reviewed one of these), shipping the diff to Codex re-leaks those secrets externally. The agent will pause and ask. Default response: redact secret-containing files entirely before sending to Codex, review the cleanup logic from the redacted version. See `docs/security.md` for details.

### Stop trying to silence harness prompts via the allowlist

Claude Code has content-based safety checks (`Contains simple_expansion`, `expansion obfuscation`, `Unhandled node type: string`) that fire on inline shell expansions, embedded heredocs, and complex composites — **regardless of what's in `.claude/settings.local.json`**. The fix is at the agent level (Hard Rule 9): write logic to `/tmp/script.sh` or `/tmp/script.py` first, then run it as a clean simple command. The orchestrator already does this for Step 0 pre-flight and Step 4c Codex parsing. If you extend the agent, follow the same pattern.

## Limitations

- **One repo per install.** Multi-repo support would require a config array. Out of scope for v1.
- **Polls on demand.** The agent runs when you invoke `/review-prs`. Cron and webhook automation are documented but not built in. See [docs/automation.md](docs/automation.md).
- **Forgejo basic-auth + Cloudflare Access only.** Other auth setups will need the curl shapes adjusted. PRs welcome.
- **Codex 0.125.0 output format.** The orchestrator's JSON parser handles the banner+tokens-line format of this version. If Codex changes its output, the parser may need tweaking — see [docs/tuning.md](docs/tuning.md).

## Tuning

After running on real PRs, you'll want to tune. Common adjustments:

- **Severity calibration** — if Claude over-flags or Codex under-flags, edit `.claude/agents/pr-reviewer.md`.
- **More debate rounds** — Option B (full back-and-forth pairs, ~6 rounds) is a small change to the orchestrator.
- **Auto-approve guardrails** — disable approve verdicts on PRs touching sensitive paths (auth, crypto, lockfiles).
- **PR size threshold** — skip very large diffs to control token cost.

See [docs/tuning.md](docs/tuning.md).

## Contributing

Pull requests welcome. Please:

- Keep the debate flow auditable — every change should still produce sensible audit records.
- Don't add tools that could exfiltrate data without an explicit allowlist entry.
- Test against a Forgejo instance you control; never against production.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgements

Built on Claude Code's subagent and slash command primitives. The "silence until consensus" pattern was the result of design conversations exploring how to make adversarial-review agents trustworthy enough to merge into a real review workflow without becoming review-noise.
