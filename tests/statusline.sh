#!/usr/bin/env bash
# Fixture tests for plugins/guyb/statusline/guyb-status.sh. Usage: bash tests/statusline.sh
# Builds throwaway project trees in a temp dir (removed on exit); writes nothing in the repo, no network.
# PowerShell twin: statusline.ps1 (keep the cases and expected lines in sync). Targets bash 3.2.
root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/plugins/guyb/statusline/guyb-status.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-statusline.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd)

fail=0
check() { # name expected actual; on failure prints the bash version and a bash -x trace of the last run
  if [ "$2" = "$3" ]; then echo "ok   $1"; return; fi
  echo "FAIL $1: expected [$2] got [$3]"; fail=$((fail + 1))
  bash --version | head -1
  if [ -f "$tmp/.last.cwd" ]; then
    echo "--- bash -x trace (last 40 lines), stdin: $(cat "$tmp/.last.in")"
    sed 's#^exec 2>/dev/null$#:#' "$script" > "$tmp/.dbg.sh" # the script silences stderr, which is where -x writes
    ( cd "$(cat "$tmp/.last.cwd")" && cat "$tmp/.last.in" | bash -x "$tmp/.dbg.sh" 2>&1 | tail -n 40 )
    echo "---"
  fi
}
run() { # cwd stdin-json (remembered in $tmp/.last.* for check diagnostics)
  printf '%s' "$1" > "$tmp/.last.cwd"; printf '%s' "$2" > "$tmp/.last.in"
  ( cd "$1" && printf '%s' "$2" | bash "$script" 2>&1 )
}
json() { printf '{"session_id":"s","workspace":{"current_dir":"%s","project_dir":"%s"},"cwd":"%s"}' "$1" "$1" "$1"; }
proj() { # name head-line: project with a .git dir
  mkdir -p "$tmp/$1/.git"
  printf '%s\n' "$2" > "$tmp/$1/.git/HEAD"
}
runs() { # dir: runs.md with 2 running rows
  mkdir -p "$1"
  printf '%s\n' '| ID | Agent | Model | Task | Wave | After | Status | Started | Tokens |' \
    '|---|---|---|---|---|---|---|---|---|' \
    '| a-1 | x | m | t | 1 | - | done | d | 1k |' \
    '| a-2 | x | m | t | 1 | - | running | d | 1k |' \
    '| a-3 | x | m | t | 1 | - | running | d | 1k |' > "$1/runs.md"
}
questions() { # dir open-count
  mkdir -p "$1"
  { printf '%s\n' '| ID | Run | Question | Blocking | Assumed | Status |' '|---|---|---|---|---|---|' \
      '| Q1 | a-1 | q | no | a | answered: yes |'
    n=0; while [ "$n" -lt "$2" ]; do n=$((n + 1)); echo "| Q$((n + 1)) | a-1 | q | no | a | open |"; done
  } > "$1/questions.md"
}

# new registry, 2 running, 1 open question, branch from ref
proj new 'ref: refs/heads/main'
runs "$tmp/new/.claude/guyb/pipeline"; questions "$tmp/new/.claude/guyb/pipeline" 1
check "new registry" "guyb > new  main  2 running  1 question" "$(run "$tmp" "$(json "$tmp/new")")"
mkdir -p "$tmp/new/a/b"
check "subdirectory finds root" "guyb > new  main  2 running  1 question" "$(run "$tmp" "$(json "$tmp/new/a/b")")"
questions "$tmp/new/.claude/guyb/pipeline" 2
check "plural questions" "guyb > new  main  2 running  2 questions" "$(run "$tmp" "$(json "$tmp/new")")"
proj br 'ref: refs/heads/feat/x'
check "branch with slash" "guyb > br  feat/x" "$(run "$tmp" "$(json "$tmp/br")")"

# only cwd; workspace.current_dir wins over cwd; PWD fallback on empty or garbled stdin
check "only cwd" "guyb > new  main  2 running  2 questions" "$(run "$tmp" "{\"cwd\":\"$tmp/new\"}")"
# JSON with a comma goes through a variable: bash 3.2 brace-expands {a,b} inside "$(... "..." ...)"
j="{\"cwd\":\"$tmp/new\",\"workspace\":{\"current_dir\":\"$tmp/br\"}}"
check "current_dir wins" "guyb > br  feat/x" "$(run "$tmp" "$j")"
j="{\"workspace\":{\"current_dir\":\"$tmp/br\"},\"cwd\":\"$tmp/new\"}"
check "current_dir first, differs from cwd" "guyb > br  feat/x" "$(run "$tmp" "$j")"
j="{\"cwd\": \"$tmp/new\", \"workspace\": { \"current_dir\" : \"$tmp/br\" }}"
check "whitespace around colon" "guyb > br  feat/x" "$(run "$tmp" "$j")"
check "BOM on stdin" "guyb > br  feat/x" "$(run "$tmp" "$(printf '\357\273\277'; printf '{"cwd":"%s"}' "$tmp/br")")"
check "empty stdin uses PWD" "guyb > br  feat/x" "$(run "$tmp/br" "")"
check "garbled stdin uses PWD" "guyb > br  feat/x" "$(run "$tmp/br" '{not json "cwd": ')"
check "missing dir uses PWD" "guyb > br  feat/x" "$(run "$tmp/br" "{\"cwd\":\"$tmp/nope\"}")"
rm -f "$tmp/.last.cwd"
check "no stdin (null device)" "guyb > br  feat/x" "$(cd "$tmp/br" && bash "$script" < /dev/null 2>&1)"

