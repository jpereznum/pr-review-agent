#!/usr/bin/env bash
# install.sh — interactive installer for the PR review agent
#
# Run from the repo root of the project you want to install into,
# OR pass --target /path/to/project as the first arg.
#
# This script:
#   1. Prompts for your Forgejo URL, repo, reviewer username, Slack recipient.
#   2. Substitutes those values into the templates.
#   3. Writes the customized files to <target>/.claude/.
#   4. Copies .claude/env.example so you can fill in your password.
#   5. Updates <target>/.gitignore to exclude .claude/audit/ and .claude/env.
#   6. Prints next steps.
#
# It does NOT:
#   - Touch your existing .claude/ contents other than the files it owns.
#   - Run the agent.
#   - Store secrets anywhere.

set -euo pipefail

# ----- Locate the template directory (relative to this script) -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/template"

if [[ ! -d "$TEMPLATE_DIR/.claude" ]]; then
  echo "ERROR: template directory not found at $TEMPLATE_DIR/.claude"
  echo "Run this script from inside a clone of the pr-review-agent repo."
  exit 1
fi

# ----- Parse args -----
TARGET=""
NONINTERACTIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  TARGET="$(pwd)"
fi

if [[ ! -d "$TARGET" ]]; then
  echo "ERROR: target directory does not exist: $TARGET"
  exit 1
fi

cd "$TARGET"

echo
echo "PR Review Agent installer"
echo "Target: $TARGET"
echo

# ----- Prompt for config -----
prompt() {
  local var="$1" question="$2" default="${3:-}"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    if [[ -n "${!var:-}" ]]; then return; fi
    if [[ -n "$default" ]]; then printf -v "$var" "%s" "$default"; return; fi
    echo "ERROR: --non-interactive but $var is not set and has no default"
    exit 1
  fi
  local prompt_str="$question"
  [[ -n "$default" ]] && prompt_str+=" [$default]"
  prompt_str+=": "
  read -r -p "$prompt_str" val
  if [[ -z "$val" && -n "$default" ]]; then
    val="$default"
  fi
  printf -v "$var" "%s" "$val"
}

prompt FORGEJO_BASE_URL    "Forgejo base URL (e.g. https://git.example.com)"
prompt REPO                "Repository (owner/name)"
prompt REVIEWER_USERNAME   "Your Forgejo username"
prompt SLACK_RECIPIENT_NAME "Slack DM recipient name (e.g. Bob)"

