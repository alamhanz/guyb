# Usage guard, sourced (not run): by tab-status.sh (notify) and by the PreToolUse Agent|Task hook with arg "gate".
# The guyb status line writes "<level> <window> <pct> <resets_at>" (level warn|stop, window 5h|7d) to
# ${GUYB_USAGE_DIR:-~/.claude/guyb/usage}/state when plan usage crosses usage_warn / usage_stop; callers source this
# file only when that file exists (one stat otherwise). Fails open: any problem means no notice, no gate.
# Notify (mode resume without agent_id, done, agent-stop): once per (session, level, window, resets_at) it prints the
# notice on stderr and arranges exit 2; with the asyncRewake hook option that wakes the model. Mode end drops the
# session's marker. Gate: at level stop asks for permission before a new agent launch.
# Expects $input (stdin JSON, notify) and $1 (mode); bash 3.2 safe, ASCII only, never prompts.
ug_dir=${GUYB_USAGE_DIR:-$HOME/.claude/guyb/usage}
ug_mode=${1:-}
ug_lvl=; ug_win=; ug_pct=; ug_rs=
[ -f "$ug_dir/state" ] && IFS=' ' read -r ug_lvl ug_win ug_pct ug_rs < "$ug_dir/state"
case $ug_lvl in warn|stop) ;; *) return 0 ;; esac
case $ug_win in 5h|7d) ;; *) return 0 ;; esac
case $ug_pct$ug_rs in ''|*[!0-9]*) return 0 ;; esac
[ -n "$ug_pct" ] && [ -n "$ug_rs" ] || return 0

if [ "$ug_mode" != gate ]; then
  case $ug_mode in resume|done|agent-stop|end) ;; *) return 0 ;; esac
  ug_re='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
  ug_sid=
  if [[ ${input:-} =~ $ug_re ]]; then ug_sid=${BASH_REMATCH[1]//[!A-Za-z0-9_-]/}; fi
  [ -n "$ug_sid" ] || return 0
  if [ "$ug_mode" = end ]; then rm -f "$ug_dir/fired.$ug_sid"; return 0; fi
  ug_re='"agent_id"[[:space:]]*:'
  if [ "$ug_mode" = resume ] && [[ ${input:-} =~ $ug_re ]]; then return 0; fi  # a subagent's tool call, not the main session
  ug_key="$ug_lvl $ug_win $ug_rs"
  ug_old=; [ -f "$ug_dir/fired.$ug_sid" ] && IFS= read -r ug_old < "$ug_dir/fired.$ug_sid"
  [ "$ug_old" = "$ug_key" ] && return 0  # already told: no fork
fi

ug_now=$(date +%s)
case $ug_now in ''|*[!0-9]*) return 0 ;; esac
if [ "$ug_rs" -le "$ug_now" ]; then rm -f "$ug_dir/state"; return 0; fi

ug_time=$(date -d "@$ug_rs" '+%Y-%m-%d %H:%M' 2>/dev/null) || ug_time=$(date -r "$ug_rs" '+%Y-%m-%d %H:%M' 2>/dev/null) || ug_time=
[ -n "$ug_time" ] || ug_time=$ug_rs
if [ "$ug_win" = 5h ]; then ug_name=5-hour; else ug_name=weekly; fi

if [ "$ug_mode" = gate ]; then
  [ "$ug_lvl" = stop ] || return 0
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"guyb: %s plan usage at %s%% (resets %s); a new agent may be cut off mid-task."}}\n' "$ug_name" "$ug_pct" "$ug_time"
  return 0
fi

# no marker written = no notice (a read-only home must not repeat the notice on every call)
{ mkdir -p "$ug_dir" && printf '%s\n' "$ug_key" > "$ug_dir/fired.$ug_sid"; } 2>/dev/null || return 0
find "$ug_dir" -name 'fired.*' -mtime +8 -delete >/dev/null 2>&1
if [ "$ug_lvl" = stop ]; then
  printf 'guyb usage guard: %s plan usage at %s%% (resets %s). Wind down now: load the guyb:end skill and follow "Usage limit mode". Do not launch new agents.\n' "$ug_name" "$ug_pct" "$ug_time" >&2
else
  printf 'guyb usage guard: %s plan usage at %s%% (resets %s). Tell the user. Finish running work; do not start new waves or large runs.\n' "$ug_name" "$ug_pct" "$ug_time" >&2
fi
trap 'exit 2' EXIT
return 0
