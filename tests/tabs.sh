#!/usr/bin/env bash
# Tests for the launcher tab features in scripts/launch.sh: colour table, title sanitising, dry-run command lines.
# Usage: bash tests/tabs.sh. Launches nothing (GUYB_DRYRUN=1), needs no tmux/claude/network; temp dir removed on exit.
# PowerShell twin: tabs.ps1 (keep the expected colour table identical).
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-tabs.XXXXXX") || exit 1
tmp=$(cd "$tmp" && pwd) || exit 1  # macOS TMPDIR ends in '/'; normalize so expected paths match
trap 'rm -rf "$tmp"' EXIT
unset TMUX CLAUDECODE
export GUYB_DRYRUN=1
# shellcheck disable=SC1091
. "$root/scripts/launch.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
expect_eq() { if [ "$2" = "$3" ]; then ok; else no "$1: got '$2', want '$3'"; fi; }
expect_has() { if has "$2" "$3"; then ok; else no "$1: missing '$3' in: $2"; fi; }
expect_lacks() { if has "$2" "$3"; then no "$1: unexpected '$3' in: $2"; else ok; fi; }

# Colour table (same values in tabs.ps1). The unicode name is "cafe" with e-acute as UTF-8 bytes.
expect_eq color-guyb "$(_guyb_color guyb)" '#61AFEF'
expect_eq color-shuto "$(_guyb_color shuto)" '#E06C75'
expect_eq color-space "$(_guyb_color 'my app')" '#61AFEF'
expect_eq color-a "$(_guyb_color a)" '#D19A66'
expect_eq color-unicode "$(_guyb_color "$(printf 'caf\303\251')")" '#56B6C2'
expect_eq color-empty "$(_guyb_color '')" '#C678DD'

# Control characters never reach a title.
dirty="$(printf 'a\033]0;x\007b\nc\177d')"
expect_eq clean "$(_guyb_clean "$dirty")" 'a]0;xbcd'

expect_eq clean-c1 "$(_guyb_clean "$(printf 'a\302\233b\302\200c\303\251')")" "$(printf 'abc\303\251')"
expect_eq tmux-arg-semi "$(_guyb_tmux_arg 'x;')" 'x\;'
expect_eq tmux-arg-mid-semi "$(_guyb_tmux_arg 'x;y')" 'x;y'
expect_eq tmux-arg-hash "$(_guyb_tmux_arg 'a#b')" 'a##b'

mkdir -p "$tmp/proj/my app" "$tmp/proj/guyb" "$tmp/proj/x;" "$tmp/proj/a#b"
export GUYB_ROOT="$tmp/proj"

out="$(guyb 'my app' 2>&1)"
expect_has here-osc "$out" 'here: osc0 my app'
expect_has here-env "$out" 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 claude /guyb:start'
expect_lacks here-no-tmux "$out" 'tmux:'

out="$(TMUX=/tmp/fake,1,0 guyb guyb 2>&1)"
expect_has tmux-new "$out" "tmux: new-window -P -F '#{window_id}' -n 'guyb'"
expect_has tmux-env "$out" 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 claude /guyb:start; exec $SHELL'
expect_has tmux-autorename "$out" 'set-window-option -t @dry automatic-rename off'
expect_has tmux-allowrename "$out" 'set-window-option -t @dry allow-rename off'
expect_has tmux-style "$out" 'window-status-style bg=#61AFEF,fg=#000000'
expect_has tmux-style-current "$out" 'window-status-current-style bg=#61AFEF,fg=#000000,bold'
expect_lacks tmux-no-global "$out" ' -g'

out="$(TMUX=/tmp/fake,1,0 guyb 'x;' 2>&1)"
expect_has tmux-semi-n "$out" "-n 'x\\;' -c '$tmp/proj/x\\;'"
out="$(TMUX=/tmp/fake,1,0 guyb 'a#b' 2>&1)"
expect_has tmux-hash "$out" "-n 'a##b' -c '$tmp/proj/a##b'"

list="$(guyb --list 2>&1)"
expect_has list-guyb "$list" "guyb	$tmp/proj/guyb"
expect_has list-space "$list" 'my app'
expect_lacks list-no-dryrun "$list" 'here:'

