#!/usr/bin/env bash
# Read-only session briefing for /guyb:start. No prompts, no cd, no secrets. Usage: brief.sh [project folder]
dir="${1:-$PWD}"
dir="${dir%/}"
export GIT_TERMINAL_PROMPT=0

echo "project: $(basename "$dir")"

max_parallel=5; max_src=default
for c in "$dir/.claude/CLAUDE.md:project" "$HOME/.claude/guyb/profile.md:profile"; do
  [ -f "${c%:*}" ] || continue
  v=$(sed -nE 's/^[[:space:]]*([-*][[:space:]]+)?[`*]*max_parallel[`*]*[[:space:]]*:[`*[:space:]]*([0-9]{1,2})[`*[:space:]]*$/\2/p' "${c%:*}" | awk '$1 + 0 >= 1 && $1 + 0 <= 20 { print $1 + 0; exit }')
  if [ -n "$v" ]; then max_parallel=$v; max_src=${c##*:}; break; fi
done
echo "max parallel: $max_parallel ($max_src)"

# Outdated plugin flag: installed guyb@guyb vs the local marketplace source. Silent on any gap.
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
inst_f="$cfg/plugins/installed_plugins.json"
mk_f="$cfg/plugins/known_marketplaces.json"
if [ -f "$inst_f" ] && [ -f "$mk_f" ]; then
  if command -v jq >/dev/null 2>&1; then
    inst=$(jq -r '.plugins["guyb@guyb"][0].version // empty' "$inst_f" 2>/dev/null | tr -d '\r')
    srcdir=$(jq -r '.guyb.source.path // empty' "$mk_f" 2>/dev/null | tr -d '\r')
  else
    inst=$(tr -d '\r' < "$inst_f" | awk '
      !f { i = index($0, "\"guyb@guyb\""); if (i) { f = 1; $0 = substr($0, i) } }
      f && match($0, /"version"[ \t]*:[ \t]*"[^"]*"/) {
        v = substr($0, RSTART, RLENGTH); sub(/^"version"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v); print v; exit
      }')
    srcdir=$(tr -d '\r' < "$mk_f" | awk '
      !f && match($0, /"guyb"[ \t]*:/) { f = 1; $0 = substr($0, RSTART + RLENGTH) }
      f {
        e = index($0, "\"installLocation\""); if (e) { t = substr($0, 1, e - 1) } else { t = $0 }
        if (match(t, /"path"[ \t]*:[ \t]*"([^"\\]|\\.)*"/)) {
          v = substr(t, RSTART, RLENGTH); sub(/^"path"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v); print v; exit
        }
        if (e || index($0, "\"lastUpdated\"")) exit
      }')
  fi
  case "$srcdir" in *\\*) srcdir=$(printf '%s' "$srcdir" | sed 's/\\\\/\\/g') ;; esac
  case "$srcdir" in
    [A-Za-z]:[\\/]*)
      if command -v cygpath >/dev/null 2>&1; then srcdir=$(cygpath -u "$srcdir" 2>/dev/null)
      elif command -v wslpath >/dev/null 2>&1; then srcdir=$(wslpath -u "$srcdir" 2>/dev/null); fi ;;
  esac
  pj="$srcdir/plugins/guyb/.claude-plugin/plugin.json"
  if [ -n "$inst" ] && [ -n "$srcdir" ] && [ -f "$pj" ]; then
    if command -v jq >/dev/null 2>&1; then
      avail=$(jq -r '.version // empty' "$pj" 2>/dev/null | tr -d '\r')
    else
      avail=$(tr -d '\r' < "$pj" | awk 'match($0, /"version"[ \t]*:[ \t]*"[^"]*"/) {
        v = substr($0, RSTART, RLENGTH); sub(/^"version"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v); print v; exit }')
    fi
    behind=$(awk -v a="$inst" -v b="$avail" 'BEGIN {
      sub(/[-+].*$/, "", a); sub(/[-+].*$/, "", b)
      if (a !~ /^[0-9]+(\.[0-9]+)*$/ || b !~ /^[0-9]+(\.[0-9]+)*$/) exit
      na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb) ? na : nb
      for (i = 1; i <= n; i++) {
        if (x[i] + 0 < y[i] + 0) { print 1; exit }
        if (x[i] + 0 > y[i] + 0) exit
      }
    }')
    [ "$behind" = "1" ] && echo "plugin: $inst installed, $avail available - run: claude plugin marketplace update guyb; claude plugin update guyb@guyb"
  fi
fi

