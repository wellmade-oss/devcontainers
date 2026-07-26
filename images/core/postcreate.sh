#!/usr/bin/env bash
# Container-first-start setup. Runs after volume mounts are in place, so
# anything that needs to live alongside persisted state goes here — NOT
# in the Dockerfile, where volume mounts would shadow it.
#
# Idempotent: safe to re-run on rebuilds, no-op when state already exists.
#
# RESILIENCE: this script must NOT abort partway. The steps below are
# independent, and one failing must not skip the others — in particular the
# ~/.claude.json re-link (which preserves Claude's auth across rebuilds) must
# run even if the skills symlink fails. So we deliberately DON'T use `set -e`;
# instead each step is wrapped and a failure warns + continues. See the
# `step()` helper and the ownership self-heal below.
set -uo pipefail

ATELIER_AI_SKILLS=/opt/wellmade/atelier-ai/skills
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_JSON="${HOME}/.claude.json"

# Run a labelled step; on failure, warn and keep going instead of aborting.
step() {
  local label="$1"; shift
  if ! "$@"; then
    echo "wellmade: WARNING — step '${label}' failed (continuing)" >&2
    return 1
  fi
}

# ----- ownership self-heal (uid/gid mismatch recovery) ----------------------
# Runs first so the symlink/seed steps below inherit a writable $HOME even on a
# rebuild onto a host-uid-owned volume. Same script is also wired to
# postStartCommand so it catches a mismatch that appears on a plain start
# (postCreateCommand only fires on create). See fix-ownership.sh for the full
# rationale and docs/uid-gid-alignment.md for the launcher-side root cause.
step "self-heal \$HOME ownership" /opt/wellmade/bin/fix-ownership.sh || true

# ----- Claude: skills symlink ------------------------------------------------
# The atelier-ai skills live in the image. The ~/.claude volume mount would
# shadow a Dockerfile-built symlink, so we recreate it here on every create.
# -fn replaces an existing symlink without descending into it.
if [[ -d "${ATELIER_AI_SKILLS}" ]]; then
  step "mkdir ~/.claude" mkdir -p "${CLAUDE_DIR}" || true
  step "link skills" ln -sfn "${ATELIER_AI_SKILLS}" "${CLAUDE_DIR}/skills" || true
fi

# ----- Claude: ~/.claude.json persistence -----------------------------------
# Claude Code stores its user-level global config (OAuth, MCP) at $HOME/.claude.json,
# OUTSIDE the ~/.claude/ directory. That file would be lost on rebuild because
# only ~/.claude/ is mounted as a volume. Symlink it INTO the volume so it
# persists alongside everything else. This is the step that keeps you from
# re-authenticating on every rebuild — it MUST run even if the steps above
# failed, which is why the whole script no longer aborts on the first error.
if [[ ! -L "${CLAUDE_JSON}" ]]; then
  # First create: if the file already exists (newly-installed image with a
  # freshly populated claude.json), move it into the volume before symlinking.
  if [[ -f "${CLAUDE_JSON}" ]]; then
    step "seed claude.json into volume" mv "${CLAUDE_JSON}" "${CLAUDE_DIR}/claude.json" || true
  fi
  # Create the symlink if the target either exists (re-using a primed volume)
  # or doesn't (claude will create it on first auth, into the volume).
  step "link claude.json" ln -sfn "${CLAUDE_DIR}/claude.json" "${CLAUDE_JSON}" || true
fi

# ----- Claude: settings.json default ---------------------------------------
# If the user has no settings.json yet, drop a minimal one pointing at the
# right model defaults. Don't overwrite an existing one.
if [[ ! -f "${CLAUDE_DIR}/settings.json" ]]; then
  step "write default settings.json" tee "${CLAUDE_DIR}/settings.json" >/dev/null <<'JSON' || true
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json"
}
JSON
fi

echo "wellmade: container post-create complete."
