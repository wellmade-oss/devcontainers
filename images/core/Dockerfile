# syntax=docker/dockerfile:1.25
#
# wellmade-oss/dc-core
#
# Agent-ready Debian-slim base. No language runtimes, no cloud CLIs.
# Every Wellmade devcontainer image extends this one.

ARG DEBIAN_VERSION=bookworm
FROM debian:${DEBIAN_VERSION}-slim

ARG USERNAME=wm
ARG USER_UID=1000
ARG USER_GID=${USER_UID}

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC \
    SHELL=/bin/zsh \
    WELLMADE_DC=1

# --- system layer ---------------------------------------------------------
# One apt pass: base utilities, build tools, db clients, shells.
# These float at the Debian-stable version; the weekly cron rebuild
# pulls in upstream apt patches. (Dependabot tracks the FROM base image
# and GitHub Actions; the URL-pinned ARG binaries below are tracked by
# Renovate — see renovate.json.)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release apt-transport-https \
      git openssh-client \
      zsh \
      vim \
      sudo \
      build-essential pkg-config \
      jq ripgrep fd-find tree less procps file \
      unzip zip xz-utils \
      postgresql-client sqlite3 \
      python3 python3-pip python3-venv \
      locales tzdata \
 && locale-gen C.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

# yq (Go binary, not in Debian stable yet at a recent version)
# renovate: datasource=github-releases depName=mikefarah/yq
ARG YQ_VERSION=4.53.3
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq

# GitHub CLI (apt repo)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# GitLab CLI (glab) — EU shops use it.
# Tarball + install is more robust than .deb (no dpkg state, same flow on
# any glibc Linux). dpkg --print-architecture already returns amd64/arm64,
# which is exactly what glab's filenames use.
# renovate: datasource=gitlab-releases depName=gitlab-org/cli
ARG GLAB_VERSION=1.107.0
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${ARCH}.tar.gz" \
      | tar -xz -C /tmp \
 && install -m 0755 /tmp/bin/glab /usr/local/bin/glab \
 && rm -rf /tmp/bin

# fd-find ships as `fdfind` on Debian — alias to the expected name
RUN ln -sf "$(which fdfind)" /usr/local/bin/fd

# --- user setup -----------------------------------------------------------
RUN groupadd --gid ${USER_GID} ${USERNAME} \
 && useradd --uid ${USER_UID} --gid ${USER_GID} --shell /bin/zsh -m ${USERNAME} \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
 && chmod 0440 /etc/sudoers.d/${USERNAME}

# --- shell: zsh + oh-my-zsh ----------------------------------------------
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Install oh-my-zsh for plugin ecosystem + sensible defaults, then
# disable its theme — we drive the prompt entirely from starship below.
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
 && sed -i 's|^ZSH_THEME=.*|ZSH_THEME=""|' /home/${USERNAME}/.zshrc

# --- prompt: starship ----------------------------------------------------
# starship is a fast, cross-shell prompt configured via TOML. We use it
# to render the locked Wellmade prompt design (see starship.toml for the
# full spec). The `[dc]` indicator that marks "you're inside a Wellmade
# dev container" lives inside starship.toml as a custom module gated on
# the WELLMADE_DC env var the Dockerfile sets above.
USER root
RUN curl -fsSL https://starship.rs/install.sh \
      | sh -s -- --yes --bin-dir /usr/local/bin
USER ${USERNAME}

# Drop the prompt config into the user's XDG config dir, then append
# starship's init hook to .zshrc so it activates on every shell. The
# .config dir doesn't exist yet (oh-my-zsh's install didn't create it).
RUN mkdir -p /home/${USERNAME}/.config
COPY --chown=${USER_UID}:${USER_GID} starship.toml /home/${USERNAME}/.config/starship.toml
RUN cat <<'STARSHIP_INIT' >> /home/${USERNAME}/.zshrc

# starship prompt — config in ~/.config/starship.toml
eval "$(starship init zsh)"
STARSHIP_INIT

# --- node (convenience runtime + npm for ad-hoc agent use) ---------------
# Both agents below are native binaries that do NOT need Node (OpenCode and
# Claude each install standalone). Node is kept here deliberately anyway: it
# gives agents `npm`/`npx` out of the box and hedges future core-level
# tooling, at the cost of some image size — a conscious trade, not a
# dependency. core is NOT a Node dev image; the `workbench` image installs
# its own Node LTS toolchain on top.
# Node 24 (Krypton) is the current Active LTS as of 2026-05.
USER root
ARG NODE_MAJOR=24
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g npm@latest

