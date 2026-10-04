#!/usr/bin/env bash
# Tab status icon: sets the terminal tab title to "<icon> <project name>" as Claude Code's state changes.
# Usage: tab-status.sh running|resume|done|waiting|end   (async hook; never blocks, never prints, always exits 0)
#   running = hourglass (U+23F3)   done = check mark (U+2705)   waiting = question mark (U+2753)   end = plain name
#   resume  = PostToolUse: repaint "running" only if the last state written was "waiting" (cheap no-op otherwise)
# Acts only when GUYB_TAB_NAME is set (the guyb launcher exports it). Icons are built from UTF-8 bytes (source stays ASCII).
# GUYB_TAB_ASCII=1 or TERM=linux/dumb: "* " running, "+ " done, "? " waiting. GUYB_DRYRUN=1 prints "tab: <mode> <title>".
# Reaching the terminal: tmux ($TMUX) renames the window; Unix/macOS/WSL write OSC 0 to /dev/tty; Windows (Git Bash) hands
# off to tab-status.ps1, which attaches to the console of the Claude Code process (a hook's own console is hidden).
cat >/dev/null 2>&1
state="${1:-}"
[ -n "${GUYB_TAB_NAME:-}" ] || exit 0
case "$state" in running|resume|done|waiting|end) ;; *) exit 0 ;; esac

LC_ALL=C
name="${GUYB_TAB_NAME//[$'\001'-$'\037'$'\177']/}"
name="${name//$'\302'[$'\200'-$'\237']/}"
[ -n "$name" ] || exit 0

stf="${TMPDIR:-/tmp}/guyb-tab-${name//[!A-Za-z0-9]/_}"
if [ "$state" = resume ]; then
  last=""; [ -f "$stf" ] && read -r last < "$stf"
  [ "$last" = waiting ] || exit 0
  state=running
fi
if [ "$state" = end ]; then rm -f "$stf" 2>/dev/null; else printf '%s\n' "$state" 2>/dev/null >"$stf"; fi

ascii=""
case "${GUYB_TAB_ASCII:-}" in 1) ascii=1 ;; esac
case "${TERM:-}" in linux|dumb) ascii=1 ;; esac
case "$state" in
  running) if [ -n "$ascii" ]; then g='*'; else g=$'\342\217\263'; fi ;;
  done)    if [ -n "$ascii" ]; then g='+'; else g=$'\342\234\205'; fi ;;
  waiting) if [ -n "$ascii" ]; then g='?'; else g=$'\342\235\223'; fi ;;
  *)       g="" ;;
esac
if [ -n "$g" ]; then title="$g $name"; else title="$name"; fi

if [ -n "${TMUX:-}" ]; then mode=tmux; else mode=osc0; fi
if [ -n "${GUYB_DRYRUN:-}" ]; then printf 'tab: %s %s\n' "$mode" "$title"; exit 0; fi

if [ "$mode" = tmux ]; then
  # tmux format-expands the name ('#' doubled) and reads a trailing ';' as a command separator
  t="${title//\#/##}"
  case "$t" in *\;) t="${t%;}\;" ;; esac
  tmux rename-window -t "${TMUX_PANE:-}" "$t" >/dev/null 2>&1
  exit 0
fi

case "${OSTYPE:-}" in
  msys*|cygwin*)
    p="${0%/*}/tab-status.ps1"
    if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -w "$p")"; fi
    ps=powershell.exe
    command -v "$ps" >/dev/null 2>&1 || ps="${SYSTEMROOT:-/c/Windows}/System32/WindowsPowerShell/v1.0/powershell.exe"
    "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$p" "$state" >/dev/null 2>&1
    exit 0 ;;
esac
printf '\033]0;%s\007' "$title" 2>/dev/null >/dev/tty
exit 0