# legacy registry: only when STATE.md is guyb-owned; new wins when both exist
proj leg 'ref: refs/heads/dev'
runs "$tmp/leg/.claude/pipeline"; questions "$tmp/leg/.claude/pipeline" 1
printf '%s\n' '# T' '## Decisions' > "$tmp/leg/.claude/STATE.md"
check "legacy not owned" "guyb > leg  dev" "$(run "$tmp" "$(json "$tmp/leg")")"
printf '%s\r\n' '<!-- guyb:state -->' '# T' > "$tmp/leg/.claude/STATE.md"
check "legacy owned by marker (CRLF)" "guyb > leg  dev  2 running  1 question" "$(run "$tmp" "$(json "$tmp/leg")")"
{ printf '\357\273\277'; printf '%s\n' '# Next up' '## open issues' '### DECISIONS' '# Recent changes'; } > "$tmp/leg/.claude/STATE.md"
check "legacy owned by headings (BOM)" "guyb > leg  dev  2 running  1 question" "$(run "$tmp" "$(json "$tmp/leg")")"
mkdir -p "$tmp/leg/.claude/guyb/pipeline"
printf '%s\n' '| ID | Status |' '|---|---|' '| n-1 | running |' > "$tmp/leg/.claude/guyb/pipeline/runs.md"
check "both present, new wins" "guyb > leg  dev  1 running  1 question" "$(run "$tmp" "$(json "$tmp/leg")")"
printf '%s\n' '| Status | ID |' '|---|---|' '| Running | n-1 |' '| running | |' > "$tmp/leg/.claude/guyb/pipeline/runs.md"
check "columns by header name, blank id skipped" "guyb > leg  dev  1 running  1 question" "$(run "$tmp" "$(json "$tmp/leg")")"

# zero counts, non-git, detached HEAD, worktree gitdir file, spaces, non-ASCII
proj zero 'ref: refs/heads/main'
runs "$tmp/zero/.claude/guyb/pipeline"; sed 's/running/done/' "$tmp/zero/.claude/guyb/pipeline/runs.md" > "$tmp/runs.tmp"
cp "$tmp/runs.tmp" "$tmp/zero/.claude/guyb/pipeline/runs.md"
check "zero counts omitted" "guyb > zero  main" "$(run "$tmp" "$(json "$tmp/zero")")"
mkdir -p "$tmp/nogit"
check "non-git dir" "guyb > nogit" "$(run "$tmp" "$(json "$tmp/nogit")")"
proj det 'abcdef0123456789abcdef0123456789abcdef01'
check "detached HEAD" "guyb > det  abcdef0" "$(run "$tmp" "$(json "$tmp/det")")"
mkdir -p "$tmp/gd/main.git" "$tmp/wt-abs" "$tmp/wt-rel"
printf '%s\n' 'ref: refs/heads/wt-branch' > "$tmp/gd/main.git/HEAD"
printf 'gitdir: %s\n' "$tmp/gd/main.git" > "$tmp/wt-abs/.git"
printf 'gitdir: %s\n' "../gd/main.git" > "$tmp/wt-rel/.git"
check "worktree gitdir (absolute)" "guyb > wt-abs  wt-branch" "$(run "$tmp" "$(json "$tmp/wt-abs")")"
check "worktree gitdir (relative)" "guyb > wt-rel  wt-branch" "$(run "$tmp" "$(json "$tmp/wt-rel")")"
proj "my app" 'ref: refs/heads/main'
check "name with spaces" "guyb > my app  main" "$(run "$tmp" "$(json "$tmp/my app")")"
uni="caf$(printf '\303\251')"
proj "$uni" 'ref: refs/heads/main'
check "non-ASCII name gives ASCII output" "guyb > caf??  main" "$(run "$tmp" "$(json "$tmp/$uni")")"

# Windows-style path in JSON (needs a converter: cygpath on Git Bash, wslpath on WSL)
conv=
if command -v cygpath >/dev/null 2>&1; then conv='cygpath -m'
elif command -v wslpath >/dev/null 2>&1 && wslpath -m / 2>/dev/null | grep -q ':'; then conv='wslpath -m'; fi
if [ -n "$conv" ]; then
  win=$($conv "$tmp/new" | sed 's#/#\\\\#g')
  check "Windows-style path, escaped backslashes" "guyb > new  main  2 running  2 questions" "$(run "$tmp" "{\"workspace\":{\"current_dir\":\"$win\"}}")"
  win=$($conv "$tmp/new")
  check "Windows-style path, forward slashes" "guyb > new  main  2 running  2 questions" "$(run "$tmp" "{\"cwd\":\"$win\"}")"
else echo "skip Windows-style path (no cygpath/wslpath)"; fi

# loose timing sanity
s=$(date +%s); run "$tmp" "$(json "$tmp/new")" > /dev/null; e=$(date +%s)
if [ $((e - s)) -le 3 ]; then echo "ok   runtime under 3s"; else echo "FAIL runtime over 3s"; fail=$((fail + 1)); fi

if [ "$fail" -eq 0 ]; then echo "statusline: all passed"; else echo "statusline: $fail failed"; fi
[ "$fail" -eq 0 ]
