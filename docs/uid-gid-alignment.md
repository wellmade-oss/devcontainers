# UID/GID alignment in Wellmade dev containers — research notes

**Status: RESOLVED — no image change needed.** The images stay standard
(bake `USER_UID=1000`, let the launcher's `updateRemoteUserUID` do the
alignment). No fixuid, no runtime-chown baked in.

**Root cause (confirmed):** the launcher on the affected host was
[`totophe/devcon`](https://github.com/totophe/devcon) — a VS-Code-free
devcontainer launcher — which parsed `devcontainer.json` but did **not**
implement `updateRemoteUserUID`, so the container user `wm` was never
remapped off its baked uid 1000. Host files (uid 1001) were therefore
unwritable. This was NOT an image bug: the image ships 1000 correctly
and expects the launcher to remap, exactly as VS Code / the official
`@devcontainers/cli` do.

**Fix (shipped):** `updateRemoteUserUID` support was added to `devcon`
and released in **v0.2.3** — confirmed working on the 1001 host. The fix
lives in the launcher, where it belongs; every image `devcon` runs
benefits, and the Wellmade images stay drop-in compatible with VS Code.

**Image-side mitigation (shipped 2026-07-26):** alignment can still be
*skipped* transiently — devcon logged `user-uid alignment timed out and
was skipped` on one connect. When that happens wm stays at uid 1000
while `$HOME` (and the persisted volumes + plain home files like
`~/.zsh_history`) are host-uid-owned from a prior aligned run, so wm
can't write them — symptoms were a failed `~/.claude/skills` symlink,
Claude re-auth every rebuild, and `zsh: locking failed … permission
denied` on shell exit. So the image now self-heals defensively:
- `images/core/fix-ownership.sh` — `sudo chown -R` `$HOME` back to us
  whenever `$HOME` isn't wm-owned (no-op otherwise). Wired to
  **`postStartCommand`** (runs every start, not just create) and also
  called at the top of `postcreate.sh`.
- `postcreate.sh` no longer runs `set -e`; each step is isolated so one
  failure warns instead of aborting — that abort was why the Claude-auth
  persistence step was being skipped.

This is mitigation, not the fix — the real cause (the timeout) is
devcon's, briefed separately.

The diagnostic and mechanism notes below are retained as reference for
the next time a uid/gid symptom shows up (e.g. a different launcher, a
CI runner, or rootless Docker).

**Date:** 2026-07-13 (resolved 2026-07-25; image mitigation 2026-07-26)

---

## The problem, concretely

`images/core/Dockerfile` bakes the container user:

```dockerfile
ARG USERNAME=wm
ARG USER_UID=1000
ARG USER_GID=${USER_UID}
```

`wm` is created as uid/gid **1000**. On a Linux host whose developer is
**not** uid 1000, bind-mounted paths come up owned by the host uid, and
`wm` (1000) can't write them.

**Live repro we actually hit:** Linux host, developer uid **1001**.
Bind-mounted project files land owned by 1001; `wm` is 1000; result is
write errors on the project inside the container.

This bites every bind mount, not just the workspace:

- the workspace at `/workspaces/${localWorkspaceFolderBasename}`
- `~/.ssh`, `~/.claude`, `~/.config/gh`, `~/.config/glab-cli` (named
  volumes — these inherit image-dir ownership on *first* attach, so
  they start correct, but a uid remap after the fact can desync them)
- in `workbench`: the bind-mounted host Docker socket
  `/var/run/docker.sock` (its own gid problem — separate but related)

macOS hosts don't feel this (Docker Desktop's VM handles uid
translation), which is why it's a Linux-host-specific bug. The
developer who hit it is on Linux.

---

## Diagnose first — we don't yet know the root cause

"Write errors on the project" has at least four distinct root causes,
each with a DIFFERENT fix. Do not pick a fix until the diagnostic below
tells you which row you're in.

| Root cause | Tell | Fix belongs on |
|------------|------|----------------|
| `updateRemoteUserUID` never fired | `id` inside container shows **1000**, not the host uid | host / tooling |
| It fired but a half-remap happened (HOME not re-chowned) | `id` shows host uid, but `~` is still 1000/root-owned | devcontainer.json (config) |
| Rootless Docker / userns-remap on the host | host files owned by a *high* uid (e.g. 100999) | host daemon config |
| Named-volume state dir stranded at 1000 from a prior run | workspace writable, but `~/.claude` (etc.) fails | one-time volume chown |

Note the split that matters most: **is the failing path the workspace
(`/workspaces/…`, a bind mount) or a state volume (`~/.claude`,
`~/.config/gh`, a named volume)?** They point at different rows.

### Diagnostic block — run INSIDE the running container on the 1001 host

