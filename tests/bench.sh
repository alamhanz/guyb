#!/usr/bin/env bash
# Timing harness for the PreToolUse guard hooks (Bash entries). Not part of CI.
# Usage: bash tests/bench.sh [--root <plugin dir>] [-n N]     (default root: plugins/guyb, N = 10)
# Reads the guard entries from <root>/hooks/hooks.json, exports CLAUDE_PLUGIN_ROOT=<root>, and runs each matching
# entry exactly as Claude Code does (bash -c "<command>") with the scenario JSON on stdin. Hooks of one call run
# in parallel in Claude Code, so a scenario reports the slowest matching entry per run (median and p90, ms).
# Baseline: copy hooks.json and the guards from another revision into a temp dir (git show <rev>:<path>) and pass --root.
# Read-only on the repo; temp dir removed on exit. Needs jq or python3. Targets bash 3.2 (timer: EPOCHREALTIME, date +%s%N, python3).
root=$(cd "$(dirname "$0")/.." && pwd)/plugins/guyb
n=10
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root=$(cd "$2" && pwd) || exit 1; shift 2 ;;
    -n) n=$2; shift 2 ;;
    *) echo "usage: bench.sh [--root <plugin dir>] [-n N]" >&2; exit 2 ;;
  esac
done
case "$n" in ''|*[!0-9]*|0) echo "bench: -n needs a positive integer" >&2; exit 2 ;; esac
[ -f "$root/hooks/hooks.json" ] || { echo "bench: $root/hooks/hooks.json not found" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-bench.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
if command -v cygpath >/dev/null 2>&1; then root=$(cygpath -m "$root"); tmpw=$(cygpath -m "$tmp"); else tmpw=$tmp; fi
export CLAUDE_PLUGIN_ROOT=$root GIT_TERMINAL_PROMPT=0

# millisecond clock
if [ -n "${EPOCHREALTIME:-}" ]; then now() { local t=${EPOCHREALTIME/[.,]/}; now_ms=$((t / 1000)); }
elif [ "$(date +%N 2>/dev/null)" != N ] && [ -n "$(date +%N 2>/dev/null)" ]; then now() { now_ms=$(( $(date +%s%N) / 1000000 )); }
else now() { now_ms=$(python3 -c 'import time; print(int(time.time()*1000))'); }
fi

# guard entries: if-pattern TAB command, Bash shell only
entries=$tmp/entries
if command -v jq >/dev/null 2>&1; then
  jq -r '.hooks.PreToolUse[].hooks[] | select((.shell // "bash") == "bash" and (.command | test("guard-(secrets|readonly)"))) | [(.if // ""), .command] | @tsv' "$root/hooks/hooks.json"
else
  python3 -c '
import json, sys
for e in json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]["PreToolUse"]:
    for h in e["hooks"]:
        if h.get("shell", "bash") == "bash" and ("guard-secrets" in h["command"] or "guard-readonly" in h["command"]):
            print(h.get("if", "") + "\t" + h["command"])' "$root/hooks/hooks.json"
fi | tr -d '\r' > "$entries"
[ -s "$entries" ] || { echo "bench: no Bash guard entries in $root/hooks/hooks.json" >&2; exit 1; }

# fixture repos: clean (secrets guard), alias (ci = commit)
git init -q "$tmp/clean" && git -C "$tmp/clean" config user.email b@b && git -C "$tmp/clean" config user.name b || exit 1
git init -q "$tmp/alias" && git -C "$tmp/alias" config alias.ci commit || exit 1
cw=$tmpw/clean; aw=$tmpw/alias

pad=$(head -c 50000 /dev/zero | tr '\0' 'x')
sc=0
scen() { # id label agent cwd command
  sc=$((sc + 1)); ids="$ids $sc"
  printf '%s' "$1 $2" > "$tmp/label_$sc"; printf '%s' "$5" > "$tmp/cmd_$sc"
  local agent=""; [ "$3" = - ] || agent=",\"agent_type\":\"$3\""
  printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"%s}' "$5" "$4" "$agent" > "$tmp/in_$sc.json"
}
ids=""
scen S1 "main session, git status" - "$cw" "git status"
scen S2 "implementer, cd x && git add ." guyb:implementer "$cw" "cd x && git add ."
scen S3 "code-reviewer, git log -1" guyb:code-reviewer "$cw" "git log -1"
scen S4 "code-reviewer, git add . (blocked)" guyb:code-reviewer "$cw" "git add ."
scen S5 "code-reviewer, git ci -m x (alias)" guyb:code-reviewer "$aw" "git ci -m x"
scen S6 "main session, git commit -m x" - "$cw" "git commit -m x"
scen S7 "implementer, 50 KB command" guyb:implementer "$cw" "echo $pad; git status"

echo "bench: root=$root runs=$n (median / p90 ms of the slowest matching entry)"
printf '%-40s %7s %7s %4s\n' scenario median p90 rc
for i in $ids; do
  label=$(cat "$tmp/label_$i"); cmd=$(cat "$tmp/cmd_$i")
  : > "$tmp/times"; rc=-
  r=0
  while [ "$r" -lt "$n" ]; do
    worst=0
    while IFS="$(printf '\t')" read -r cond hook; do
      pat=${cond#Bash(}; pat=${pat%)}
      # shellcheck disable=SC2254 # the if filter is a glob on purpose
      case "$cmd" in $pat) ;; *) continue ;; esac
      now; t0=$now_ms
      bash -c "$hook" < "$tmp/in_$i.json" > /dev/null 2>&1; code=$?
      now; d=$((now_ms - t0))
      [ "$d" -gt "$worst" ] && worst=$d
      [ "$r" -eq 0 ] && { [ "$rc" = - ] && rc=$code || { [ "$code" -gt "${rc%%,*}" ] && rc=$code; }; }
    done < "$entries"
    echo "$worst" >> "$tmp/times"
    r=$((r + 1))
  done
  sort -n "$tmp/times" > "$tmp/sorted"
  med=$(sed -n "$(( (n + 1) / 2 ))p" "$tmp/sorted")
  p90=$(sed -n "$(( (n * 9 + 9) / 10 ))p" "$tmp/sorted")
  printf '%-40s %7s %7s %4s\n' "$label" "$med" "$p90" "$rc"
done
