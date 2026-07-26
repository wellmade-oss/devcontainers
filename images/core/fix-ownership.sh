#!/usr/bin/env bash
# Ownership self-heal for /home/wm — runs on EVERY container start (wired to
# devcontainer.json postStartCommand) and also at the top of postcreate.sh.
#
# Why every start: the launcher (devcon / VS Code) aligns wm's uid/gid to the
# host — including re-owning /home/wm — as a per-START action. When that
# alignment is skipped or times out, wm stays at its baked uid while $HOME and
# everything under it (the persisted volumes ~/.claude, ~/.ssh, … AND plain
# home files like ~/.zsh_history, ~/.zshrc, caches) stay owned by the HOST uid
# from a previous aligned run. wm then can't write any of it:
#   - ~/.claude       → Claude auth won't persist → re-login every rebuild
#   - ~/.zsh_history  → "zsh: locking failed … permission denied" on exit
#   - dotfiles/caches → assorted permission-denied failures
#
# postCreateCommand fires only on CREATE, so it can't catch a mismatch that
# appears on a plain start of an already-created container — hence this also
# runs from postStartCommand.
#
# Fix: if $HOME isn't owned by us, take the whole tree back with passwordless
# sudo (available in the image). Idempotent; the `-O $HOME` test makes it a
# no-op in the normal aligned case, so the cost of re-chowning large caches
# (~/.vscode-server) is only paid on the mismatch path. This does NOT fix the
# launcher — see docs/uid-gid-alignment.md — it just keeps a uid hiccup from
# wrecking the container's writable state.

set -uo pipefail

if [[ ! -O "${HOME}" ]]; then
  echo "wellmade: ${HOME} not owned by $(id -un) — self-healing ownership of \$HOME" >&2
  if sudo chown -R "$(id -u):$(id -g)" "${HOME}"; then
    echo "wellmade: ownership self-heal complete." >&2
  else
    echo "wellmade: WARNING — ownership self-heal failed (continuing)" >&2
  fi
fi
