#!/usr/bin/env bash
# Tests for the launcher tab features in scripts/launch.sh: colour table, title sanitising, dry-run command lines.
# Usage: bash tests/tabs.sh. Launches nothing (GUYB_DRYRUN=1), needs no tmux/claude/network; temp dir removed on exit.
# PowerShell twin: tabs.ps1 (keep the expected colour table identical).
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-tabs.XXXXXX") || exit 1
tmp=$(cd "$tmp" && pwd) || exit 1  # macOS TMPDIR ends in '/'; normalize so expected paths match
trap 'rm -rf "$tmp"' EXIT
unset TMUX CLAUDECODE GUYB_TAB_NAME GUYB_TAB_ASCII
export GUYB_DRYRUN=1 TERM=xterm
# shellcheck disable=SC1091
. "$root/scripts/launch.sh"

# Tab icons as UTF-8 bytes: running U+23F3, done U+2705, waiting U+2753 (same code points in tabs.ps1).
RUN=$(printf '\342\217\263'); DONE=$(printf '\342\234\205'); WAIT=$(printf '\342\235\223')

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
expect_has here-osc "$out" "here: osc0 $DONE my app"
expect_has here-env "$out" "GUYB_TAB_NAME='my app' CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 claude /guyb:start"
out="$(GUYB_TAB_ASCII=1 guyb 'my app' 2>&1)"
expect_has here-osc-ascii "$out" 'here: osc0 + my app'
out="$(TERM=dumb guyb 'my app' 2>&1)"
expect_has here-osc-dumb "$out" 'here: osc0 + my app'
out="$(guyb 'my app' 2>&1)"
expect_lacks here-no-tmux "$out" 'tmux:'

out="$(TMUX=/tmp/fake,1,0 guyb guyb 2>&1)"
expect_has tmux-new "$out" "tmux: new-window -P -F '#{window_id}' -n '$DONE guyb'"
expect_has tmux-env "$out" "GUYB_TAB_NAME='guyb' CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 claude /guyb:start; exec \$SHELL"
expect_has tmux-autorename "$out" 'set-window-option -t @dry automatic-rename off'
expect_has tmux-allowrename "$out" 'set-window-option -t @dry allow-rename off'
expect_has tmux-style "$out" 'window-status-style bg=#61AFEF,fg=#000000'
expect_has tmux-style-current "$out" 'window-status-current-style bg=#61AFEF,fg=#000000,bold'
expect_lacks tmux-no-global "$out" ' -g'

out="$(TMUX=/tmp/fake,1,0 guyb 'x;' 2>&1)"
expect_has tmux-semi-n "$out" "-n '$DONE x\\;' -c '$tmp/proj/x\\;'"
out="$(TMUX=/tmp/fake,1,0 guyb 'a#b' 2>&1)"
expect_has tmux-hash "$out" "-n '$DONE a##b' -c '$tmp/proj/a##b'"

list="$(guyb --list 2>&1)"
expect_has list-guyb "$list" "guyb	$tmp/proj/guyb"
expect_has list-space "$list" 'my app'
expect_lacks list-no-dryrun "$list" 'here:'