```bash
# 1. Who does the container think we are? If this says 1000 (not the
#    host's 1001), updateRemoteUserUID did NOT fire — that's the whole bug.
id

# 2. Is HOME actually owned by us?
ls -ldn "$HOME" "$HOME/.claude" 2>/dev/null

# 3. Who owns the workspace (the bind mount)?
ls -ldn /workspaces/* 2>/dev/null

# 4. Can we actually write each place? (exit 0 = writable)
touch /workspaces/*/.__wtest 2>&1 && rm -f /workspaces/*/.__wtest && echo "workspace: WRITABLE"
touch "$HOME/.claude/.__wtest" 2>&1 && rm -f "$HOME/.claude/.__wtest" && echo "~/.claude: WRITABLE"

# 5. Rootless / userns-remap check: a HIGH owner uid on a host file
#    (100000+) means the daemon is remapping — a host-side concern.
stat -c '%u %g %n' /workspaces/*/* 2>/dev/null | head
```

### Reading it

- **`id` shows 1000** → `updateRemoteUserUID` isn't taking effect. Most
  likely the container is driven by something other than a local VS
  Code / `devcontainer` CLI running as the host user (remote host,
  pre-pulled image, plain `docker run`). Fix on the **host/tooling**
  side — this is NOT an image bug.
- **`id` shows 1001 but writes still fail** → the remap happened but a
  path is stranded. If it's a *state volume*, it's a one-time
  `sudo chown -R wm ~/.claude …` (sudo is passwordless in the image);
  if it's HOME broadly, look at the `remoteUser`/`containerUser` combo.
- **Owner uid is 100000-ish** → rootless Docker or userns-remap on the
  host. Purely a host daemon concern; the image can't and shouldn't
  fix it.

Until this is run, everything below is options, not a decision.

---

## Why "just bake a different USER_UID" is the wrong lever

Hardcoding `USER_UID=1001` fixes exactly one host and breaks the next
one (1000, 1002, macOS, CI). The image is shared across developers and
CI; the host uid is not knowable at build time. We want **alignment to
whatever the host is**, not a second hardcoded guess.

So the fix has to be dynamic — resolved per host, at build-or-start
time, not baked.

---

## The two mechanisms (and the key misconception to avoid)

There are two distinct tools. They are **complementary**, and neither
alone is obviously sufficient. The trap is thinking either one "stat's
the workspace and figures out the host uid." **Neither does that.**

### 1. `updateRemoteUserUID` (VS Code / devcontainer spec, built-in)

- devcontainer.json property. **Defaults to `true`.**
- When `remoteUser` or `containerUser` is set (ours sets both to `wm`),
  VS Code, on Linux, remaps the container user's uid/gid to match the
  **host user running the Dev Containers client**.
- Mechanism: it derives an extra image layer at up-time that `usermod`s
  the target user and `chown`s that user's HOME to the host uid/gid.
- **Important:** it does **not** re-own arbitrary pre-existing
  bind-mounted files. It doesn't need to — once `wm` *becomes* 1001,
  the host's already-1001-owned files are writable by definition. What
  it fixes is *the container user's identity*, not the files.

**Open question / suspected gap:** our devcontainer.json already sets
`remoteUser: wm` + `containerUser: wm`, so `updateRemoteUserUID` should
already be firing by default — yet the 1001 host still had write
issues. Candidate explanations to verify:

- We consume a **prebuilt image** (`image: ghcr.io/...:v1`), not a
  local `build.dockerfile`. `updateRemoteUserUID` still works on a
  pulled image, but via an at-up-time derived layer; that path may be
  less thorough / may not have taken effect as expected.
- The remap chowns HOME but the **named-volume state** dirs
  (`~/.claude`, `~/.config/gh`, …) were populated on a *previous* run
  at uid 1000 and didn't get re-chowned, so writes to those failed
  while the workspace itself was fine — or vice versa. Need to pin down
  *which* path actually threw the write error.