# Validate
if [[ ! "$FORGEJO_BASE_URL" =~ ^https?:// ]]; then
  echo "ERROR: FORGEJO_BASE_URL must start with http:// or https://"
  exit 1
fi
if [[ "$FORGEJO_BASE_URL" == */ ]]; then
  FORGEJO_BASE_URL="${FORGEJO_BASE_URL%/}"
fi
if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
  echo "ERROR: REPO must be in form owner/name"
  exit 1
fi

echo
echo "About to install with:"
echo "  Forgejo URL:     $FORGEJO_BASE_URL"
echo "  Repo:            $REPO"
echo "  Reviewer:        $REVIEWER_USERNAME"
echo "  Slack recipient: $SLACK_RECIPIENT_NAME"
echo

if [[ "$NONINTERACTIVE" != "1" ]]; then
  read -r -p "Proceed? [y/N] " yn
  [[ "$yn" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
fi

# ----- Substitute placeholders -----
substitute() {
  local src="$1" dst="$2"
  sed \
    -e "s|{{FORGEJO_BASE_URL}}|$FORGEJO_BASE_URL|g" \
    -e "s|{{REPO}}|$REPO|g" \
    -e "s|{{REVIEWER_USERNAME}}|$REVIEWER_USERNAME|g" \
    -e "s|{{SLACK_RECIPIENT_NAME}}|$SLACK_RECIPIENT_NAME|g" \
    "$src" > "$dst"
}

# ----- Create directory structure -----
mkdir -p .claude/agents .claude/commands .claude/state .claude/audit

# ----- Install files -----
echo "Installing files..."

# Subagents (no placeholders, just copy)
cp "$TEMPLATE_DIR/.claude/agents/pr-reviewer.md" .claude/agents/pr-reviewer.md
echo "  ✓ .claude/agents/pr-reviewer.md"

cp "$TEMPLATE_DIR/.claude/agents/pr-author-fixer.md" .claude/agents/pr-author-fixer.md
echo "  ✓ .claude/agents/pr-author-fixer.md"

# Orchestrators (templated)
substitute "$TEMPLATE_DIR/.claude/commands/review-prs.md.template" .claude/commands/review-prs.md
echo "  ✓ .claude/commands/review-prs.md"

substitute "$TEMPLATE_DIR/.claude/commands/address-changes.md.template" .claude/commands/address-changes.md
echo "  ✓ .claude/commands/address-changes.md"

# /start-review-loop helper (no placeholders, just copy)
cp "$TEMPLATE_DIR/.claude/commands/start-review-loop.md" .claude/commands/start-review-loop.md
echo "  ✓ .claude/commands/start-review-loop.md"

# Settings (templated)
if [[ -f .claude/settings.local.json ]]; then
  echo "  ! .claude/settings.local.json already exists — not overwriting"
  echo "    The new allowlist patterns are in: $TEMPLATE_DIR/.claude/settings.local.json.template"
  echo "    Merge manually if needed."
else
  substitute "$TEMPLATE_DIR/.claude/settings.local.json.template" .claude/settings.local.json
  echo "  ✓ .claude/settings.local.json"
fi

# State file (only if missing)
if [[ -f .claude/state/pr-reviews.json ]]; then
  echo "  ! .claude/state/pr-reviews.json exists — keeping yours"
else
  echo "{}" > .claude/state/pr-reviews.json
  echo "  ✓ .claude/state/pr-reviews.json (empty)"
fi

# env.example (always copy fresh — it has no secrets)
cp "$TEMPLATE_DIR/.claude/env.example" .claude/env.example
echo "  ✓ .claude/env.example"

# Don't overwrite an existing .claude/env (it has secrets)
if [[ -f .claude/env ]]; then
  echo "  = .claude/env exists — keeping yours"
fi

# Audit folder (always set up)
cp "$TEMPLATE_DIR/.claude/audit/README.md" .claude/audit/README.md
[[ ! -f .claude/audit/.gitkeep ]] && touch .claude/audit/.gitkeep
echo "  ✓ .claude/audit/ (README + .gitkeep)"

# ----- Update .gitignore -----
add_to_gitignore() {
  local pattern="$1" comment="$2"
  if [[ -f .gitignore ]] && grep -qxF "$pattern" .gitignore; then
    return
  fi
  if [[ ! -f .gitignore ]]; then
    : > .gitignore
  fi
  if [[ -n "$comment" ]]; then
    echo "" >> .gitignore
    echo "# $comment" >> .gitignore
  fi
  echo "$pattern" >> .gitignore
}

add_to_gitignore ".claude/audit/" "PR review agent — audit logs may contain diff content with secrets"
add_to_gitignore ".claude/env"    "PR review agent — env file with FORGEJO_PASSWORD, never commit"
echo "  ✓ .gitignore (updated)"

# ----- Done -----
echo
echo "Installation complete."
echo
echo "Next steps:"
echo "  1. Create your env file:"
echo "       cp .claude/env.example .claude/env"
echo "       chmod 600 .claude/env"
echo "       # Edit .claude/env and set FORGEJO_PASSWORD=..."
echo
echo "  2. (If your Forgejo is behind Cloudflare Access) confirm auth:"
echo "       cloudflared access token --app=$FORGEJO_BASE_URL"
echo
echo "  3. Confirm Codex CLI is installed:"
echo "       codex exec --version"
echo
echo "  4. Start a Claude Code session in this directory:"
echo "       claude"
echo
echo "  5. In the session, run either:"
echo "       /review-prs           # review PRs assigned to you"
echo "       /address-changes      # address REQUEST_CHANGES on PRs you authored"
echo "       /start-review-loop    # schedule recurring /review-prs (in-session)"
echo
echo "See README.md in the cloned repo for full documentation."
