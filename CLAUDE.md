# devcontainers/

This folder is the **just-created** sibling repo
`wellmade-oss/devcontainers`. It will hold Wellmade's curated
dev container images, published to
`ghcr.io/wellmade-oss/dc-*`.

If you're Claude Code reading this, the situation is:

1. **Empty repo, by design.** Image work hasn't started yet.
2. **Design lineage:** inspired by [`totophe/dc-toolbelt`](https://github.com/totophe/dc-toolbelt) —
   a layered family of self-rooted images, not thin shims over
   Microsoft's `mcr.microsoft.com/devcontainers/*`. We keep the
   layered idea and simplify the opinions hard.
3. **Consumer:** the [`wm` CLI's](../cli/) `wm devcontainer`
   command, which picks the right image from this catalog at
   wizard time. See [`cli/docs/case-studies.md`](../cli/docs/case-studies.md)
   scenario 10 and [`cli/docs/architecture.md`](../cli/docs/architecture.md)'s
   `wm devcontainer` section.

## Core opinions

- **Self-rooted, not Microsoft-extended.** Base is plain
  `debian:bookworm-slim` with our own user, shell, and sudo
  setup. We borrow good ideas from
  `mcr.microsoft.com/devcontainers/*` (non-root user with sudo,
  cached VS Code server) — but we don't inherit from them. The
  independence is a feature: predictable size, predictable
  upgrade cadence, no surprise tooling.
- **Two tiers, not five.** A `core` agent-ready base and a single
  `workbench` daily-driver image. Add more only when a real
  scenario demands it.
- **European providers by default.** When a cloud CLI ships,
  prefer Scaleway over GCP/AWS/Azure. OVH, Hetzner are
  candidates if needs arise. Non-EU CLIs aren't banned — they go
  in opt-in variants when a customer needs them — but the
  *defaults* and the *flagship images* lean European.
- **Agent-ready — and agent-agnostic — at the base.** Two agents
  live in `core`: **OpenCode** (the model-agnostic baseline —
  Anthropic, OpenAI, Gemini, local Ollama; MIT; headless
  `opencode run` for CI) and **Claude** (the accessory we reach
  for; not model-agnostic, but atelier-ai's skills/hooks/templates
  are built for it). Plus atelier-ai skills + the `wm` CLI. Every
  image is agent-ready out of the box without being locked to one
  agent. Both install as native binaries via their official
  installers (no Node needed); core keeps Node anyway as a
  convenience runtime, not an agent dependency. OpenCode here means
  Anomaly's project (opencode.ai / `anomalyco/opencode`) — pinned
  to that repo's releases, deliberately not the npm package name,
  after the Anomaly/Charm naming split.
- **No combinatorial variants.** No `workbench-aws`,
  `workbench-gcloud`. Customers who need a different cloud reach
  for `workbench` and add the CLI via a per-project Dockerfile.

## The tiers

```
core                 (agent-ready Debian-slim base)
└── workbench        (daily driver: Node + Python + Rust + Scaleway + Ansible + 1Password + act)
```

That's it. Two images at launch.

### `core`

`FROM debian:bookworm-slim`. Agent-ready base.

- User `wm` with passwordless sudo. **Zsh + Oh My Zsh**
  (robbyrussell theme).
- System: `git`, `gh`, `glab`, `curl`, `wget`, `ca-certificates`,
  `gnupg`, `jq`, `yq`, `ripgrep`, `fd-find`, `tree`, `less`,
  `procps`, `build-essential`, `unzip`, `zip`, `xz-utils`,
  `postgresql-client`, `sqlite3`, `vim`.
- **Agent layer**: **OpenCode** (model-agnostic baseline) +
  **Claude** (native install), **atelier-ai** skills (stable
  install path; `.claude/` skel'd into new user homes), **`wm`
  CLI**, all on PATH.
- **Not in core**: no language runtimes, no cloud CLIs, no IaC
  tooling, no Docker / Docker-in-Docker.

### `workbench`

`FROM core`. The image you reach for unless you have a specific
reason not to.

**Languages:**
- **Node.js at current LTS** (floor — never below). **npm only**
  (npm + npm workspaces + Turborepo). No pnpm, no yarn.
  Preinstalled globally: Turborepo, `tsx`, `npm-check-updates`,
  and the Wellmade lint stack (`@wellmade/eslint-config`,
  `@wellmade/prettier-config`, `@wellmade/stylelint-config` +
  their peer deps `eslint`, `prettier`, `stylelint`,
  `typescript`).
- **Python 3** (latest stable). Agents reach for Python tools
  constantly, so this tier ships them:
  - **uv** — fast resolver, the agent-friendly default
  - **pipx** — clean global CLI installs
  - **ruff** — lint + format
  - **mypy** — type checking
  - **pytest** + `pytest-cov`
  - **ipython** — one-off exploration
  - `pip` / `venv` available as fallbacks
- **Rust stable via rustup** — `cargo`, `rustc`, `rustfmt`,
  `clippy`, plus `cargo-watch` and `cargo-edit`.

**Cloud + IaC + secrets (folded in, no separate cloud variant):**
- **Scaleway CLI** (`scw`) — the EU-cloud default
- **Ansible** (`ansible-core`) — Wellmade's IaC tool of choice
- **1Password CLI** (`op`)

**CI tooling:**
- **`act`** ([nektos/act](https://github.com/nektos/act)) — runs
  GitHub Actions workflows locally in containers. Imperfect
  runner emulation but covers ~80% of CI debugging without
  pushing a "fix CI" commit. **Needs the host Docker socket
  mounted into the container** (NOT Docker-in-Docker — see
  below); the devcontainer.json template documents the mount.

**Docker client:** `docker-ce-cli` + `docker-buildx-plugin` +
`docker-compose-plugin` (Compose v2, invoked as `docker
compose` — the plugin, not the legacy v1 python `docker-compose`
script). Client only, no daemon — everything drives the mounted
host socket, same as `act`. These come straight from Docker's apt
repo (`download.docker.com`), so `apt upgrade` / the weekly
rebuild keep them current; no pinned ARG to Renovate-track.

**Local dev extras:**
- **`acl`** (apt) — ships `setfacl`/`getfacl` for fine-grained
  permission handoffs (sharing the mounted docker socket /
  volumes without host-file chowns).
- **`mkcert`** ([FiloSottile/mkcert](https://github.com/FiloSottile/mkcert)) —
  locally-trusted dev certificates, no browser CA warnings on
  `https://localhost`. Go binary from GitHub releases, pinned +
  Renovate-tracked like act/zellij.

**Kubernetes:** `kubectl` + `helm` ship by default. Small
footprint, common enough to justify.

**Terminal multiplexer:** **`zellij`**
([zellij-org/zellij](https://github.com/zellij-org/zellij)) — Rust
binary, installed from GitHub releases (statically-linked musl
build, Renovate-tracked like the other pinned ARGs). Sessions
survive a dropped SSH/remote connection, which matters for long
agent runs on a remote box.

## Hard "don't"s

- **Don't ship Docker-in-Docker.** It misbehaves, especially
  when developers aren't on Docker Desktop. If a project needs
  Docker, mount the host socket from `devcontainer.json` and
  document it. Same applies to `act`.
- **Don't propose OpenTofu or Pulumi.** Deliberately out of the
  Wellmade stack — too risky, not resilient enough. Ansible is
  the IaC tool.
- **Don't propose pnpm or yarn.** npm + npm workspaces +
  Turborepo is the JS toolchain.
- **Don't propose UI libraries in default lint stacks.** The
  lint stack is the `@wellmade/*` configs and their peers only.
- **Don't bake a language into `core`.** Languages live in
  `workbench`.
- **Don't drop below Node LTS.** LTS is the floor; never narrow
  the range for older Node versions.
- **Don't scaffold image directories without a real stack to
  back them up.** Start with `core` and `workbench`. Add
  anything else only when a real consumer asks for it.

## Versioning + auto-update

- **`:latest`** — newest build of main, always.
- **`:v1`** — major version pin, gets every minor/patch
  automatically. When Node LTS bumps, `:v1` picks it up — that's
  the *point* of "almost always up to date."
- **No language-version suffixes** (no `:v1-node22`). dc-toolbelt
  used `node24-*` and the Node 25 day would mean renaming every
  image.
- **Breaking change → `:v2`.** Should be rare.

**Auto-update mechanism:**
- **Renovate** (`renovate.json`), run via the **Mend hosted
  GitHub App** — *not* a self-hosted CI runner. This is a public
  repo, so we deliberately keep any write-scoped token off our
  own CI surface; Mend holds its own credentials and runs the
  engine. The app is installed on `wellmade-oss`, scoped to
  this repo only. Renovate's customManager reads the `# renovate:`
  annotation above each tracked `ARG` (yq, glab, scw, act,
  mkcert, kubectl, helm + the OpenCode and Claude pins) and opens bump
  PRs weekly. `NODE_MAJOR` is deliberately excluded — it's a
  manual LTS floor, never auto-narrowed. The OpenCode pin tracks
  the `anomalyco/opencode` *repo releases*, not an npm package
  name (see the Dockerfile comment for why).
- **Dependabot** (`.github/dependabot.yml`) — GitHub-native,
  zero install. Originally added for the Docker `FROM` base image
  *and* GitHub Actions. **Heads-up / cleanup:** now that Renovate
  is active it also manages GitHub Actions, so Dependabot's
  `github-actions` entry overlaps and both will open PRs for the
  same Action bumps. Pick one owner for Actions (simplest: drop
  the `github-actions` block from `dependabot.yml` and let
  Renovate own it, leaving Dependabot to the `FROM` digests it's
  good at — or disable Renovate's actions manager instead).
- **Weekly cron rebuild** on the CI workflow so upstream apt /
  npm / pip patches flow through even when no Dockerfile commit
  happened.

## Likely layout when it lands

```
devcontainers/
├── README.md
├── images/
│   ├── core/                Dockerfile + devcontainer.json template
│   └── workbench/           Dockerfile + devcontainer.json template
├── catalog.toml             manifest read by `wm devcontainer`
└── .github/
    ├── workflows/
    │   ├── build.yml        build + push images on tag and on weekly cron
    │   └── catalog-validate.yml  catalog.toml stays in sync with images/
    └── dependabot.yml       base image digests + pinnable deps
```

Adding a future image should touch ~2 files (Dockerfile +
catalog entry), not five.

## What we keep from dc-toolbelt

- Layered FROM chain rooted at one base.
- Agents in the base, agent-ready by default (here: OpenCode +
  Claude, where dc-toolbelt shipped Claude alone).
- Zsh + Oh My Zsh.
- Templates paired with Dockerfiles.
- Named volumes for CLI state so credentials survive rebuilds.

## What we simplify

- **No combinatorial variants** (`python-scaleway`, etc.).
- **Language-agnostic core** — no Node baked into the base.
- **Adding an image touches ~2 files** (Dockerfile + catalog
  entry), not 5+.
- **Tags don't bake language versions.** `core:v1`, `workbench:v1`
  — never `workbench-node22-*`.
- **One specialized image at launch** instead of dc-toolbelt's
  thirteen.

## Relationship to other repos

- **`cli/`** — consumer. `wm devcontainer` reads `catalog.toml`
  from here at wizard time (fetched at runtime, pinned per `wm`
  release; see [`cli/docs/open-questions.md`](../cli/docs/open-questions.md)).
- **`atelier-ai/`** — preinstalled in `core` so any image is
  agent-ready. A future `devcontainer-conventions` skill is
  plausible but not committed.
- **`standards-js/`** — `workbench` preinstalls `@wellmade/eslint-config`
  etc. globally for fast cold starts. Optimization, not a hard
  dependency.
- **`bedrock-js/`** — no direct relationship. Customer projects
  install it themselves.
