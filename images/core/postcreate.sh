#!/usr/bin/env bash
# Container-first-start setup. Runs after volume mounts are in place, so
# anything that needs to live alongside persisted state goes here — NOT
# in the Dockerfile, where volume mounts would shadow it.
#
# Idempotent: safe to re-run on rebuilds, no-op when state already exists.

set -euo pipefail

ATELIER_AI_SKILLS=/opt/wellmade/atelier-ai/skills
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_JSON="${HOME}/.claude.json"

# ----- Claude: skills symlink ------------------------------------------------
# The atelier-ai skills live in the image. The ~/.claude volume mount would
# shadow a Dockerfile-built symlink, so we recreate it here on every create.
# -fn replaces an existing symlink without descending into it.
if [[ -d "${ATELIER_AI_SKILLS}" ]]; then
  mkdir -p "${CLAUDE_DIR}"
  ln -sfn "${ATELIER_AI_SKILLS}" "${CLAUDE_DIR}/skills"
fi

# ----- Claude: ~/.claude.json persistence -----------------------------------
# Claude Code stores its user-level global config (OAuth, MCP) at $HOME/.claude.json,
# OUTSIDE the ~/.claude/ directory. That file would be lost on rebuild because
# only ~/.claude/ is mounted as a volume. Symlink it INTO the volume so it
# persists alongside everything else.
if [[ ! -L "${CLAUDE_JSON}" ]]; then
  # First create: if the file already exists (newly-installed image with a
  # freshly populated claude.json), move it into the volume before symlinking.
  if [[ -f "${CLAUDE_JSON}" ]]; then
    mv "${CLAUDE_JSON}" "${CLAUDE_DIR}/claude.json"
  fi
  # Create the symlink if the target either exists (re-using a primed volume)
  # or doesn't (claude will create it on first auth, into the volume).
  ln -sfn "${CLAUDE_DIR}/claude.json" "${CLAUDE_JSON}"
fi

# ----- Claude: settings.json default ---------------------------------------
# If the user has no settings.json yet, drop a minimal one pointing at the
# right model defaults. Don't overwrite an existing one.
if [[ ! -f "${CLAUDE_DIR}/settings.json" ]]; then
  cat > "${CLAUDE_DIR}/settings.json" <<'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json"
}
JSON
fi

echo "wellmade: container post-create complete."
