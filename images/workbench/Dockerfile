# syntax=docker/dockerfile:1.25
#
# wellmade-oss/dc-workbench
#
# The daily driver. Node LTS + Python + Rust + Scaleway + Ansible
# + 1Password + act, on top of the agent-ready dc-core.

ARG CORE_TAG=v1
FROM ghcr.io/wellmade-oss/dc-core:${CORE_TAG}

USER root

# --- Node LTS toolchain ---------------------------------------------------
# core already ships Node (for Claude CLI). Workbench locks it to current
# LTS as the floor and adds the @wellmade lint stack + Turborepo.
# NODE_MAJOR is a deliberate manual floor, not auto-bumped: we move it by
# hand when a new Node LTS is adopted, never auto-narrow it (see CLAUDE.md
# "Don't drop below Node LTS"). That's why renovate.json skips this ARG.
# Node 24 (Krypton) is the current Active LTS as of 2026-05.
ARG NODE_MAJOR=24
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g npm@latest

# Global JS toolchain — npm + Turborepo only. No pnpm, no yarn.
RUN npm install -g \
      turbo \
      tsx \
      typescript \
      npm-check-updates \
      @wellmade/eslint-config \
      @wellmade/prettier-config \
      @wellmade/stylelint-config \
      eslint \
      prettier \
      stylelint

# --- Python tooling -------------------------------------------------------
# core already ships python3 + pip + venv. Workbench adds the agent-grade
# tooling: uv, pipx, ruff, mypy, pytest, ipython.
RUN curl -fsSL https://astral.sh/uv/install.sh | sh \
 && mv /root/.local/bin/uv /usr/local/bin/uv \
 && mv /root/.local/bin/uvx /usr/local/bin/uvx

# pipx (system-wide, then bin-symlinked) for global Python CLIs.
RUN python3 -m pip install --break-system-packages --no-cache-dir pipx \
 && python3 -m pipx ensurepath \
 && ln -sf /root/.local/bin/pipx /usr/local/bin/pipx || true

# Install ruff, mypy, pytest, ipython via pipx so each gets its own venv.
# Run as the wm user so the venvs live in their home.
USER wm
RUN python3 -m pipx install ruff \
 && python3 -m pipx install mypy \
 && python3 -m pipx install pytest \
 && python3 -m pipx install ipython
USER root

# --- Rust stable via rustup ----------------------------------------------
USER wm
ENV RUSTUP_HOME=/home/wm/.rustup \
    CARGO_HOME=/home/wm/.cargo \
    PATH=/home/wm/.cargo/bin:${PATH}

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile minimal -c rustfmt -c clippy \
 && cargo install cargo-watch cargo-edit
USER root

# --- Cloud + IaC + secrets -----------------------------------------------
# Scaleway CLI (EU-default). Asset names switched to amd64/arm64
# (used to be x86_64) — dpkg --print-architecture matches directly now.
# renovate: datasource=github-releases depName=scaleway/scaleway-cli
ARG SCW_VERSION=2.58.3
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL "https://github.com/scaleway/scaleway-cli/releases/download/v${SCW_VERSION}/scaleway-cli_${SCW_VERSION}_linux_${ARCH}" \
      -o /usr/local/bin/scw \
 && chmod +x /usr/local/bin/scw

# Ansible (core only — not the full collections bundle).
# acl: ships setfacl/getfacl — needed for fine-grained permission
# handoffs (e.g. sharing the mounted docker socket / mounted volumes
# across the wm user without chowning the host's files).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ansible-core acl \
 && rm -rf /var/lib/apt/lists/*

# 1Password CLI.
RUN curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
      | gpg --dearmor -o /usr/share/keyrings/1password-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
      > /etc/apt/sources.list.d/1password.list \
 && mkdir -p /etc/debsig/policies/AC2D62742012EA22/ \
 && curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol \
      -o /etc/debsig/policies/AC2D62742012EA22/1password.pol \
 && mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22 \
 && curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
      | gpg --dearmor -o /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg \
 && apt-get update \
 && apt-get install -y --no-install-recommends 1password-cli \
 && rm -rf /var/lib/apt/lists/*

# --- CI tooling: act -----------------------------------------------------
# Local GitHub Actions runner. NEEDS host Docker socket mounted via
# devcontainer.json (NOT Docker-in-Docker — that's deliberately rejected).
# renovate: datasource=github-releases depName=nektos/act
ARG ACT_VERSION=0.2.89
RUN ARCH=$(dpkg --print-architecture); \
    case "$ARCH" in \
      amd64) ACT_ARCH=x86_64 ;; \
      arm64) ACT_ARCH=arm64 ;; \
      *)     echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/act_Linux_${ACT_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin act \
 && chmod +x /usr/local/bin/act

# --- terminal multiplexer: zellij ----------------------------------------
# Rust binary, GitHub releases. Its asset names use the Rust target triple
# (x86_64/aarch64-unknown-linux-musl), so map dpkg's amd64/arm64 across —
# same shape as act above. The musl build is statically linked, so it runs
# on Debian without extra libs.
# renovate: datasource=github-releases depName=zellij-org/zellij
ARG ZELLIJ_VERSION=0.44.3
RUN ARCH=$(dpkg --print-architecture); \
    case "$ARCH" in \
      amd64) ZJ_ARCH=x86_64 ;; \
      arm64) ZJ_ARCH=aarch64 ;; \
      *)     echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-${ZJ_ARCH}-unknown-linux-musl.tar.gz" \
      | tar -xz -C /usr/local/bin zellij \
 && chmod +x /usr/local/bin/zellij

# Docker CLI only (no daemon — uses the mounted host socket).
# Compose v2 (docker-compose-plugin) ships alongside the CLI so `docker
# compose` works against the mounted host socket. It's the plugin, not the
# legacy `docker-compose` v1 python script — invoked as `docker compose`.
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && chmod a+r /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/* \
 && usermod -aG docker wm || groupadd docker && usermod -aG docker wm

# --- local TLS: mkcert ----------------------------------------------------
# Generates locally-trusted dev certificates (no CA warnings in the browser
# for https://localhost). Go binary from GitHub releases; asset names use
# amd64/arm64, matching dpkg directly — no arch remap needed.
# renovate: datasource=github-releases depName=FiloSottile/mkcert
ARG MKCERT_VERSION=v1.4.4
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL "https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-${ARCH}" \
      -o /usr/local/bin/mkcert \
 && chmod +x /usr/local/bin/mkcert

# --- Kubernetes: kubectl + helm ------------------------------------------
# Direct binary install (no apt repo, no GPG). Avoids the apt-repo +
# debsig-keyring dance which behaves inconsistently under buildkit's
# network sandbox against the k8s CDN. Tradeoff: no automatic updates via
# `apt upgrade` — but the image's `:v1` tag is rebuilt weekly anyway, and
# Renovate bumps these ARGs (see renovate.json).
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.36.2
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v4.2.3
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
      -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
      | tar -xz -C /tmp \
 && install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm \
 && rm -rf "/tmp/linux-${ARCH}"

# Pre-create the directories devcontainer.json volume-mounts onto.
# Empty named volumes inherit ownership from the image dir on first
# attach, so these chowns ensure scw/op/kube start out wm-owned.
RUN mkdir -p /home/wm/.config/scw \
             /home/wm/.config/op \
             /home/wm/.kube \
             /home/wm/.cargo/registry \
 && chown -R wm:wm /home/wm/.config /home/wm/.kube /home/wm/.cargo

USER wm
WORKDIR /home/wm

CMD ["zsh", "-l"]