if [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if ab=$(git -C "$dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
    set -- $ab
    sync="ahead $2, behind $1"
  else
    sync="no upstream"
  fi
  echo "branch: $branch ($sync)"

  dirty=$(git -C "$dir" status --short 2>/dev/null)
  n=0
  [ -n "$dirty" ] && n=$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')
  echo "uncommitted: $n file(s)"
  [ "$n" -gt 0 ] && printf '%s\n' "$dirty" | head -10 | sed 's/^/  /'
  [ "$n" -gt 10 ] && echo "  ... +$((n - 10)) more"

  if ! grep -qE '^/?\.claude/?(pipeline/?)?[[:space:]]*$' "$dir/.gitignore" 2>/dev/null; then
    echo "gitignore: .claude/pipeline/ not ignored"
  fi

  echo "last commits:"
  git -C "$dir" log --oneline -5 2>/dev/null | sed 's/^/  /'

  if command -v gh >/dev/null 2>&1; then
    prs=$(cd "$dir" 2>/dev/null && gh pr list --limit 5 2>/dev/null | cut -f1-3 | awk -F'\t' '{ print $1 " | " $2 " | " $3 }')
    if [ -n "$prs" ]; then
      echo "open PRs:"
      printf '%s\n' "$prs" | sed 's/^/  /'
    fi
  fi
else
  echo "git: not a repository"
fi

state="$dir/.claude/STATE.md"
if [ -f "$state" ]; then
  for h in "Next up" "Open issues"; do
    sec=$(awk -v h="$h" '
      { sub(/\r$/, "") }
      found && /^#/ { exit }
      found && NF { gsub(/^[ \t]+|[ \t]+$/, ""); print "  " $0; if (++c >= 5) exit }
      !found && tolower($0) ~ "^#+[ \t]*" tolower(h) { found = 1 }
    ' "$state")
    [ -n "$sec" ] && { echo "STATE.md $h:"; printf '%s\n' "$sec"; }
  done
  # Drift: PRs named in live-state sections of STATE.md (Current Status, Open Issues, Next Up, In progress, Open PRs) that are already merged or closed (max 3 gh calls, silent on failure).
  if [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] && command -v gh >/dev/null 2>&1; then
    tmo=
    command -v timeout >/dev/null 2>&1 && tmo=timeout
    [ -z "$tmo" ] && command -v gtimeout >/dev/null 2>&1 && tmo=gtimeout
    for n in $(tr -d '\r' < "$state" | awk '/^#/ { l = (tolower($0) ~ /^#+[ \t]*(current status|open issues|next up|in progress|open prs)/); next } l' | grep -oiE '(^|[^[:alnum:]])(#|pull/|pr[[:space:]]+#?)[0-9]+' | grep -oE '[0-9]+$' | awk '!s[$0]++' | head -3); do
      if [ -n "$tmo" ]; then
        st=$(cd "$dir" 2>/dev/null && "$tmo" 5 gh pr view "$n" --json state -q .state 2>/dev/null | tr -d '\r')
      else
        st=$(cd "$dir" 2>/dev/null && gh pr view "$n" --json state -q .state 2>/dev/null | tr -d '\r')
      fi
      case "$st" in MERGED|CLOSED) echo "STATE.md drift: PR #$n is $st - update STATE.md" ;; esac
    done
  fi
else
  echo "STATE.md: missing"
fi

runs="$dir/.claude/pipeline/runs.md"
if [ -f "$runs" ]; then
  unf=$(grep -E '^\|.*\|[[:space:]]*(running|queued)[[:space:]]*\|' "$runs")
  if [ -n "$unf" ]; then
    echo "unfinished runs ($(printf '%s\n' "$unf" | wc -l | tr -d ' ')):"
    printf '%s\n' "$unf" | head -5 | sed -E 's/^\|[[:space:]]*//; s/[[:space:]]*\|[[:space:]]*/ | /g; s/ \| $//; s/^/  /'
  fi
fi

qs="$dir/.claude/pipeline/questions.md"
if [ -f "$qs" ]; then
  open=$(grep -E '^\|[[:space:]]*Q[0-9]+.*\|[[:space:]]*open[[:space:]]*\|' "$qs")
  if [ -n "$open" ]; then
    echo "open questions ($(printf '%s\n' "$open" | wc -l | tr -d ' ')):"
    printf '%s\n' "$open" | head -5 | cut -d'|' -f2-5 | sed -E 's/^[[:space:]]*//; s/[[:space:]]*\|[[:space:]]*/ | /g; s/^/  /'
  fi
fi
