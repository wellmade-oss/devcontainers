# Fix: every command echoes its own name before executing (zsh in zellij)

> **Status: FIXED in `dc-core`.** The scoped `$ZELLIJ` guard below was appended
> to `~/.zshrc` in **`images/core/Dockerfile`** (right after the starship init
> block), not workbench — even though zellij only ships in workbench. The
> leaking stack is omz, which lives in `core`; the guard is inert without
> zellij, so it's safe in core and means workbench inherits it via `FROM core`
> (and any future zellij-in-core is already covered). Matches the homelab
> `shell_env` role's choice.

Originally a handoff for whoever maintains **`ghcr.io/wellmade-oss/dc-workbench`**
(the image behind `wellmade-os-app-1`). Diagnosed 2026-07-25 on hephaestus; the
identical fix has already shipped in the homelab `shell_env` Ansible role, which
builds the same zsh/omz/starship stack on the container's *host*.

## Symptom

In an interactive zsh in the container, the command name is printed immediately
before the command's own output, with no trailing newline:

```
[dc] ~ $ ls
lsCLAUDE.md  Makefile  README.md  content  demo.py  ...
   ^^
[dc] ~ $ cd .
cd%
```

The trailing `%` is zsh's `PROMPT_EOL_MARK`, confirming the leaked text ended
without a newline.

## Root cause

Oh-my-zsh's `lib/termsupport.zsh` sets the terminal title from `precmd` and
`preexec` hooks. Its `title()` picks an escape sequence by `$TERM`:

```zsh
case "$TERM" in
  cygwin|xterm*|putty*|rxvt*|...)  print -Pn "\e]2;${2:q}\a" ;;  # OSC — universal
  screen*|tmux*)                   print -Pn "\ek${1:q}\e\\" ;;  # GNU-screen hardstatus
  *)                               ... terminfo tsl/fsl ... ;;
esac
```

`ESC k <text> ESC \` is the **GNU-screen hardstatus** sequence. Only screen and
tmux implement it.

The failing stack is **zellij nested inside tmux**. Zellij passes the outer
tmux's `TERM` straight through to its panes without overriding it — verified on
live processes:

```
TERM=tmux-256color ZELLIJ=0 ZELLIJ_SESSION_NAME=sincere-muskrat
```

So zsh believes it is talking to tmux, emits `ESC k`, and the process actually
parsing those bytes is **zellij**, which has no `ESC k` handler. Zellij consumes
the 2-byte escape and renders the payload as ordinary text. tmux, one layer
further out, never sees it.

Raw pty capture from inside the container (`TERM=tmux-256color`, running
`ls -d /etc`) — the leak is the first token on the line:

```
^[kls^[\  ^[[0m^[[01;34m/etc^[[0m
└──┬───┘  └── the real ls output
   └─ ESC k "ls" ESC \
```

The payload is `${(z)2}[1]`, the **first word only**, which is why `cd .` leaks
`cd` and not `cd .`.

`precmd` leaks the cwd through the exact same path, but starship's prompt redraw
(`\r` then `\e[J`) erases it before you can see it. Only the `preexec` leak
survives, because nothing redraws between it and the command's output.

**Not a bug in starship, zellij, tmux, or the container's zshrc.** It is upstream
omz treating `TERM=tmux-*` as proof that tmux is the renderer.

## Fix

Append to `/home/wm/.zshrc` in the image (order within the file doesn't matter —
omz reads `DISABLE_AUTO_TITLE` at hook time, not at source time):

```zsh
# oh-my-zsh sets the terminal title from precmd/preexec. For TERM=screen*/tmux*
# it emits the GNU-screen hardstatus sequence (ESC k … ESC \), which only screen
# and tmux parse. Zellij inherits tmux's TERM when nested inside it but has no
# ESC k handler, so it renders the payload as text and every command echoes its
# own name before running. `if` rather than `&&` so a non-zellij shell leaves $?
# at 0 — this lands at the end of ~/.zshrc and starship colours the first prompt
# from it.
if [[ -n "$ZELLIJ" ]]; then
  DISABLE_AUTO_TITLE=true
fi
```

### Why scoped to `$ZELLIJ` rather than disabled outright

Under plain tmux the `ESC k` path is correct and works. `$ZELLIJ` is set by
zellij in every pane it owns, so it is the reliable "the innermost renderer is
zellij" marker. Disabling titles unconditionally would also work but gives up
window naming in the tmux-only case for no reason.

### If you would rather keep titles working under zellij

Replace `title()` with the OSC form after omz is sourced — OSC 0/1/2 is
understood by tmux, zellij and iTerm2 alike:

```zsh
DISABLE_AUTO_TITLE=true
autoload -Uz add-zsh-hook
_dc_title()   { print -Pn "\e]0;${1//[[:cntrl:]]/}\a" }
add-zsh-hook precmd  () { _dc_title "%~" }
add-zsh-hook preexec () { _dc_title "$1" }
```

Costs you a hand-maintained copy of an omz internal. The homelab side chose the
three-line version above; match it unless you actually want the titles.

## Verification

From the container host, capture the raw bytes rather than eyeballing a terminal
— the whole bug is invisible bytes:

```sh
printf 'ls -d /etc\nexit\n' | TERM=tmux-256color \
  script -qec "docker exec -it -e TERM=tmux-256color wellmade-os-app-1 /bin/zsh -i" /tmp/raw.out \
  >/dev/null 2>&1
cat -v /tmp/raw.out | grep -- '-d /etc' -A2
```

- **Before the fix:** a `^[kls^[\` appears immediately before the `ls` output.
- **After the fix:** that sequence is gone (the `^[k~^[\` from `precmd` goes too).

Note the harness must force `TERM=tmux-256color`; with the default
`xterm-256color` the OSC branch is taken and the bug cannot reproduce. That is
also why this never showed up in CI or a plain `docker exec`.

Then confirm interactively: attach zellij inside tmux, exec into the container,
run `ls` — no echoed command name — and check that the **first** prompt's `$` is
green, not red (that is the `$?` trap the `if` form avoids).

## Context worth carrying

The container's omz is pinned at commit `6574980` (2026-06-29); the host's is a
different checkout. Both carry this branch — it is current upstream omz
behaviour, not drift, so `omz update` will not fix it and a future update will
not undo the fix.
