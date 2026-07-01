# Wellmade devcontainers

Self-rooted dev container images for the Wellmade toolchain.
Two images, agent-ready by default, EU-cloud bias.

Published to [`ghcr.io/wellmade-oss/dc-*`](https://github.com/orgs/wellmade-oss/packages?repo_name=devcontainers).

## The images

### `core` — agent-ready base

```
ghcr.io/wellmade-oss/dc-core:v1
```

Debian-slim with the agent layer preinstalled: Claude CLI,
atelier-ai skills, and the `wm` CLI. Plus standard system tools
(git, gh, glab, jq, yq, ripgrep, fd, postgres + sqlite clients,
build-essential). Zsh + Oh My Zsh. User `wm` with passwordless
sudo.

No language runtimes, no cloud CLIs. Extend this image if you
need a thinner, more focused container than `workbench`.

### `workbench` — daily driver

```
ghcr.io/wellmade-oss/dc-workbench:v1
```

`FROM core`. The image you reach for unless you have a reason
not to.

- **Node LTS** + npm + Turborepo + `@wellmade/*` lint stack
- **Python 3** + uv + pipx + ruff + mypy + pytest + ipython
- **Rust stable** via rustup + cargo + clippy + rustfmt
- **Scaleway CLI** (EU-cloud default)
- **Ansible** (IaC)
- **1Password CLI**
- **`act`** for local GitHub Actions runs (needs host Docker
  socket — devcontainer.json mounts it)
- **kubectl + helm**

## Usage

Drop one of the [`devcontainer.json` templates](./images) into
your project's `.devcontainer/` directory:

```bash
mkdir -p .devcontainer
cp /path/to/devcontainers/images/workbench/devcontainer.json .devcontainer/
```

Or use [`wm devcontainer`](../cli/) when it lands — it picks the
right image from `catalog.toml` and writes the template for you.

## Persisted state

Both images mount named Docker volumes so credentials and project state
survive container rebuilds. The naming convention signals reset-tolerance:

| Prefix | Contents | Safe to `docker volume prune`? |
|--------|----------|--------------------------------|
| `wellmade-state-*` | Credentials, auth, project history (Claude, gh, glab, ssh, scw, op, kube) | **No** — you'd lose logins |
| `wellmade-cache-*` | Build caches (cargo registry, etc.) | Yes — costs a cold install |

On first start, `/opt/wellmade/bin/postcreate.sh` (idempotent) wires up:

- `~/.claude/skills` → `/opt/wellmade/atelier-ai/skills` (recreated inside
  the mounted volume so it isn't shadowed by the volume mount)
- `~/.claude.json` → symlink into `~/.claude/` so the home-root file
  persists alongside everything else Claude needs

Loss-on-rebuild items (deliberately not persisted, to keep volume count
small): `~/.gitconfig`, `~/.zsh_history`, npm/uv caches. Add a volume if
you need them.

## Versioning

- `:latest` — newest build of `main`
- `:v1` — rolling major-version pin. Picks up every minor /
  patch automatically (including Node LTS bumps). Use this in
  long-lived projects.
- Breaking changes → `:v2`. Should be rare.

Updates flow from:

1. **Dependabot** — base image digests + pinnable deps, weekly.
2. **Weekly cron rebuild** — pulls upstream apt / npm / pip
   patches even when no commit happened.

## Design opinions

See [`CLAUDE.md`](./CLAUDE.md) for the full design rationale.
The short version:

- Self-rooted, not Microsoft-extended.
- Two tiers, not five. Add more only when a real scenario asks.
- Agent-ready at the base — Claude CLI in every image.
- EU-cloud bias (Scaleway, not GCP/AWS, in the defaults).
- No combinatorial variants.
- No Docker-in-Docker (host socket mount only).
- No OpenTofu / Pulumi (Ansible only).
- npm + Turborepo only (no pnpm, no yarn).

Inspired by [`totophe/dc-toolbelt`](https://github.com/totophe/dc-toolbelt),
simplified hard.

## License

MIT. © Wellmade.
