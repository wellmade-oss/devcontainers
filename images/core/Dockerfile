# syntax=docker/dockerfile:1.7
#
# wellmade-studio/dc-core
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
# Pinned-version updates flow via Dependabot + weekly rebuild.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release apt-transport-https \
      git openssh-client \
      zsh \
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
ARG YQ_VERSION=4.53.2
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
ARG GLAB_VERSION=1.99.0
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

RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
 && sed -i 's|^ZSH_THEME=.*|ZSH_THEME="robbyrussell"|' /home/${USERNAME}/.zshrc \
 && cat <<'ZSHRC_APPEND' >> /home/${USERNAME}/.zshrc

# --- Wellmade devcontainer indicator ---
# When this shell is running inside a Wellmade devcontainer image, the
# Dockerfile sets WELLMADE_DC=1. Prepend a small purple `[dc]` to the
# prompt so it's visually distinct from a host shell — the only thing
# we need is "in container yes/no". The colour (256-palette 141, a light
# lavender) stays outside robbyrussell's green/cyan/yellow palette so it
# doesn't compete with the arrow / cwd / git status segments.
if [[ -n "$WELLMADE_DC" ]]; then
  PROMPT="%F{141}[dc]%f $PROMPT"
fi
ZSHRC_APPEND

# --- node (needed only to install Claude CLI + wm at core level) ---------
# We install Node here purely to host the agent layer. The `workbench`
# image installs its own Node LTS toolchain on top — that's intentional;
# core stays "agent-ready" without claiming to be a Node dev image.
# Node 24 (Krypton) is the current Active LTS as of 2026-05.
USER root
ARG NODE_MAJOR=24
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g npm@latest

# --- agent layer: Claude CLI + wm + atelier-ai ---------------------------
# These three together make every Wellmade image agent-ready by default.
RUN npm install -g @anthropic-ai/claude-code

# wm CLI: design-phase repo, no published binary yet. Placeholder install
# step kept as a comment until the first wm release ships.
# RUN curl -fsSL https://wellmade.be/wm/install.sh | sh

# atelier-ai skills: cloned to a stable system path. The
# ~/.claude/skills symlink is NOT created at build time — devcontainer.json
# mounts a volume on ~/.claude/, which would shadow it. postcreate.sh
# recreates it inside the volume on first container start.
ARG ATELIER_AI_REF=main
RUN git clone --depth=1 --branch "${ATELIER_AI_REF}" \
      https://github.com/wellmade-studio/atelier-ai.git \
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