# --- agent layer: OpenCode + Claude + wm + atelier-ai --------------------
# Every Wellmade image is agent-ready by default, and deliberately
# agent-AGNOSTIC — we ship two agents:
#   - OpenCode  — the baseline. Model-agnostic (Anthropic, OpenAI, Gemini,
#                 local Ollama, …), MIT, headless `opencode run` mode for
#                 CI/scripting, pairs with a self-hosted local model on a
#                 homelab box. This is the floor every image guarantees.
#   - Claude    — the accessory we reach for. Not model-agnostic, but its
#                 capabilities earn its place: atelier-ai's skills, hooks
#                 and AGENTS.md templates are built for it.
#
# Both install as native binaries into the wm user's home — OpenCode into
# ~/.opencode/bin, Claude into ~/.local/bin — neither on PATH by default.
# Put both on PATH for every shell (login + non-interactive) up front, and
# pass --no-modify-path to the installers so they don't also edit rc files.
ENV PATH=/home/${USERNAME}/.opencode/bin:/home/${USERNAME}/.local/bin:${PATH}

# OpenCode (https://opencode.ai, github.com/anomalyco/opencode) via its
# official native installer — a prebuilt binary (picks an AVX2-optimized
# variant where available), no Node needed, into ~/.opencode/bin. Pinned via
# VERSION= for reproducible builds. Installed as the wm user so it lands in
# their home; --no-modify-path because PATH is managed by the ENV above.
#
# Renovate tracks GitHub releases on anomalyco/opencode directly — that's
# Anomaly's repo, where the installer actually pulls binaries from, and the
# authoritative source of truth. We deliberately do NOT track the npm
# `opencode-ai` package: after the Anomaly/Charm naming split, the other
# camp registered confusingly-named packages, so pinning to the repo (not a
# package name) keeps the version feed from ever drifting to the wrong
# project. (As of writing both report 1.17.11 — same lineage, same version.)
# renovate: datasource=github-releases depName=anomalyco/opencode
ARG OPENCODE_VERSION=1.17.11
USER ${USERNAME}
RUN curl -fsSL https://opencode.ai/install | VERSION="${OPENCODE_VERSION}" bash -s -- --no-modify-path
USER root

# Claude Code via the official native installer (the recommended path —
# self-contained binary into ~/.local/bin, no Node needed). Pinned to a
# specific version rather than the rolling channel for reproducible builds;
# the binary still background-auto-updates per user at runtime. Installed as
# the wm user so it lands in their home (~/.local/bin, already on PATH above).
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.195
USER ${USERNAME}
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}"
USER root

# wm CLI: design-phase repo, no published binary yet. Placeholder install
# step kept as a comment until the first wm release ships.
# RUN curl -fsSL https://wellmade.be/wm/install.sh | sh

# atelier-ai skills: cloned to a stable system path. The
# ~/.claude/skills symlink is NOT created at build time — devcontainer.json
# mounts a volume on ~/.claude/, which would shadow it. postcreate.sh
# recreates it inside the volume on first container start.
# atelier-ai still lives under wellmade-studio — it hasn't migrated to the
# wellmade-oss org yet. Kept as an ARG so the move is a one-line flip (or a
# build-time override) once wellmade-oss/atelier-ai exists.
ARG ATELIER_AI_ORG=wellmade-studio
ARG ATELIER_AI_REF=main
RUN git clone --depth=1 --branch "${ATELIER_AI_REF}" \
      https://github.com/${ATELIER_AI_ORG}/atelier-ai.git \
      /opt/wellmade/atelier-ai

# Container lifecycle script invoked by devcontainer.json postCreateCommand.
COPY postcreate.sh /opt/wellmade/bin/postcreate.sh
RUN chmod +x /opt/wellmade/bin/postcreate.sh \
 && chown -R ${USERNAME}:${USERNAME} /opt/wellmade

# Pre-create the directories that devcontainer.json volume-mounts onto.
# When Docker first attaches an empty named volume, it copies the image's
# directory contents (including ownership) into the volume — so getting
# ownership right HERE means the volume comes up wm-owned.
RUN mkdir -p /home/${USERNAME}/.config/gh \
             /home/${USERNAME}/.config/glab-cli \
             /home/${USERNAME}/.claude \
             /home/${USERNAME}/.ssh \
 && chmod 700 /home/${USERNAME}/.ssh \
 && chown -R ${USER_UID}:${USER_GID} /home/${USERNAME}

USER ${USERNAME}
WORKDIR /home/${USERNAME}

CMD ["zsh", "-l"]
