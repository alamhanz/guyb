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
    prs=$(cd "$dir" 2>/dev/null && gh pr list --limit 5 2>/dev/null | cut -f1-3 | sed 's/\t/ | /g')
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
      found && /^#/ { exit }
      found && NF { gsub(/^[ \t]+|[ \t]+$/, ""); print "  " $0; if (++c >= 5) exit }
      !found && tolower($0) ~ "^#+[ \t]*" tolower(h) { found = 1 }
    ' "$state")
    [ -n "$sec" ] && { echo "STATE.md $h:"; printf '%s\n' "$sec"; }
  done
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