- Some interaction with `containerUser` vs `remoteUser` we haven't
  isolated. (`containerUser` = every process; `remoteUser` = the tools
  VS Code launches. Setting both is belt-and-suspenders but worth
  confirming it's not causing a half-remap.)

**We must reproduce and read the actual error before choosing.** "Write
issue on the project" vs "write issue on ~/.claude" point at different
fixes.

### 2. `fixuid` (boxboat/fixuid, runtime binary)

- A setuid-root binary installed in the image. Run *as the container
  user* at container start.
- Mechanism: reads the uid/gid **the container process is already
  running as** (i.e. whatever `docker run -u <uid>:<gid>` — or the
  devcontainer remap — set it to), then rewrites `/etc/passwd`,
  `/etc/group`, and re-owns files that were owned by the *old* baked
  uid/gid to the *new* running uid/gid.
- **Crucial:** fixuid does **not** discover the host uid on its own. It
  needs the container to *already be running as* the host uid (via `-u`
  or via `updateRemoteUserUID`). Given that, fixuid makes the internal
  user database coherent: valid passwd entry, HOME owned correctly,
  sudo still works, old 1000-owned files re-owned to 1001.
- Install shape (v0.6.0): download tarball → `/usr/local/bin/fixuid`,
  `chown root:root`, `chmod 4755` (setuid), write
  `/etc/fixuid/config.yml` with `user: wm` / `group: wm`.
- Release assets use `amd64`/`arm64` — matches `dpkg
  --print-architecture` directly, no remap needed (same as scw/mkcert).
- Renovate-trackable: `# renovate: datasource=github-releases
  depName=boxboat/fixuid`. Asset filename drops the `v` (`fixuid-0.6.0-…`)
  while the git tag has it (`v0.6.0`); the existing customManager regex
  already tolerates the optional `v`.

**Invocation under devcontainers:** the fixuid README's `ENTRYPOINT
["fixuid"]` is unreliable here because devcontainer.json overrides
ENTRYPOINT/CMD and keeps the container alive itself. The reliable hook
is `eval "$(fixuid -q)"` at the **top of `postcreate.sh`**, before it
does its symlink/chown work (fixuid re-owns HOME, so it must run
first). But — see below — this only helps *if the container is already
running as the host uid*.

### How they compose

```
updateRemoteUserUID  →  gets the container RUNNING AS the host uid (1001)
fixuid               →  reconciles the internal user DB + re-owns old
                        1000-owned files to 1001, so the now-1001 wm is
                        coherent (passwd entry, HOME, sudo)
```

fixuid **without** a uid override (or without `updateRemoteUserUID`
actually taking effect) runs as the baked 1000, sees nothing to change,
and does nothing for the 1001 host. That's the single most important
finding: **fixuid alone was not going to fix the reported bug.** The
half that gets the container running as 1001 has to be present too.

---

## Candidate solutions

Ordered by preference. The image should stay standard, so **host/config
options (A, D) are preferred; image-mutating options (B, C) are
fallbacks** only if the diagnostic proves alignment can't be achieved
without them.

| # | Approach | Where | Fixes uid≠1000? | Notes |
|---|----------|-------|-----------------|-------|
| A | Rely on `updateRemoteUserUID` default; fix the *host/tooling* so it fires | host | Should, in theory | It's *already* on. If `id` shows 1000, the container isn't being driven by a local VS Code/CLI as the host user — fix that, not the image. **Preferred.** |
| D | Test `remoteUser` only vs both `remoteUser`+`containerUser` | config | Maybe | Cheap experiment: does setting both cause a half-remap? Config change, not an image change. |
| —  | One-time `sudo chown -R wm <path>` for a stranded state volume | runtime | Yes, for that path | If diagnostic shows a *volume* stranded at 1000 while `id` is correct. sudo is passwordless in the image. Not a code change — an ops step. |
| B | `fixuid` in postcreate + host uid passed in | **image** | Yes | Belt-and-suspenders, but this is the "make the image less pure" path we're trying to avoid. Only if A/D can't be made to work. Needs the container already running as the host uid. |
| C | Explicit `chown` of workspace/volumes in postcreate | **image** | Yes, brute-force | Slow on large trees, heavy-handed, mutates the standard image. Last resort. |

**Current lean:** keep the image standard. Run the diagnostic; expect
to land in row A (host/tooling) or the one-time-chown row. Reach for B/C
only if the environment genuinely can't deliver `updateRemoteUserUID`
(e.g. a fixed non-VS-Code runner) AND that constraint is permanent.

---

## What to nail down before writing any code

1. **Reproduce** on the 1001 host and capture the **exact** failing
   path + error (workspace? a named-volume state dir? the docker
   socket?). This decides everything.
2. **Consumption mode:** do we pull `ghcr.io/wellmade-oss/dc-*:v1`
   (prebuilt) or build locally via `build.dockerfile`? Affects how
   thoroughly `updateRemoteUserUID` remaps.
3. **Is `updateRemoteUserUID` actually firing?** Inside the container,
   `id` should report the host uid (1001), not 1000, if it worked.
   Check before assuming it's broken.
4. **Named-volume desync:** the state volumes are chowned to 1000 at
   image-build time and copied on first attach. If the user is remapped
   to 1001 afterward, those dirs may be stranded at 1000. This is a
   likely culprit distinct from the workspace itself.
5. **Docker socket gid** (workbench only): a separate axis — the
   mounted `/var/run/docker.sock` has the host's `docker` gid, which
   won't match the container's. Track separately; don't conflate with
   the user-uid problem.

## Where the fix will live (once decided)

**Preference: on the HOST, not in the image.** Keeping the image
standard (bake `USER_UID=1000`, let `updateRemoteUserUID` align it) is
the mainstream devcontainer contract and what Microsoft's images do.
The 1001 write errors most likely mean the *environment* isn't letting
`updateRemoteUserUID` fire, not that the image is wrong — the
diagnostic above will confirm.

*If* a code fix ever proves unavoidable (row B/C — only after A/D are
ruled out), it belongs in **`core`**, not `workbench`: the `wm` user,
the workspace mount, and the state volumes all originate in the base,
so fixing `core` means `workbench` (`FROM core`) inherits it. But the
whole point of the host-first stance is to not go there.

## References

- boxboat/fixuid — https://github.com/boxboat/fixuid (v0.6.0 latest as
  of 2026-07-13)
- devcontainer.json reference (`updateRemoteUserUID`, `remoteUser`,
  `containerUser`) — https://containers.dev/implementors/json_reference/
- Current image: `images/core/Dockerfile` (user setup at the
  `# --- user setup ---` block), `images/core/postcreate.sh`,
  `images/core/devcontainer.json` (mounts + `remoteUser`/`containerUser`).
