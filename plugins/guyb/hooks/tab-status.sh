#!/usr/bin/env bash
# Tab status icon: sets the terminal tab title to "<icon> <project name>" as Claude Code's state changes.
# Usage: tab-status.sh running|resume|done|waiting|agent-start|agent-stop|end   (async hook; never blocks, never prints, always exits 0)
#   running = hourglass (U+23F3)   done = check mark (U+2705)   waiting = question mark (U+2753)   end = plain name
#   resume  = PostToolUse: repaint "running" only if the last state written was "waiting" (cheap no-op otherwise);
#             ignored when the event comes from a subagent (stdin has agent_id), so a subagent cannot clear a main "waiting"
#   agent-start / agent-stop = SubagentStart / SubagentStop: one marker file per agent_id in "<state file>.agents/".
#   done (main Stop) paints the check mark only when no marker is live; otherwise the state becomes "idle-agents" and the
#   hourglass stays until the last agent-stop (or until the main agent runs again). Markers older than 4 hours are stale:
#   ignored and deleted, so a crashed agent cannot pin the hourglass. agent_id is read from stdin without jq.
# Acts only when GUYB_TAB_NAME is set (the guyb launcher exports it). Icons are built from UTF-8 bytes (source stays ASCII).
# GUYB_TAB_ASCII=1 or TERM=linux/dumb: "* " running, "+ " done, "? " waiting. GUYB_DRYRUN=1 prints "tab: <mode> <title>".
# Reaching the terminal: tmux ($TMUX) renames the window; Unix/macOS/WSL write OSC 0 to /dev/tty; Windows (Git Bash) hands
# off to tab-status.ps1, which attaches to the console of the Claude Code process (a hook's own console is hidden).
state="${1:-}"
input=""
case "$state" in
  resume|agent-start|agent-stop) IFS= read -r -d '' input 2>/dev/null ;;
  *) cat >/dev/null 2>&1 ;;
esac
[ -n "${GUYB_TAB_NAME:-}" ] || exit 0
case "$state" in running|resume|done|waiting|agent-start|agent-stop|end) ;; *) exit 0 ;; esac

LC_ALL=C
name="${GUYB_TAB_NAME//[$'\001'-$'\037'$'\177']/}"
name="${name//$'\302'[$'\200'-$'\237']/}"
[ -n "$name" ] || exit 0

stf="${TMPDIR:-/tmp}/guyb-tab-${name//[!A-Za-z0-9]/_}"
ad="$stf.agents"
id=""
re='"agent_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
if [[ "$input" =~ $re ]]; then id="${BASH_REMATCH[1]//[!A-Za-z0-9_-]/}"; fi
last=""; [ -f "$stf" ] && read -r last < "$stf"
# true when an agent marker is live; stale markers (older than 240 minutes) are deleted first
agents_live() {
  [ -d "$ad" ] || return 1
  local f any=""
  for f in "$ad"/*; do [ -f "$f" ] && any=1; done
  [ -n "$any" ] || return 1
  find "$ad" -type f -mmin +240 -delete >/dev/null 2>&1  # only spawned when a marker exists
  for f in "$ad"/*; do [ -f "$f" ] && return 0; done
  return 1
}
# $state is what gets painted, $keep what gets stored ("idle-agents" = main idle, agents still running, hourglass shown)
keep="$state"
case "$state" in
  resume)
    [[ "$input" =~ $re ]] && exit 0
    if [ "$last" = idle-agents ]; then printf 'running\n' 2>/dev/null >"$stf"; exit 0; fi
    [ "$last" = waiting ] || exit 0
    state=running; keep=running ;;
  agent-start)
    [ -n "$id" ] || exit 0
    [ -d "$ad" ] || mkdir -p "$ad" 2>/dev/null
    : 2>/dev/null >"$ad/$id"
    # a start hook landing after the main Stop: an agent is running, so show it
    [ "$last" = done ] || exit 0
    state=running; keep=idle-agents ;;
  agent-stop)
    [ -n "$id" ] || exit 0
    rm -f "$ad/$id" 2>/dev/null
    agents_live && exit 0
    [ "$last" = idle-agents ] || exit 0
    state=done; keep=done ;;
  done)
    if agents_live; then
      keep=idle-agents
      # hourglass already shown: record the state, repaint nothing
      if [ "$last" = running ] || [ "$last" = idle-agents ]; then printf '%s\n' "$keep" 2>/dev/null >"$stf"; exit 0; fi
      state=running
    fi ;;
esac
if [ "$state" = end ]; then rm -rf "$stf" "$ad" 2>/dev/null; else printf '%s\n' "$keep" 2>/dev/null >"$stf"; fi

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