# --- Real tmux (bash only; launch.ps1 has no tmux branch). Private server via -L, never the developer's tmux.
# Skipped when tmux is missing unless GUYB_REQUIRE_TMUX=1 (CI), where a missing tmux is a failure.
if ! command -v tmux >/dev/null 2>&1; then
  if [ -n "${GUYB_REQUIRE_TMUX:-}" ]; then no "tmux required (GUYB_REQUIRE_TMUX) but not installed"; else echo "skip: no tmux"; fi
else
  sock="guyb-$$"
  T() { tmux -L "$sock" -f /dev/null "$@"; }
  trap 'T kill-server >/dev/null 2>&1; rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/bin" "$tmp/proj/shuto"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/claude"; chmod +x "$tmp/bin/claude"
  # id of the window named $1 (space-safe: split each line at the first '|')
  win_id() {
    T list-windows -F '#{window_id}|#{window_name}' | while IFS= read -r l; do
      if [ "${l#*|}" = "$1" ]; then echo "${l%%|*}"; break; fi
    done
  }
  # pane cwd of window $1 as a physical path (macOS reports /private/var for /var)
  pane_dir() { local p; p="$(T display -p -t "$1" '#{pane_current_path}')"; [ -d "$p" ] && (cd "$p" && pwd -P); }
  # run guyb against the private server; $TMUX points at it, the caller's tmux is never used
  tguyb() (
    unset GUYB_DRYRUN
    TMUX="$(T display -p '#{socket_path}'),$(T display -p '#{pid}'),0"
    export TMUX PATH="$tmp/bin:$PATH" SHELL=/bin/sh
    guyb "$@" 2>&1
  )
  if T new-session -d -s base -x 120 -y 30 2>/dev/null; then
    before="$(T show-options -g; T show-window-options -g)"

    out="$(tguyb 'my app')"
    expect_has real-opened "$out" "Opened 'my app'"
    id="$(win_id 'my app')"
    if [ -z "$id" ]; then no "real-window: no window named 'my app'"; else
      expect_eq real-autorename "$(T show-window-options -t "$id" -v automatic-rename)" off
      expect_eq real-allowrename "$(T show-window-options -t "$id" -v allow-rename)" off
      # tmux may print hex colours in lower case
      expect_eq real-style "$(T show-window-options -t "$id" -v window-status-style | tr a-z A-Z)" 'BG=#61AFEF,FG=#000000'
      expect_eq real-style-current "$(T show-window-options -t "$id" -v window-status-current-style | tr a-z A-Z)" 'BG=#61AFEF,FG=#000000,BOLD'
      expect_eq real-cwd "$(pane_dir "$id")" "$(cd "$tmp/proj/my app" && pwd -P)"
    fi

    tguyb shuto >/dev/null
    id="$(win_id shuto)"
    expect_eq real-color-shuto "$(T show-window-options -t "$id" -v window-status-style | tr a-z A-Z)" 'BG=#E06C75,FG=#000000'
    expect_eq real-color-per-window "$(T show-window-options -t "$(win_id 'my app')" -v window-status-style | tr a-z A-Z)" 'BG=#61AFEF,FG=#000000'

    # -n and -c escaping: the name and cwd must arrive intact ('#' doubled, trailing ';' escaped)
    for n in 'x;' 'a#b'; do
      tguyb "$n" >/dev/null
      id="$(win_id "$n")"
      if [ -z "$id" ]; then no "real-name '$n': no window with that name"; else
        ok
        expect_eq "real-cwd '$n'" "$(pane_dir "$id")" "$(cd "$tmp/proj/$n" && pwd -P)"
      fi
    done

    expect_eq real-global-untouched "$(T show-options -g; T show-window-options -g)" "$before"
    expect_eq real-first-window-default "$(T show-window-options -t base:0 -v automatic-rename)" ''
  else
    no "real tmux: could not start a private server"
  fi
  T kill-server >/dev/null 2>&1
fi

