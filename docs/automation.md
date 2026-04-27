# Automation

The agent runs on demand by default — you start a Claude Code session and type `/review-prs`. This is the right default while you're calibrating the agent. Once you trust it, you can automate the trigger.

## Manual (default)

```bash
cd /path/to/project
claude
# in session:
/review-prs
```

Pros: fully observable, you see every step, easy to abort. Cons: requires you to remember.

## Cron + headless Claude Code

```bash
*/30 * * * * cd /path/to/project && \
  source .claude/env && \
  claude -p "/review-prs" \
    --output-format json \
    --bare \
    --max-turns 60 \
    --max-budget-usd 2.00 \
    >> /var/log/pr-review.log 2>&1
```

Notes:

- Cron has a minimal environment. `source .claude/env` (or your equivalent) to get `FORGEJO_PASSWORD` into the shell.
- `cloudflared` and `codex` must be on `PATH`. You may need to set `PATH` explicitly in the cron line.
- `--bare` skips loading user-level settings, which is what you usually want for unattended runs (predictable behavior).
- `--max-budget-usd` is a circuit breaker; tune to your expected per-run cost.
- The cloudflared token expires after ~24h interactive auth. For unattended use, configure service token auth via `cf-access-id` / `cf-access-secret` headers — see Cloudflare Access service token docs.

## Forgejo webhook

Lower latency than polling; fires only when PRs change.

1. Set up a small HTTP endpoint (Flask, FastAPI, anything) that listens for `pull_request` events.
2. On `opened`, `synchronized`, or `review_requested`, invoke `claude -p "/review-prs"` (optionally pass the PR number to make the agent skip listing).
3. Configure a Forgejo webhook in your repo's Settings → Webhooks pointing at your endpoint, with the `Pull Request` trigger.

Skeleton:

```python
from flask import Flask, request
import subprocess

app = Flask(__name__)

@app.post("/forgejo-webhook")
def webhook():
    event = request.headers.get("X-Forgejo-Event")
    if event != "pull_request":
        return "", 204
    payload = request.get_json()
    if payload["action"] not in ("opened", "synchronized", "review_requested"):
        return "", 204
    # Optional: pass PR number to make /review-prs target it
    pr_number = payload["pull_request"]["number"]
    subprocess.Popen([
        "claude", "-p", f"/review-prs {pr_number}",
        "--bare", "--max-turns", "60", "--max-budget-usd", "2.00",
    ], cwd="/path/to/project")
    return "", 202
```

The orchestrator currently doesn't accept a PR number argument; you'd extend Step 2 to honor an explicit target if provided.

## Allowlist for unattended runs

For cron and webhook setups, also pass `--allowedTools` to Claude Code so it doesn't even ask. Match the patterns in `.claude/settings.local.json`:

```bash
claude -p "/review-prs" \
  --allowedTools \
    "Bash(curl -s -u alice:* -H cf-access-token:* https://git.example.com/api/v1/repos/myorg/myproject/*)" \
    "Bash(curl -s -u alice:* -H cf-access-token:* -H Accept:* https://git.example.com/myorg/myproject/pulls/*.diff)" \
    "Bash(curl -s -u alice:* -H cf-access-token:* -X POST -H Content-Type:* --data @/tmp/* https://git.example.com/api/v1/repos/myorg/myproject/pulls/*/reviews)" \
    "Bash(cloudflared access token --app=https://git.example.com)" \
    "Bash(git fetch *)" \
    "Bash(git diff *)" \
    "Bash(codex exec*)" \
    "Bash(python3 -*)" \
    "Bash(mkdir -p *)" \
    "Bash(cat /tmp/*)" \
    "Bash(cat .claude/audit/*)" \
    "Bash(cat .claude/state/*)" \
    "Read(**)" \
    "Write(.claude/audit/**)" \
    "Write(.claude/state/**)" \
    "Write(/tmp/**)" \
  --bare
```

This is more verbose than `settings.local.json` (`--bare` skips that file) but gives you the same security boundary.

## What I'd actually do

1. **Manual for the first 1-2 weeks.** Calibrate. Watch for over-flagging, false convergence, prompt-injection attempts.
2. **Then move to webhook**, not cron. Webhook is event-driven (fires only when PRs change), which is more efficient and lower-latency than polling. Cron is fine if you can't run a webhook receiver, but it's the worse choice when both are available.
3. **Keep audit reviews on a schedule** — once a week, look at no-consensus runs and any auto-approves. Calibrate from there.