# --- tab-status.sh (status hook): GUYB_DRYRUN=1 prints "tab: <mode> <title>". Acts only when GUYB_TAB_NAME is set.
hook="$root/plugins/guyb/hooks/tab-status.sh"
hk() { GUYB_TAB_NAME="$tname" TMPDIR="$tmp" bash "$hook" "$@" </dev/null 2>&1; }
hkin() { GUYB_TAB_NAME="$tname" TMPDIR="$tmp" bash "$hook" "$@" 2>&1; }  # stdin comes from the caller
tname='my app'
expect_eq hook-running "$(hk running)" "tab: osc0 $RUN my app"
expect_eq hook-done "$(hk done)" "tab: osc0 $DONE my app"
expect_eq hook-waiting "$(hk waiting)" "tab: osc0 $WAIT my app"
expect_eq hook-end "$(hk end)" 'tab: osc0 my app'
expect_eq hook-ascii-running "$(GUYB_TAB_ASCII=1 hk running)" 'tab: osc0 * my app'
expect_eq hook-ascii-done "$(GUYB_TAB_ASCII=1 hk done)" 'tab: osc0 + my app'
expect_eq hook-ascii-waiting "$(GUYB_TAB_ASCII=1 hk waiting)" 'tab: osc0 ? my app'
expect_eq hook-dumb "$(TERM=dumb hk done)" 'tab: osc0 + my app'
expect_eq hook-tmux "$(TMUX=/tmp/fake,1,0 hk waiting)" "tab: tmux $WAIT my app"
expect_eq hook-bad-state "$(hk bogus)" ''
expect_eq hook-no-state "$(hk)" ''
tname=''
expect_eq hook-unset-name "$(hk running)" ''
tname="$(printf 'a\033]0;x\007b\302\233c\177')"
expect_eq hook-clean "$(hk done)" "tab: osc0 $DONE a]0;xbc"
# resume (PostToolUse) repaints only after "waiting"
tname='rs'
hk end >/dev/null
expect_eq hook-resume-fresh "$(hk resume)" ''
hk running >/dev/null
expect_eq hook-resume-after-running "$(hk resume)" ''
hk waiting >/dev/null
expect_eq hook-resume-after-waiting "$(hk resume)" "tab: osc0 $RUN rs"
expect_eq hook-resume-twice "$(hk resume)" ''
hk end >/dev/null
# subagents: Stop keeps the hourglass while an agent marker is live; the last agent-stop paints the check mark
tname='ag'
ev() { printf '{"agent_id":"%s","agent_type":"x"}' "$2" | hkin "$1"; }
hk end >/dev/null
hk running >/dev/null
ev agent-start a1 >/dev/null
expect_eq agent-stop-before-main-stop "$(ev agent-stop a1)" ''
expect_eq agent-stop-first-then-done "$(hk done)" "tab: osc0 $DONE ag"
hk running >/dev/null
ev agent-start a1 >/dev/null; ev agent-start a2 >/dev/null
expect_eq agent-done-with-live "$(hk done)" ''  # hourglass already shown: no repaint
expect_eq agent-done-with-live-state "$(cat "$tmp/guyb-tab-ag")" idle-agents
expect_eq agent-stop-one-of-two "$(ev agent-stop a1)" ''
expect_eq agent-stop-last-after-done "$(ev agent-stop a2)" "tab: osc0 $DONE ag"
expect_eq agent-stop-again "$(ev agent-stop a2)" ''
# "?" after Stop while an agent runs: the last agent-stop still paints the check (main is idle)
hk running >/dev/null; ev agent-start w1 >/dev/null; hk done >/dev/null
expect_eq agent-idle-notify "$(hk waiting)" "tab: osc0 $WAIT ag"
expect_eq agent-idle-sub-resume "$(ev resume w1)" ''
expect_eq agent-idle-last-stop "$(ev agent-stop w1)" "tab: osc0 $DONE ag"
# ... and a main-agent tool use after that "?" goes back to the hourglass
hk running >/dev/null; ev agent-start w2 >/dev/null; hk done >/dev/null; hk waiting >/dev/null
expect_eq agent-idle-main-resume "$(hk resume)" "tab: osc0 $RUN ag"
ev agent-stop w2 >/dev/null
# Stop with a live agent after a waiting "?" repaints the hourglass
ev agent-start a3 >/dev/null; hk waiting >/dev/null
expect_eq agent-ascii "$(GUYB_TAB_ASCII=1 hk done)" 'tab: osc0 * ag'
ev agent-stop a3 >/dev/null
# main agent runs again while agents live (background task re-invoked it): last agent-stop must not paint
hk running >/dev/null; ev agent-start b1 >/dev/null; hk done >/dev/null
expect_eq agent-main-resumes "$(hk resume)" ''
expect_eq agent-stop-while-main-runs "$(ev agent-stop b1)" ''
expect_eq agent-then-done "$(hk done)" "tab: osc0 $DONE ag"
# a start hook that lands after Stop shows the hourglass; its stop restores the check mark
expect_eq agent-late-start "$(ev agent-start c1)" "tab: osc0 $RUN ag"
expect_eq agent-late-stop "$(ev agent-stop c1)" "tab: osc0 $DONE ag"
# missing or unsafe agent_id
expect_eq agent-no-id "$(printf '{}' | hkin agent-start)" ''
hk running >/dev/null
printf '{"agent_id":"../x y"}' | hkin agent-start >/dev/null
expect_eq agent-id-sanitized "$(ls "$tmp/guyb-tab-ag.agents")" 'xy'
printf '{"agent_id":"../x y"}' | hkin agent-stop >/dev/null
# stale markers (older than 4h) are ignored and deleted
hk running >/dev/null; ev agent-start old >/dev/null
touch -t 200001010000 "$tmp/guyb-tab-ag.agents/old"
expect_eq agent-stale-ignored "$(hk done)" "tab: osc0 $DONE ag"
expect_eq agent-stale-deleted "$(ls "$tmp/guyb-tab-ag.agents")" ''
# a waiting "?" is not cleared by a subagent's PostToolUse, but is by the main agent's
hk waiting >/dev/null
expect_eq agent-resume-ignored "$(ev resume a9)" ''
expect_eq agent-resume-main "$(printf '{"tool_name":"Bash"}' | hkin resume)" "tab: osc0 $RUN ag"
# end clears the markers
ev agent-start e1 >/dev/null
hk end >/dev/null
expect_eq agent-end-clears "$([ -e "$tmp/guyb-tab-ag.agents" ] && echo present)" ''
# no terminal to reach: never fails, never prints
out="$(env -u GUYB_DRYRUN GUYB_TAB_NAME=zz TMPDIR="$tmp" TMUX=/nonexistent/sock,1,0 bash "$hook" running </dev/null 2>&1)"; rc=$?
expect_eq hook-silent "$out" ''
expect_eq hook-rc "$rc" 0

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
    export TMUX PATH="$tmp/bin:$PATH" SHELL=/bin/sh GUYB_TAB_ASCII=1
    guyb "$@" 2>&1
  )
  if T new-session -d -s base -x 120 -y 30 2>/dev/null; then
    before="$(T show-options -g; T show-window-options -g)"

    out="$(tguyb 'my app')"
    expect_has real-opened "$out" "Opened 'my app'"
    id="$(win_id '+ my app')"
    if [ -z "$id" ]; then no "real-window: no window named 'my app'"; else
      expect_eq real-autorename "$(T show-window-options -t "$id" -v automatic-rename)" off
      expect_eq real-allowrename "$(T show-window-options -t "$id" -v allow-rename)" off
      # tmux may print hex colours in lower case
      expect_eq real-style "$(T show-window-options -t "$id" -v window-status-style | tr a-z A-Z)" 'BG=#61AFEF,FG=#000000'
      expect_eq real-style-current "$(T show-window-options -t "$id" -v window-status-current-style | tr a-z A-Z)" 'BG=#61AFEF,FG=#000000,BOLD'
      expect_eq real-cwd "$(pane_dir "$id")" "$(cd "$tmp/proj/my app" && pwd -P)"
    fi

    tguyb shuto >/dev/null
    id="$(win_id '+ shuto')"
    expect_eq real-color-shuto "$(T show-window-options -t "$id" -v window-status-style | tr a-z A-Z)" 'BG=#E06C75,FG=#000000'
    expect_eq real-color-per-window "$(T show-window-options -t "$(win_id '+ my app')" -v window-status-style | tr a-z A-Z)" 'BG=#61AFEF,FG=#000000'

    # -n and -c escaping: the name and cwd must arrive intact ('#' doubled, trailing ';' escaped)
    for n in 'x;' 'a#b'; do
      tguyb "$n" >/dev/null
      id="$(win_id "+ $n")"
      if [ -z "$id" ]; then no "real-name '$n': no window with that name"; else
        ok
        expect_eq "real-cwd '$n'" "$(pane_dir "$id")" "$(cd "$tmp/proj/$n" && pwd -P)"
      fi
    done

    # status hook renames the window ('#' and a trailing ';' arrive intact)
    for n in 'my app' 'x;' 'a#b'; do
      id="$(win_id "+ $n")"
      pane="$(T display -p -t "$id" '#{pane_id}')"
      sockinfo="$(T display -p '#{socket_path}'),$(T display -p '#{pid}'),0"
      (
        unset GUYB_DRYRUN
        export TMUX="$sockinfo" TMUX_PANE="$pane" GUYB_TAB_NAME="$n" GUYB_TAB_ASCII=1 TMPDIR="$tmp"
        bash "$hook" waiting </dev/null >/dev/null 2>&1
      )
      expect_eq "real-hook '$n'" "$(win_id "? $n")" "$id"
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
  expect_has zsh-here "$out" "here: osc0 $DONE my app"
  expect_has zsh-here-env "$out" "GUYB_TAB_NAME='my app' CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 claude /guyb:start"
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