# --- zsh: users source launch.sh from ~/.zshrc. Skipped when zsh is missing unless GUYB_REQUIRE_ZSH=1.
if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${GUYB_REQUIRE_ZSH:-}" ]; then no "zsh required (GUYB_REQUIRE_ZSH) but not installed"; else echo "skip: no zsh"; fi
else
  mkdir -p "$tmp/bin" "$tmp/empty" "$tmp/home"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/claude"; chmod +x "$tmp/bin/claude"
  zl="$root/scripts/launch.sh"
  zg() { zsh -f -c 'unset TMUX; GUYB_DRYRUN=1 GUYB_ROOT=$1; source $2; shift 2; guyb "$@"' _ "$GUYB_ROOT" "$zl" "$@" 2>&1; }

  out="$(zg 'my app')"
  expect_has zsh-here "$out" 'here: osc0 my app'
  expect_has zsh-here-env "$out" 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 claude /guyb:start'
  out="$(zsh -f -c 'GUYB_DRYRUN=1 GUYB_ROOT=$1; source $2; TMUX=/tmp/fake,1,0 guyb "my app"' _ "$GUYB_ROOT" "$zl" 2>&1)"
  expect_has zsh-tmux-new "$out" 'tmux: new-window'
  expect_has zsh-tmux-style "$out" 'bg=#61AFEF,fg=#000000'
  expect_eq zsh-color-unicode "$(zsh -f -c 'source $1; _guyb_color "$(printf "caf\303\251")"' _ "$zl" 2>&1)" '#56B6C2'
  expect_eq zsh-tmux-arg "$(zsh -f -c 'source $1; _guyb_tmux_arg "a#b;"' _ "$zl" 2>&1)" 'a##b\;'

  out="$(zsh -f -c 'GUYB_ROOT=$1; source $2; guyb --list; echo rc=$?' _ "$tmp/empty" "$zl" 2>&1)"
  expect_eq zsh-list-empty "$out" 'rc=0'
  out="$(zsh -f -c 'GUYB_ROOT=$1; source $2; guyb nosuch; echo rc=$?' _ "$tmp/empty" "$zl" 2>&1)"
  expect_has zsh-nosuch "$out" 'Project not found'
  expect_has zsh-nosuch-rc "$out" 'rc=1'

  # install.sh appends the source line to ~/.zshrc; an interactive zsh then has guyb
  inst() { HOME="$tmp/home" SHELL=/bin/zsh PATH="$tmp/bin:$PATH" /bin/bash "$root/scripts/install.sh" --skip-permissions --root "$tmp/proj" >/dev/null 2>&1; }
  inst; inst
  rc="$(cat "$tmp/home/.zshrc" 2>/dev/null)"
  expect_has zsh-rc-source "$rc" "source \"$root/scripts/launch.sh\""
  expect_has zsh-rc-root "$rc" 'export GUYB_ROOT='
  expect_eq zsh-rc-once "$(grep -cF "source \"$root/scripts/launch.sh\"" "$tmp/home/.zshrc")" 1
  expect_has zsh-interactive-list "$(env -u GUYB_DRYRUN HOME="$tmp/home" ZDOTDIR="$tmp/home" zsh -i -c 'guyb --list' 2>/dev/null </dev/null)" 'my app'

  # brief.sh and check.sh run from zsh (smoke.sh has the full coverage)
  b="$(zsh -f -c 'bash "$1" "$2"' _ "$root/plugins/guyb/skills/start/brief.sh" "$tmp/proj/my app" 2>/dev/null)"
  expect_eq zsh-brief-first "$(printf '%s\n' "$b" | head -n1)" 'project: my app'
  cj="$tmp/zsh-check.json"
  HOME="$tmp/home" zsh -f -c 'bash "$1" "$2"' _ "$root/plugins/guyb/skills/setup/check.sh" "$tmp/proj/my app" > "$cj" 2>/dev/null
  if command -v jq >/dev/null 2>&1; then
    if jq empty "$cj" >/dev/null 2>&1; then ok; else no "zsh-check-json: invalid JSON"; fi
  elif command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$cj" >/dev/null 2>&1; then ok; else no "zsh-check-json: invalid JSON"; fi
  else echo "skip: no jq/python3 for zsh check.sh JSON"; fi
fi

echo "tabs.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
