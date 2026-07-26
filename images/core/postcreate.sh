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
# The launcher (e.g. devcon / VS Code) is supposed to align wm's uid/gid to the
# host before we run. If that alignment is skipped or times out, wm stays at
# its baked uid while the persisted ~/.claude volume is owned by the HOST uid
# from a previous successful run — every write below then fails "Permission
# denied", which also breaks Claude auth persistence and re-prompts login.
#
# Defend against that here: if ~/.claude exists but isn't owned by us, take it
# back with passwordless sudo (available in the image). Cheap, idempotent, and
# a no-op in the normal aligned case. This does NOT fix the launcher — see
# docs/uid-gid-alignment.md — it just keeps a uid hiccup from wrecking the
# container's writable state.
if [[ -e "${CLAUDE_DIR}" && ! -O "${CLAUDE_DIR}" ]]; then
  echo "wellmade: ${CLAUDE_DIR} not owned by $(id -un) — self-healing ownership" >&2
  step "chown ~/.claude" sudo chown -R "$(id -u):$(id -g)" "${CLAUDE_DIR}" || true
fi

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
