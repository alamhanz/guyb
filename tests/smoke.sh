#!/usr/bin/env bash
# Smoke tests for the bash helper scripts (brief.sh, check.sh, guard-secrets.sh, guard-readonly.sh).
# Usage: bash tests/smoke.sh. Builds throwaway git repos and a fake HOME in a temp dir (removed on exit);
# writes nothing in the repo, needs no network or secrets, and stubs gh. Targets bash 3.2.
# The independent groups of cases run as background jobs (GUYB_TEST_JOBS, default 8), each with its own fixtures and HOME.
# PowerShell twin: smoke.ps1 (keep the cases in sync).
# The guard hooks are sourced in subshells (as hooks.json does), which shellcheck cannot follow.
# shellcheck disable=SC1090
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-smoke.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
export GIT_TERMINAL_PROMPT=0
unset CLAUDE_CONFIG_DIR

# Mixed (C:/...) paths survive both git and native tools under Git Bash; elsewhere paths pass through.
# Paths under $tmp are rewritten with parameter expansion (no cygpath fork per call).
win() {
  case "$1" in
    "$tmp"/*) printf %s "${tmp_w}${1#"$tmp"}" ;;
    *) if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf %s "$1"; fi ;;
  esac
}
if command -v cygpath >/dev/null 2>&1; then tmp_w=$(cygpath -m "$tmp"); else tmp_w=$tmp; fi

pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
expect_has() { if has "$2" "$3"; then ok; else no "$1: missing '$3'"; fi; }
expect_lacks() { if has "$2" "$3"; then no "$1: unexpected '$3'"; else ok; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok; else no "$1: got '$2', want '$3'"; fi; }
cnt() { cnt_n=0; while IFS= read -r cnt_l; do case $cnt_l in *"$2"*) cnt_n=$((cnt_n + 1)) ;; esac; done < "$1"; } # file substring: lines containing it, in $cnt_n

json_ok() { # file
  if command -v jq >/dev/null 2>&1; then jq empty "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" >/dev/null 2>&1
  elif command -v pwsh >/dev/null 2>&1; then pwsh -NoProfile -Command 'Get-Content -Raw -LiteralPath $args[0] | ConvertFrom-Json | Out-Null' "$1" >/dev/null 2>&1
  else return 0; fi
}

# Fake HOME: no real profile, config, or git identity is read. Every group gets its own below this one.
home="$tmp/home"; mkdir -p "$home/.claude"
export HOME="$home"
export USERPROFILE="$home"

# Stub gh. `pr list` prints $GH_STUB_LIST (tab-separated number, state, title, branch lines; exit 1 with GH_STUB_LISTFAIL);
# GH_STUB_LISTRC makes `pr list` exit with that code (4 = not logged in); `pr view N` prints $GH_STUB_STATE; anything else fails quietly (no network). GH_STUB_SLEEP delays every call, GH_STUB_LOG records the arguments.
stub="$tmp/stub"; mkdir -p "$stub"
cat > "$stub/gh" <<'STUB'
#!/bin/sh
[ -n "$GH_STUB_LOG" ] && echo "$*" >> "$GH_STUB_LOG"
[ -n "$GH_STUB_SLEEP" ] && sleep "$GH_STUB_SLEEP"
if [ "$1" = pr ] && [ "$2" = list ]; then
  [ -n "$GH_STUB_LISTFAIL" ] && exit 1
  [ -n "$GH_STUB_LISTRC" ] && exit "$GH_STUB_LISTRC"
  [ -n "$GH_STUB_LIST" ] && printf '%s\n' "$GH_STUB_LIST"
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = view ]; then echo "${GH_STUB_STATE:-OPEN}"; exit 0; fi
exit 1
STUB
chmod +x "$stub/gh"
export PATH="$stub:$PATH"

# One git repo is built here and copied per fixture (cp is one fork; init, 3 config, add and commit are not).
fx_tpl="$tmp/fx-template"; mkdir -p "$fx_tpl/.claude/guyb"; fx_w=${fx_tpl/#"$tmp"/$tmp_w}
git -C "$fx_w" init -q --template= 2>/dev/null
git -C "$fx_w" config user.name smoke
git -C "$fx_w" config user.email smoke@example.invalid
git -C "$fx_w" config commit.gpgsign false
printf '# fixture\n' > "$fx_tpl/README.md"
printf '# fixture\r\n\r\nmax_parallel: 3\r\n' > "$fx_tpl/.claude/CLAUDE.md"
printf '# State\r\n\r\n## Next up\r\n- ship the thing\r\n\r\n## Open issues\r\n- PR #7 awaiting review\r\n- flaky test\r\n' > "$fx_tpl/.claude/guyb/STATE.md"
git -C "$fx_w" add -A >/dev/null 2>&1
git -C "$fx_w" commit -q -m init >/dev/null 2>&1
make_fixture() { mkdir -p "$1" && cp -R "$fx_tpl/." "$1/"; } # dir

runners="bash"
# /bin/bash joins the matrix only when it is a different file than the bash on PATH (same binary twice adds no coverage, costs ~35 s of forks on Git Bash).
bash_path=$(command -v bash)
[ -x /bin/bash ] && ! [ /bin/bash -ef "$bash_path" ] && runners="$runners /bin/bash"
command -v zsh >/dev/null 2>&1 && runners="$runners zsh"
run() { # runner script args...
  r=$1; shift
  if [ "$r" = zsh ]; then zsh -c 'bash "$@"' zsh "$@"; else "$r" "$@"; fi
}

brief="$root/plugins/guyb/skills/start/brief.sh"
check="$root/plugins/guyb/skills/setup/check.sh"
jobs_max=${GUYB_TEST_JOBS:-8}
root_w=$(win "$root")

# Fixture helpers for migration and cleanup cases (bash 3.2, BSD touch -t for mtimes).
gen_lines() { awk -v n="$1" -v p="$2" 'BEGIN { for (i = 1; i <= n; i++) print p " " i }'; } # count prefix
gen_table() { # file header count id-prefix status
  { printf '%s\n|---|\n' "$2"; awk -v n="$3" -v p="$4" -v s="$5" 'BEGIN { for (i = 1; i <= n; i++) print "| " p i " | x-1 | q | no | a | " s " |" }'; } > "$1"
}
RUNHDR='| ID | Agent | Model | Task | Wave | After | Status | Started | Tokens |'
runrow() { printf '| %s | implementer | sonnet | t | 1 | - | %s | %s | 1k |\n' "$1" "$2" "$3"; } # id status date
GUYB_OLD_STATE='# State\n\n## Next up\n- OLD-NEXT\n\n## Open issues\n- old issue\n\n## Decisions\n- d\n\n## Recent changes\n- c\n'
today=$(date +%Y-%m-%d)

# Stubs and script variants shared (read-only) by the groups below.
mkdir -p "$tmp/dfail" "$tmp/dsleep" "$tmp/nsleep"
printf '#!/bin/sh\nexit 1\n' > "$tmp/dfail/docker"; printf '#!/bin/sh\nsleep 120 &\nsleep 120\n' > "$tmp/dsleep/docker"
printf '#!/bin/sh\nsleep 300 &\nsleep 300\n' > "$tmp/nsleep/node"
chmod +x "$tmp/dfail/docker" "$tmp/dsleep/docker" "$tmp/nsleep/node"
# Hung-probe stubs sleep 120 s (node: 300 s, check.sh alone takes ~20 s on Windows) and the checks only assert "well under that", so a loaded machine does not flake them.
# Run twice: as shipped, and with timeout/gtimeout hidden (stock macOS) to exercise the poll-and-kill fallback.
sed -e 's/command -v timeout /command -v no-such-timeout /' -e 's/command -v gtimeout /command -v no-such-gtimeout /' "$brief" > "$tmp/brief-notmo.sh"
sed -e 's/has timeout \&\& tmo=timeout/has no-such-timeout \&\& tmo=timeout/' -e 's/has gtimeout \&\& /has no-such-gtimeout \&\& /' "$check" > "$tmp/check-notmo.sh"
ee="$tmp/envempty"; mkdir -p "$ee"; ee_w=${ee/#"$tmp"/$tmp_w}
en2="$tmp/envnode2"; mkdir -p "$en2"; printf '{"name":"x"}\n' > "$en2/package.json"; en2_w=${en2/#"$tmp"/$tmp_w}
ed="$tmp/envdocker"; mkdir -p "$ed"; : > "$ed/compose.yaml"; ed_w=${ed/#"$tmp"/$tmp_w}

# ---- groups: each runs in a background subshell with its own HOME and fixtures; output is replayed in spawn order ----

g_matrix() { # runner index
  r=$1
  echo "brief.sh and check.sh on fixtures ($r)"
  md="$tmp/mx$2"; mkdir -p "$md"
  a="$md/proj"; b="$md/my proj [v2]"
  make_fixture "$a"; make_fixture "$b"
  mx="$md/out"; mkdir -p "$mx"; mx_w=${mx/#"$tmp"/$tmp_w}
  mx_case() { # index dir: brief + check output, exit codes, to $mx/<index>.*
    i=$1; dw=${2/#"$tmp"/$tmp_w}
    run "$r" "$brief" "$dw" > "$mx/$i.brief" 2>&1; echo $? > "$mx/$i.brc"
    run "$r" "$check" "$dw" > "$mx/$i.check" 2>/dev/null; echo $? > "$mx/$i.crc"
  }
  n=0
  for d in "$a" "$b"; do
    n=$((n + 1)); mx_case "$n" "$d" &
  done
  wait
  n=0
  for d in "$a" "$b"; do
    n=$((n + 1)); name=${d##*/}
    IFS= read -r -d '' out < "$mx/$n.brief"; read -r rc < "$mx/$n.brc"; read -r crc < "$mx/$n.crc"; IFS= read -r -d '' chk < "$mx/$n.check"
    cr=${out//[!$'\r']/}
    expect_eq "brief $r $name exit" "$rc" 0
    expect_has "brief $r $name" "$out" "project: $name"
    expect_has "brief $r $name" "$out" "branch: "
    expect_has "brief $r $name" "$out" "max parallel: 3 (project)"
    expect_has "brief $r $name" "$out" "STATE.md Next up:"
    expect_has "brief $r $name" "$out" "STATE.md Open issues:"
    expect_eq "brief $r $name CR count" "${#cr}" 0
    expect_lacks "brief $r $name" "$out" "plugin: "
    expect_lacks "brief $r $name" "$out" "migrate:"
    expect_has "brief $r $name" "$out" "gitignore: .claude/guyb/pipeline/ not ignored"
    expect_eq "check $r $name exit" "$crc" 0
    if json_ok "${mx_w}/$n.check"; then ok; else no "check $r $name: output is not valid JSON"; fi
    expect_has "check $r $name" "$chk" '"version": 1'
  done
}

g_plugin() {
  echo "brief.sh outdated plugin flag"
  pa="$tmp/f-plug"; make_fixture "$pa"; pa_w=${pa/#"$tmp"/$tmp_w}
  cfg="$HOME/.claude/plugins"; mk="$tmp/marketplace"; mk_w=${mk/#"$tmp"/$tmp_w}
  mkdir -p "$cfg" "$mk/plugins/guyb/.claude-plugin"
  printf '{"name":"guyb","version":"0.7.0"}\n' > "$mk/plugins/guyb/.claude-plugin/plugin.json"
  printf '{"guyb":{"source":{"source":"directory","path":"%s"}}}\n' "${mk_w}" > "$cfg/known_marketplaces.json"
  sed 's/command -v jq /command -v no-such-jq /' "$brief" > "$tmp/brief-nojq.sh"
  if cmp -s "$brief" "$tmp/brief-nojq.sh"; then no "plugin flag: no-jq copy equals brief.sh (pattern stale)"; else ok; fi
  want="plugin: 0.6.0 installed, 0.7.0 available - run: claude plugin marketplace update guyb; claude plugin update guyb@guyb"
  for v in 0.6.0 0.7.0 0.8.0; do
    printf '{"version":2,"plugins":{"guyb@guyb":[{"scope":"user","version":"%s"}]}}\n' "$v" > "$cfg/installed_plugins.json"
    out=$(bash "$brief" "${pa_w}" 2>&1)
    if [ "$v" = 0.6.0 ]; then expect_has "plugin flag $v" "$out" "$want"; else expect_lacks "plugin flag $v" "$out" "plugin: "; fi
    if [ "$v" != 0.7.0 ]; then # the awk/sed fallback used when jq is missing, on every runner
      out=$(bash "$tmp/brief-nojq.sh" "${pa_w}" 2>&1)
      if [ "$v" = 0.6.0 ]; then expect_has "plugin flag $v without jq" "$out" "$want"; else expect_lacks "plugin flag $v without jq" "$out" "plugin: "; fi
    fi
  done
}

g_drift() {
  echo "brief.sh STATE.md drift (stub gh)"
  pd="$tmp/f-drift"; make_fixture "$pd"; pd_w=${pd/#"$tmp"/$tmp_w}
  out=$(GH_STUB_STATE=OPEN bash "$brief" "${pd_w}" 2>&1)
  expect_lacks "drift OPEN" "$out" "STATE.md drift"
  # state from the PR list: no `gh pr view` call, only open PRs printed (first 5, list shape "number | title | branch")
  lg="$tmp/ghlog-list"; : > "$lg"
  list=$(printf '9\tOPEN\tadd widget\tfeat/widget\n7\tMERGED\tship it\tfix/ship\n3\tCLOSED\told\told\n2\tOPEN\tsecond\tfeat/second')
  out=$(GH_STUB_LOG="$lg" GH_STUB_LIST="$list" GH_STUB_STATE=OPEN bash "$brief" "${pd_w}" 2>&1)
  expect_has "drift from list" "$out" "STATE.md drift: PR #7 is MERGED - update STATE.md"
  cnt "$lg" 'pr view'; expect_eq "drift from list: no pr view" "$cnt_n" 0
  cnt "$lg" 'pr list'; expect_eq "list call made once" "$cnt_n" 1
  expect_has "open PRs header" "$out" "open PRs:"
  expect_has "open PR line" "$out" "  9 | add widget | feat/widget"
  expect_has "open PR line" "$out" "  2 | second | feat/second"
  expect_lacks "merged PR not listed as open" "$out" "ship it"
  expect_lacks "closed PR not listed as open" "$out" "| old"
  # PR named in STATE.md but not among the listed ones: one `pr view`
  : > "$lg"
  out=$(GH_STUB_LOG="$lg" GH_STUB_LIST="$(printf '9\tOPEN\tadd widget\tfeat/widget')" GH_STUB_STATE=MERGED bash "$brief" "${pd_w}" 2>&1)
  expect_has "drift view fallback" "$out" "STATE.md drift: PR #7 is MERGED - update STATE.md"
  cnt "$lg" 'pr view 7'; expect_eq "drift view fallback: one pr view" "$cnt_n" 1
  # list call failing (not logged in): no PR lines, drift falls back to pr view
  out=$(GH_STUB_LISTFAIL=1 GH_STUB_STATE=MERGED bash "$brief" "${pd_w}" 2>&1)
  expect_has "drift after failed list" "$out" "STATE.md drift: PR #7 is MERGED - update STATE.md"
  expect_lacks "failed list prints no PRs" "$out" "open PRs:"
}

g_ghsleep() { # script label: a hanging gh must not stall the brief (5s budget; with and without a timeout binary)
  echo "brief.sh hung gh $2"
  ps="$tmp/f-sleep-$2"; make_fixture "$ps"; ps_w=${ps/#"$tmp"/$tmp_w}
  lg="$tmp/ghlog-sleep-$2"; : > "$lg"
  t0=$SECONDS
  out=$(GH_STUB_LOG="$lg" GH_STUB_SLEEP=120 GH_STUB_LIST="$(printf '7\tMERGED\tship it\tfix/ship\n9\tOPEN\tadd widget\tfeat/widget')" bash "$1" "${ps_w}" 2>&1)
  dt=$((SECONDS - t0))
  if [ "$dt" -lt 100 ]; then ok; else no "hung gh $2: brief took ${dt}s"; fi
  expect_lacks "hung gh $2 no PR lines" "$out" "open PRs:"
  expect_lacks "hung gh $2 no drift" "$out" "STATE.md drift"
  expect_has "hung gh $2 rest of the brief" "$out" "STATE.md Next up:"
  cnt "$lg" 'pr view'; expect_eq "hung gh $2: only the list call" "$cnt_n" 0
}

g_migration() {
  echo "brief.sh migration detection (legacy STATE.md and pipeline)"
  lg="$tmp/legacy"; make_fixture "$lg"; lg_w=${lg/#"$tmp"/$tmp_w}
  mkdir -p "$lg/.claude/pipeline/progress"; : > "$lg/.claude/pipeline/progress/z-9.md"
  touch -t 202001010000 "$lg/.claude/pipeline/progress/z-9.md"
  mv "$lg/.claude/guyb/STATE.md" "$lg/.claude/STATE.md"; rmdir "$lg/.claude/guyb"
  printf "$GUYB_OLD_STATE" > "$lg/.claude/STATE.md"
  { echo "$RUNHDR"; echo '|---|'; runrow x-1 running "$today"; } > "$lg/.claude/pipeline/runs.md"
  out=$(bash "$brief" "${lg_w}" 2>&1)
  expect_has "migrate legacy" "$out" "migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/"
  expect_lacks "migrate legacy" "$out" "conflict:"
  expect_has "migrate legacy fallback" "$out" "STATE.md Next up:"
  expect_has "migrate legacy fallback" "$out" "OLD-NEXT"
  expect_has "migrate legacy runs" "$out" "unfinished runs (1):"
  expect_has "cleanup stale in legacy pipeline" "$out" "cleanup: 1 pipeline files older than 14 days"
  expect_has "migrate legacy gitignore" "$out" "gitignore: .claude/guyb/pipeline/ not ignored"
  printf '.claude/pipeline/\n' > "$lg/.gitignore"
  out=$(bash "$brief" "${lg_w}" 2>&1)
  expect_lacks "legacy gitignore accepted while legacy pipe is used" "$out" "gitignore:"
  printf '<!-- guyb:state -->\n# State\n' > "$lg/.claude/STATE.md"
  out=$(bash "$brief" "${lg_w}" 2>&1)
  expect_has "migrate marker file" "$out" "migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/"
  printf '\357\273\277<!-- guyb:state -->\n# State\n' > "$lg/.claude/STATE.md"
  out=$(bash "$brief" "${lg_w}" 2>&1)
  expect_has "migrate BOM before marker" "$out" "migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/"
  printf '# Project\r\n\r\n## Overview\r\n\r\n## Next Up\r\n- TC-NEXT\r\n\r\n## Open Issues\r\n\r\n## Last Updated\r\n2026-01-01\r\n\r\n## Decisions\r\n\r\n## Recent Changes\r\n' > "$lg/.claude/STATE.md"
  out=$(bash "$brief" "${lg_w}" 2>&1)
  expect_has "migrate real-world title-case headings" "$out" "migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/"
  expect_has "migrate real-world headings read" "$out" "TC-NEXT"
  printf '# Notes\n\n## Next up\n\n## Open issues\n\n## Decisions\n- FOREIGN3\n' > "$lg/.claude/STATE.md"
  out=$(bash "$brief" "${lg_w}" 2>&1)
  expect_lacks "foreign file with 3 of 4 headings" "$out" "migrate: move .claude/STATE.md"
  expect_lacks "foreign file with 3 of 4 headings" "$out" "FOREIGN3"
  printf '# Notes from another tool\n\n## Next up\n- FOREIGN-NEXT\n' > "$lg/.claude/STATE.md"
  out=$(bash "$brief" "${lg_w}" 2>&1)
  expect_has "foreign STATE.md not moved" "$out" "migrate: move .claude/pipeline/ to .claude/guyb/"
  expect_lacks "foreign STATE.md not moved" "$out" "migrate: move .claude/STATE.md"
  expect_lacks "foreign STATE.md not read" "$out" "FOREIGN-NEXT"
  expect_has "foreign STATE.md not read" "$out" "STATE.md: missing"
}

g_migration_new() {
  echo "brief.sh migration detection (new layout beside legacy files)"
  a="$tmp/f-mig"; make_fixture "$a"; a_w=${a/#"$tmp"/$tmp_w}
  printf "$GUYB_OLD_STATE" > "$a/.claude/STATE.md"
  out=$(bash "$brief" "${a_w}" 2>&1)
  expect_has "migrate both STATE" "$out" "conflict: .claude/STATE.md and .claude/guyb/STATE.md both exist"
  expect_lacks "migrate both STATE" "$out" "OLD-NEXT"
  expect_has "migrate both STATE" "$out" "ship the thing"
  printf '# Notes from another tool\n' > "$a/.claude/STATE.md"
  out=$(bash "$brief" "${a_w}" 2>&1)
  expect_lacks "foreign STATE.md beside new one" "$out" "migrate:"
  rm -f "$a/.claude/STATE.md"
  mkdir -p "$a/.claude/pipeline" "$a/.claude/guyb/pipeline"
  out=$(bash "$brief" "${a_w}" 2>&1)
  expect_has "migrate both pipeline" "$out" "migrate: conflict: .claude/pipeline/ and .claude/guyb/pipeline/ both exist"
}

g_emptysec() {
  echo "brief.sh empty section, question rows, root dir"
  ep="$tmp/empty-sec"; mkdir -p "$ep/.claude/guyb/pipeline"; ep_w=${ep/#"$tmp"/$tmp_w}
  printf '# Next up\n\n# Open issues\n- one\n' > "$ep/.claude/guyb/STATE.md"
  printf '| Q | Question | Run | Status |\n|---|---|---|---|\n| Q1 | what | me | open |\n| Q2 | a |  | open |\n' > "$ep/.claude/guyb/pipeline/questions.md"
  out=$(bash "$brief" "${ep_w}" 2>&1)
  expect_lacks "empty section heading" "$out" "STATE.md Next up:"
  expect_has "empty section heading" "$out" "STATE.md Open issues:"
  expect_has "question row no trailing space" "$out" "  Q1 | what | me | open"
  case "$out" in *"open "$'\n'*|*"open ") no "question row trailing space" ;; *) ok ;; esac
  out=$(bash "$brief" / 2>&1 </dev/null)
  expect_has "root dir kept" "$out" "project: /"
}

g_gitignore() {
  echo "brief.sh gitignore check"
  a="$tmp/f-gi"; make_fixture "$a"; mkdir -p "$a/.claude/guyb/pipeline"; a_w=${a/#"$tmp"/$tmp_w}
  for gi in '.claude/guyb/pipeline/' '/.claude/guyb/pipeline'; do
    printf 'node_modules/\n%s\n' "$gi" > "$a/.gitignore"
    out=$(bash "$brief" "${a_w}" 2>&1)
    expect_lacks "gitignore $gi" "$out" "gitignore:"
    expect_lacks "gitignore $gi" "$out" "warn:"
  done
  printf '.claude/\n' > "$a/.gitignore"
  out=$(bash "$brief" "${a_w}" 2>&1)
  expect_has "gitignore .claude/" "$out" "warn: .gitignore ignores .claude/ - guyb STATE.md will not be committed"
  expect_lacks "gitignore .claude/" "$out" "gitignore:"
}

mk_clean() { # dir claude-lines state-lines registry-rows
  make_fixture "$1"
  gen_lines "$2" "line" > "$1/.claude/CLAUDE.md"
  { printf '# State\n\n## Next up\n- x\n\n## Open issues\n- y\n'; gen_lines "$(($3 - 7))" "filler"; } > "$1/.claude/guyb/STATE.md"
  p="$1/.claude/guyb/pipeline"; mkdir -p "$p/progress" "$p/reports" "$p/plans" "$p/brand/x-1"
  { echo "$RUNHDR"; echo '|---|'; runrow x-1 'done' 2020-01-01; runrow x-2 running "$today"; awk -v n="$4" 'BEGIN { for (i = 1; i <= n - 2; i++) printf "| f-%d | implementer | sonnet | t | 1 | - | done | 2020-01-01 | 1k |\n", i }'; } > "$p/runs.md"
  gen_table "$p/questions.md" '| ID | Run | Question | Blocking | Assumed | Status |' "$4" Q answered
  : > "$p/progress/x-1.md"; : > "$p/progress/x-2.md"; : > "$p/progress/x-3.md"; : > "$p/brand/x-1/a.svg"
  touch -t 202001010000 "$p/progress/x-1.md" "$p/progress/x-2.md" "$p/brand/x-1/a.svg"
}
snap() { { find "$1" | sort; git -C "${1/#"$tmp"/$tmp_w}" status --short 2>/dev/null; }; }

g_cleanup_over() {
  echo "brief.sh cleanup suggestions (over limits)"
  ov="$tmp/over"; mk_clean "$ov" 201 301 201; ov_w=${ov/#"$tmp"/$tmp_w}
  before=$(snap "$ov")
  out=$(bash "$brief" "${ov_w}" 2>&1)
  after=$(snap "$ov")
  expect_has "cleanup over" "$out" "cleanup: CLAUDE.md 201 lines (>200); STATE.md 301 lines (>300); runs.md 201 rows (>200); questions.md 201 rows (>200); 2 pipeline files older than 14 days"
  expect_lacks "cleanup over" "$out" "overdue:"
  expect_eq "brief leaves fixture unchanged" "$after" "$before"
}

g_cleanup_under() {
  echo "brief.sh cleanup suggestions (limits, overrides, profile)"
  un="$tmp/under"; mk_clean "$un" 200 300 200; un_w=${un/#"$tmp"/$tmp_w}
  rm -f "$un/.claude/guyb/pipeline/progress/x-1.md" "$un/.claude/guyb/pipeline/brand/x-1/a.svg"
  out=$(bash "$brief" "${un_w}" 2>&1)
  expect_lacks "cleanup under limits" "$out" "cleanup:"
  printf '# fixture\n\n- cleanup_state_lines: 10\ncleanup_days: 0\ncleanup_rows: abc\n' > "$un/.claude/CLAUDE.md"
  out=$(bash "$brief" "${un_w}" 2>&1)
  expect_has "cleanup override" "$out" "cleanup: STATE.md 300 lines (>10)"
  expect_lacks "cleanup invalid rows ignored" "$out" "rows"
  expect_lacks "cleanup invalid days ignored" "$out" "older than"
  mkdir -p "$HOME/.claude/guyb"; printf 'cleanup_days: 3\n' > "$HOME/.claude/guyb/profile.md"
  touch -t 202001010000 "$un/.claude/guyb/pipeline/progress/x-3.md"
  out=$(bash "$brief" "${un_w}" 2>&1)
  expect_has "cleanup profile days" "$out" "1 pipeline files older than 3 days"
}

g_overdue() {
  echo "brief.sh overdue items"
  od="$tmp/overdue"; make_fixture "$od"; mkdir -p "$od/.claude/guyb/pipeline"; od_w=${od/#"$tmp"/$tmp_w}
  { echo "$RUNHDR"; echo '|---|'; runrow y-1 running 2020-01-01; runrow y-2 queued "2020-01-02 10:30"; runrow y-3 'done' 2020-01-01; runrow y-4 running "$today"; runrow y-5 blocked 2020-02-01
    runrow y-6 running 2020-03-01; runrow y-7 running 2020-03-02; } > "$od/.claude/guyb/pipeline/runs.md"
  { echo '| ID | Run | Question | Blocking | Assumed | Status |'; echo '|---|---|---|---|---|---|'
    echo '| Q1 | y-1 | old open | no | a | open |'; echo '| Q2 | y-4 | fresh open | no | a | open |'; echo '| Q3 | y-1 | old answered | no | a | answered |'; } > "$od/.claude/guyb/pipeline/questions.md"
  out=$(bash "$brief" "${od_w}" 2>&1)
  expect_has "overdue list" "$out" "overdue: y-1, y-2, y-5, y-6, y-7, +1 more"
  { echo "$RUNHDR"; echo '|---|'; runrow y-1 running 2020-01-01; runrow y-3 'done' 2020-01-01; } > "$od/.claude/guyb/pipeline/runs.md"
  out=$(bash "$brief" "${od_w}" 2>&1)
  expect_has "overdue runs and questions" "$out" "overdue: y-1, Q1"
}

g_regfmt() {
  echo "brief.sh registry formats and run ids"
  rg="$tmp/regfmt"; make_fixture "$rg"; rp="$rg/.claude/guyb/pipeline"; mkdir -p "$rp/progress"; rg_w=${rg/#"$tmp"/$tmp_w}
  { echo "$RUNHDR"; echo '|---|'; runrow mien-dev-3 running 2020-01-01; runrow r-6b running "$today"; runrow r-6 'done' 2020-01-01; } > "$rp/runs.md"
  { echo '| Q | Run | Agent | Question | Blocking | Assumed | Status | Answer |'; echo '|---|---|---|---|---|---|---|---|'
    echo '| Q1 | mien-dev-3 | architect | old open | no | a | open | |'; echo '| Q2 | r-6b | architect | fresh | no | a | open | |'; } > "$rp/questions.md"
  out=$(bash "$brief" "${rg_w}" 2>&1)
  expect_has "overdue hyphenated id, Q-format questions" "$out" "overdue: mien-dev-3, Q1"
  printf '| ID | Run | Question | Blocking | Assumed | Status |\n|---|---|---|---|---|---|\n| Q1 | mien-dev-3 | old open | no | a | open |\n' > "$rp/questions.md"
  out=$(bash "$brief" "${rg_w}" 2>&1)
  expect_has "overdue ID-format questions" "$out" "overdue: mien-dev-3, Q1"
  : > "$rp/progress/r-6b.md"; : > "$rp/progress/r-6.md"; : > "$rp/progress/mien-dev-3-notes.md"
  touch -t 202001010000 "$rp/progress/r-6b.md" "$rp/progress/r-6.md" "$rp/progress/mien-dev-3-notes.md"
  out=$(bash "$brief" "${rg_w}" 2>&1)
  expect_has "stale: r-6b and prefix ids active, r-6 done" "$out" "cleanup: 1 pipeline files older than 14 days"
  printf '.Claude/guyb/pipeline/\n' > "$rg/.gitignore"
  out=$(bash "$brief" "${rg_w}" 2>&1)
  expect_has "gitignore is case-sensitive" "$out" "gitignore: .claude/guyb/pipeline/ not ignored"
}

g_env() {
  echo "brief.sh and check.sh toolchain detection"
  ep="$tmp/envpy"; mkdir -p "$ep"; printf '99.1\r\n' > "$ep/.python-version"; ep_w=${ep/#"$tmp"/$tmp_w}
  out=$(bash "$brief" "${ep_w}" 2>&1)
  expect_has "env python" "$out" "env: python wants 99.1 (.python-version), found"
  expect_has "env python" "$out" ".venv missing"
  mkdir -p "$ep/.venv"; out=$(bash "$brief" "${ep_w}" 2>&1)
  expect_lacks "env python venv present" "$out" ".venv missing"
  en="$tmp/envnode"; mkdir -p "$en"; printf '{"name":"x"}\n' > "$en/package.json"; : > "$en/pnpm-lock.yaml"; en_w=${en/#"$tmp"/$tmp_w}
  out=$(bash "$brief" "${en_w}" 2>&1)
  expect_has "env node" "$out" "node_modules missing (pnpm)"
  out=$(bash "$brief" "${ee_w}" 2>&1)
  expect_lacks "env empty folder" "$out" "env:"
  if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
    out=$(bash "$brief" "${ed_w}" 2>&1)
    expect_has "env docker missing" "$out" "env: docker not installed (compose.yaml)"
    cr="$tmp/croot"; mkdir -p "$cr/svc"; : > "$cr/svc/Dockerfile"; cr_w=${cr/#"$tmp"/$tmp_w}
    GUYB_ROOT="${cr_w}" bash "$check" > "$tmp/check2.json" 2>/dev/null
    IFS= read -r -d '' chk2 < "$tmp/check2.json"
    expect_has "check container" "$chk2" '"id":"container","status":"warn"'
    expect_has "check container" "$chk2" '"fix":"'
  fi
  bash "$check" "${ee_w}" > "$tmp/check3.json" 2>/dev/null
  if json_ok "$tmp_w/check3.json"; then ok; else no "check toolchain: output is not valid JSON"; fi
  IFS= read -r -d '' chk3 < "$tmp/check3.json"
  for id in container python node uv; do expect_has "check $id" "$chk3" "\"id\":\"$id\""; done
  expect_lacks "check toolchain" "$chk3" '"blocking":true,"detail":"python'
}

g_docker() { # brief script: docker daemon down, and a hung one (3s cap)
  bn=$(basename "$1")
  echo "brief.sh docker probes $bn"
  out=$(PATH="$tmp/dfail:$PATH" bash "$1" "${ed_w}" 2>&1)
  expect_has "env docker down $bn" "$out" "env: docker daemon not running (compose.yaml)"
  t0=$SECONDS; out=$(PATH="$tmp/dsleep:$PATH" bash "$1" "${ed_w}" 2>&1); dt=$((SECONDS - t0))
  expect_has "env docker hung $bn" "$out" "env: docker daemon not responding (compose.yaml)"
  if [ "$dt" -lt 100 ]; then ok; else no "env docker hung $bn: brief took ${dt}s"; fi
}

# every version probe is capped too: a hanging node must not stall check.sh or brief.sh (with and without timeout)
g_hang_check() { # check script
  echo "check.sh hung node $(basename "$1")"
  t0=$SECONDS; PATH="$tmp/nsleep:$PATH" bash "$1" "${ee_w}" > "$tmp/check4-$(basename "$1").json" 2>/dev/null; dt=$((SECONDS - t0))
  if [ "$dt" -lt 250 ]; then ok; else no "check hung node $(basename "$1"): took ${dt}s"; fi
}
g_hang_brief() { # brief script
  echo "brief.sh hung node $(basename "$1")"
  t0=$SECONDS; out=$(PATH="$tmp/nsleep:$PATH" bash "$1" "${en2_w}" 2>&1); dt=$((SECONDS - t0))
  expect_has "env hung node $(basename "$1")" "$out" "node not installed"
  if [ "$dt" -lt 250 ]; then ok; else no "brief hung node $(basename "$1"): took ${dt}s"; fi
}

g_guard() {
  echo "guard-secrets.sh"
  g="$tmp/guarded"; make_fixture "$g"; g_w=${g/#"$tmp"/$tmp_w}
  guard="$root/plugins/guyb/hooks/guard-secrets.sh"
  printf 'KEY=value\n' > "$g/.env"; printf 'KEY=\n' > "$g/.env.example"
  git -C "${g_w}" add .env >/dev/null 2>&1
  err=$(cd "$g" && . "$guard" 2>&1 >/dev/null </dev/null); rc=$?
  expect_eq "guard staged .env exit" "$rc" 2
  expect_has "guard staged .env" "$err" ".env"
  git -C "${g_w}" reset -q >/dev/null 2>&1
  git -C "${g_w}" add .env.example >/dev/null 2>&1
  (cd "$g" && . "$guard") >/dev/null 2>&1 </dev/null; expect_eq "guard staged .env.example exit" "$?" 0
  (cd "$tmp" && . "$guard") >/dev/null 2>&1 </dev/null; expect_eq "guard outside a repo exit" "$?" 0
  sg() { (cd "$tmp" && . "$guard") >/dev/null 2>&1 <<< "{\"cwd\":\"${g_w}\",\"tool_input\":{\"command\":\"$1\"}}"; rc=$?; } # command: exit code in $rc
  git -C "${g_w}" reset -q >/dev/null 2>&1
  sg 'git commit -m x'; expect_eq "guard untracked .env, plain commit" "$rc" 0
  sg 'git add -A && git commit -m x'; expect_eq "guard add -A && commit, untracked .env" "$rc" 2
  sg 'git stage .env; git commit -m x'; expect_eq "guard git stage then commit, untracked .env" "$rc" 2
  git -C "${g_w}" add .env >/dev/null 2>&1
  sg 'env git commit -m x'; expect_eq "guard env git commit, staged .env" "$rc" 2
  sg 'if true; then git commit -m x; fi'; expect_eq "guard if/then git commit, staged .env" "$rc" 2
  sg 'GIT commit -m x'; expect_eq "guard uppercase GIT commit, staged .env" "$rc" 2
  sg "(cd ${tmp_w}); git commit -m x"; expect_eq "guard subshell cd then commit, staged .env" "$rc" 2
  sg "git --git-dir=${tmp_w}/nogit commit -m x"; expect_eq "guard --git-dir elsewhere" "$rc" 2
  git -C "${g_w}" reset -q >/dev/null 2>&1
  sg 'env git commit -m x'; expect_eq "guard env git commit, nothing staged" "$rc" 0
}

g_readonly() { # chunk chunks: chunk 0 sends every row of tests/readonly-cases.tsv through the batch entry (one awk), a per-case sample, the filter contract and the extra cases; GUYB_RO_FULL=1 also runs each chunk's share per case
  echo "guard-readonly.sh (tests/readonly-cases.tsv, chunk $1 of $2)"
  ro="$root/plugins/guyb/hooks/guard-readonly.sh"
  cases="$root/tests/readonly-cases.tsv"
  hj="$root/plugins/guyb/hooks/hooks.json"
  # Minimal repo written by hand (git init + 6 config calls would be 7 forks); the hook only reads its aliases.
  ar="$tmp/aliasrepo$1"; mkdir -p "$ar/.git/objects" "$ar/.git/refs"; ar_w=${ar/#"$tmp"/$tmp_w}
  printf 'ref: refs/heads/main\n' > "$ar/.git/HEAD"
  printf '[core]\n\trepositoryformatversion = 0\n[alias]\n\tst = status\n\tci = commit\n\tc2 = ci\n\tsh = !echo hi\n\tla = lb\n\tlb = la\n' > "$ar/.git/config"
  nr="$tmp/norepo$1"; mkdir -p "$nr"; nr_w=${nr/#"$tmp"/$tmp_w}
  cd "$tmp" || exit 1
  # The hook is made to be sourced (hooks.json does); a sourced subshell skips a bash exec per case. g_wrapper runs the real bash entry.
  ro_run() { # json: hook exit code in $rc
    ( . "$ro" ) >/dev/null 2>&1 <<< "$1"; rc=$?
  }
  ro_json() { # agent cwd command: hook JSON in $ro_j
    fields=""
    [ "$1" = "-" ] || fields="\"agent_type\":\"$1\","
    case "$2" in
      -) ;;
      norepo) fields="$fields\"cwd\":\"${nr_w}\"," ;;
      *) fields="$fields\"cwd\":\"${ar_w}\"," ;;
    esac
    ro_j="{${fields}\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$3\"}}"
  }
  # Filter contract: the `if` globs of the guard-readonly Bash entries in hooks.json (case-sensitive, `*` only, like Claude Code)
  # must match every block row, so no write command skips the guard. Case variants of "git" are separate entries (globs have no classes).
  ro_globs=(); cond=""
  while IFS= read -r l; do
    l=${l%$'\r'}
    case "$l" in
      *'"if": "Bash('*) cond=${l#*'"if": "Bash('}; cond=${cond%')"'*} ;;
      *'"if": "'*) cond="" ;;
      *guard-readonly.sh*) [ -n "$cond" ] && ro_globs[${#ro_globs[@]}]=$cond; cond="" ;;
    esac
  done < "$hj"
  if [ "$1" -eq 0 ]; then
    gl=" ${ro_globs[*]} "
    expect_eq "hooks.json readonly bash filter entries" "${#ro_globs[@]}" 8
    for v in git giT gIt gIT Git GiT GIt GIT; do expect_has "hooks.json readonly filter *$v*" "$gl" " *$v* "; done
  fi
  rs=$'\036'; recs=""
  r_exp=(); r_lbl=()
  n=0; rows=0
  while IFS="$(printf '\t')" read -r exp shell agent cwd cmd note; do
    n=$((n + 1)); [ "$n" -eq 1 ] && continue
    case "$shell" in both | sh) ;; *) continue ;; esac
    rows=$((rows + 1))
    r_exp[rows]=$exp; r_lbl[rows]="$note: $cmd"
    ro_json "$agent" "$cwd" "$cmd"
    if [ "$1" -eq 0 ]; then
      recs=$recs$ro_j$rs
      if [ "$exp" = 2 ]; then
        hit=0
        # shellcheck disable=SC2254 # the if filter is a glob on purpose
        for g in "${ro_globs[@]}"; do case "$cmd" in $g) hit=1 ;; esac; done
        expect_eq "hooks.json readonly filter covers: $cmd" "$hit" 1
      fi
    fi
    if [ "${GUYB_RO_FULL:-}" = 1 ]; then [ $((rows % $2)) -eq "$1" ] || continue; else [ $((rows % 25)) -eq 0 ] || continue; fi
    ro_run "$ro_j"
    expect_eq "readonly per case $note: $cmd" "$rc" "$exp"
  done < "$cases"
  [ "$1" -eq 0 ] || return 0
  seen=0
  while read -r bn brc; do
    seen=$((seen + 1))
    expect_eq "readonly batch ${r_lbl[bn]}" "$brc" "${r_exp[bn]}"
  done <<< "$( ( . "$ro" batch ) 2>/dev/null <<< "$recs" )"
  expect_eq "readonly batch answered every row" "$seen" "$rows"
  ro_run 'not json'; expect_eq "readonly bad json" "$rc" 0
  ro_run '{"agent_type":"code-reviewer","tool_input":{"command":""}}'; expect_eq "readonly empty command" "$rc" 0
  ro_add='{"agent_type":"code-reviewer","tool_name":"Bash","tool_input":{"command":"git add ."}}'
  for gm in cmd batch; do
    ( export GUYB_MODE=$gm; . "$ro" ) >/dev/null 2>&1 <<< "$ro_add"; expect_eq "readonly GUYB_MODE=$gm in the environment still blocks" "$?" 2
  done
  eb="$tmp/emptybin"; mkdir -p "$eb"
  ( hash -r; PATH="$eb"; . "$ro" ) >/dev/null 2>&1 <<< "$ro_add"; expect_eq "readonly agent without awk is blocked" "$?" 2
  ( hash -r; PATH="$eb"; . "$ro" ) >/dev/null 2>&1 <<< '{"tool_name":"Bash","tool_input":{"command":"git add ."}}'; expect_eq "main session without awk passes" "$?" 0
}

g_wrapper() {
  echo "hooks.json guard-readonly bash entry, end to end"
  if command -v jq >/dev/null 2>&1; then
    hcmd=$(jq -r '.hooks.PreToolUse[].hooks[] | select(.shell == "bash") | select(.command | contains("guard-readonly")) | .command' "$root/plugins/guyb/hooks/hooks.json" | tr -d '\r')
    # one entry per casing of "git" (the `if` globs are case-sensitive), all with the same command
    expect_eq "hooks.json readonly bash entry count" "$(printf '%s\n' "$hcmd" | grep -c .)" 8
    expect_eq "hooks.json readonly bash entries share one command" "$(printf '%s\n' "$hcmd" | sort -u | grep -c .)" 1
    hcmd=${hcmd%%$'\n'*}
    hcmd=${hcmd//\$\{CLAUDE_PLUGIN_ROOT\}/${root_w}/plugins/guyb}
    wrap() { # json: stdout+stderr, then exit code on the last line
      printf '%s' "$1" | (cd "$tmp" && bash -c "$hcmd" 2>&1); echo "rc=$?"
    }
    out=$(wrap '{"agent_type":"guyb:code-reviewer","tool_name":"Bash","tool_input":{"command":"git add ."}}')
    expect_has "wrapper reviewer git add" "$out" "rc=2"
    expect_has "wrapper reviewer git add" "$out" "guyb: blocked - read-only agent"
    expect_has "wrapper reviewer git status" "$(wrap '{"agent_type":"guyb:code-reviewer","tool_name":"Bash","tool_input":{"command":"git status"}}')" "rc=0"
    expect_has "wrapper implementer git add" "$(wrap '{"agent_type":"guyb:implementer","tool_name":"Bash","tool_input":{"command":"git add ."}}')" "rc=0"
    expect_has "wrapper main session git add" "$(wrap '{"tool_name":"Bash","tool_input":{"command":"git add ."}}')" "rc=0"
    expect_has "wrapper bad json" "$(wrap 'not json')" "rc=0"
  else
    echo "skip: jq missing, hooks.json wrapper cases not run"
  fi
}

utc_at() { # seconds from now -> UTC "YYYY-MM-DDTHH:MM:SSZ" in $utc (pure bash, civil-from-days; one `date`)
  ue=$(( $(date +%s) + $1 )); ud=$((ue / 86400)); us=$((ue % 86400))
  uz=$((ud + 719468)); uera=$((uz / 146097)); udoe=$((uz - uera * 146097))
  uyoe=$(( (udoe - udoe / 1460 + udoe / 36524 - udoe / 146096) / 365 )); uy=$((uyoe + uera * 400))
  udoy=$((udoe - (365 * uyoe + uyoe / 4 - uyoe / 100))); ump=$(( (5 * udoy + 2) / 153 ))
  udd=$((udoy - (153 * ump + 2) / 5 + 1)); if [ "$ump" -lt 10 ]; then um=$((ump + 3)); else um=$((ump - 9)); fi
  [ "$um" -le 2 ] && uy=$((uy + 1))
  utc=$(printf '%04d-%02d-%02dT%02d:%02d:%02dZ' "$uy" "$um" "$udd" $((us / 3600)) $((us % 3600 / 60)) $((us % 60)))
}

g_connections() {
  echo "connections: lines, warnings, hook (fixture config dirs, stub CLIs)"
  cx="$HOME/cx"; mkdir -p "$cx/stub" "$cx/claude" "$cx/gh cfg" "$cx/gcloud/configurations" "$cx/az" "$cx/xdg" "$cx/appdata" "$cx/home/.aws/login/cache"
  conn="$root/plugins/guyb/skills/setup/connections.sh"
  slog="$cx/gh.log"; clog="$cx/cli.log"; : > "$slog"; : > "$clog"
  for t in aws gcloud az wrangler glab guyb-stub-cli; do printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$clog" > "$cx/stub/$t"; chmod +x "$cx/stub/$t"; done
  export PATH="$cx/stub:$PATH"
  export CLAUDE_CONFIG_DIR="$cx/claude" GH_CONFIG_DIR="$cx/gh cfg" AZURE_CONFIG_DIR="$cx/az" XDG_CONFIG_HOME="$cx/xdg" APPDATA="$cx/appdata" GH_STUB_LOG="$slog"
  export CLOUDSDK_CONFIG="${cx//\//\\}\\gcloud" # backslashes on purpose: the scripts turn them into slashes
  unset AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_ACCESS_KEY_ID AWS_PROFILE GH_TOKEN GITHUB_TOKEN CLOUDFLARE_API_TOKEN BITBUCKET_EMAIL BITBUCKET_API_TOKEN
  secret_a="SENTINEL-SECRET-1"; secret_b="SENTINEL-AWS-CACHE-2"
  allout=""
  # the scripts read $HOME/.aws and $HOME/.claude/guyb/profile.md
  export HOME="$cx/home"; mkdir -p "$HOME/.claude/guyb"; prof="$HOME/.claude/guyb/profile.md"
  . "$conn" lib
  gc_lines=""
  cn() { guyb_conn brief "$1"; guyb_conn_lines; cnout=$gc_lines; allout="$allout$cnout"; } # dir: the three line kinds in $cnout
  # fixture state: everything fine
  utc_at -3600; fresh=$utc
  printf '{"accessToken":{"secretAccessKey":"%s","expiresAt":"%s"},"refreshToken":"x"}' "$secret_b" "$fresh" > "$HOME/.aws/login/cache/a.json"
  printf '[default]\nregion = ap-northeast-1\n' > "$HOME/.aws/config"
  printf 'github.com:\n    users:\n        alamhanz:\n    user: alamhanz\n' > "$GH_CONFIG_DIR/hosts.yml"
  printf 'x' > "$cx/gcloud/configurations/config_default"; : > "$cx/gcloud/credentials.db"
  printf '\357\273\277{"subscriptions":[{"id":"SUB-123"}]}' > "$AZURE_CONFIG_DIR/azureProfile.json"
  printf '{\n  "numStartups": 1,\n  "mcpServers": {\n    "cloudflare": {\n      "type": "http"\n    },\n    "Neon": {\n      "type": "http"\n    }\n  },\n  "projects": {\n    "x": {\n      "mcpServers": {\n        "zzz": {}\n      }\n    }\n  }\n}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
  export CLOUDFLARE_API_TOKEN="$secret_a"
  full='# Profile\r\n\r\n## Git\r\n- github thing\r\n\r\n## Connections\r\n<!-- guyb:connections - "- <type> <name>: key=value ...", no secrets -->\r\n- github alamhanz: cli=gh default=yes\r\n- aws default: region=ap-northeast-1 account=1 login=aws-login\r\n- cloudflare main: auth=env\r\n- mcp cloudflare: url=https://mcp.cloudflare.com/mcp scope=user auth=oauth\r\n- mcp Neon: url=x scope=user\r\n- gcp default: project=p\r\n- azure sub: subscription=SUB-123\r\n- gitlab gl: cli=glab\r\n- foo bar: x=y\r\n\r\n## Other\r\n- aws nothing: region=x\r\n'
  printf "$full" > "$prof"
  noproj="$tmp/conn-root"; mkdir -p "$noproj"; noproj_w=${noproj/#"$tmp"/$tmp_w}
  cn "$noproj_w"
  want='connections: github alamhanz, aws default (ap-northeast-1), cloudflare main, mcp cloudflare (user), mcp Neon (user), gcp default (p), azure sub, gitlab gl, foo bar'
  expect_eq "connections all ok (CRLF profile, spaces and backslashes in config paths)" "$cnout" "$want"
  # AWS
  printf '[profile other]\nregion = x\n' > "$HOME/.aws/config"; cn "$noproj_w"
  expect_has "aws profile missing" "$cnout" "warn: connection aws default: profile default missing from ~/.aws/config"
  printf '[default]\nregion = ap-northeast-1\n' > "$HOME/.aws/config"
  utc_at -259200; old=$utc
  printf '{"accessToken":{"secretAccessKey":"%s","expiresAt":"%s"}}' "$secret_b" "$old" > "$HOME/.aws/login/cache/a.json"; cn "$noproj_w"
  expect_has "aws login cache 3 days old" "$cnout" "warn: connection aws default: login session likely expired (last refresh ${old%%T*})"
  printf '{"expiresAt":"%s"}' "$fresh" > "$HOME/.aws/login/cache/b.json"; cn "$noproj_w"
  expect_lacks "aws login: any fresh cache keeps it silent" "$cnout" "login session"
  rm -f "$HOME/.aws/login/cache/b.json"; (export AWS_ACCESS_KEY_ID=x; cn "$noproj_w"; echo "$cnout" > "$cx/o2")
  IFS= read -r -d '' o2 < "$cx/o2"
  expect_lacks "aws login: static keys in env skip the expiry check" "$o2" "login session"
  printf '{"accessToken":{"secretAccessKey":"%s","expiresAt":"%s"}}' "$secret_b" "$fresh" > "$HOME/.aws/login/cache/a.json"; cn "$noproj_w"
  expect_eq "aws login cache 1 h left" "$cnout" "$want"
  # GitHub
  printf 'github.com:\n    users:\n        someone:\n    user: someone\n' > "$GH_CONFIG_DIR/hosts.yml"; cn "$noproj_w"
  expect_has "gh other user" "$cnout" "warn: connection github alamhanz: gh not logged in as alamhanz"
  (export GH_TOKEN=x; cn "$noproj_w"; echo "$cnout" > "$cx/o3")
  IFS= read -r -d '' o3 < "$cx/o3"; expect_lacks "gh token in env" "$o3" "gh not logged in"
  printf 'github.com:\n    user: alamhanz\n' > "$GH_CONFIG_DIR/hosts.yml"
  # MCP, Cloudflare, gcloud, az
  printf '{"mcpServers": {"cloudflare": {}}}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"; cn "$noproj_w"
  expect_lacks "mcp inline config: names not read, silent" "$cnout" "MCP server"
  printf '{\n  "mcpServers": {\n    "cloudflare": {}\n  }\n}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"; cn "$noproj_w"
  expect_has "mcp name missing" "$cnout" "warn: connection mcp Neon: MCP server not configured at user scope"
  expect_lacks "mcp name present" "$cnout" "connection mcp cloudflare"
  printf '{"mcpServers":{"cloudflare":{}}}' > "$CLAUDE_CONFIG_DIR/.claude.json"; cn "$noproj_w"
  expect_lacks "mcp config not pretty-printed: silent" "$cnout" "MCP server"
  rm -f "$CLAUDE_CONFIG_DIR/.claude.json"; cn "$noproj_w"; expect_lacks "mcp config missing: silent" "$cnout" "MCP server"
  (unset CLOUDFLARE_API_TOKEN; cn "$noproj_w"; echo "$cnout" > "$cx/o1")
  IFS= read -r -d '' o1 < "$cx/o1"
  expect_has "cloudflare token unset" "$o1" "warn: connection cloudflare main: CLOUDFLARE_API_TOKEN not set in this session"
  rm -f "$GH_CONFIG_DIR/hosts.yml" "$cx/gcloud/credentials.db" "$AZURE_CONFIG_DIR/azureProfile.json"; cn "$noproj_w"
  expect_has "gcloud not logged in" "$cnout" "warn: connection gcp default: not logged in"
  expect_has "az subscription missing" "$cnout" "warn: connection azure sub: subscription SUB-123 not in az profile"
  rm -f "$cx/gcloud/configurations/config_default"; cn "$noproj_w"
  expect_has "gcloud configuration missing" "$cnout" "warn: connection gcp default: configuration default missing"
  # CLI not on PATH, wrangler, bitbucket, unknown type
  printf '# P\n\n## Connections\n- db pg: cli=guyb-no-such-cli\n- service svc: cli=guyb-stub-cli env=GUYB_SMOKE_NOPE\n- cloudflare w: auth=wrangler\n- bitbucket bb: env=BITBUCKET_EMAIL,BITBUCKET_API_TOKEN\n- zzz yy: k=v\n' > "$prof"; cn "$noproj_w"
  expect_has "cli missing" "$cnout" "warn: connection db pg: guyb-no-such-cli not on PATH"
  expect_lacks "cli present (stub, not run)" "$cnout" "guyb-stub-cli not on PATH"
  expect_has "service env var" "$cnout" "warn: connection service svc: GUYB_SMOKE_NOPE not set in this session"
  expect_has "wrangler not logged in" "$cnout" "warn: connection cloudflare w: wrangler not logged in"
  expect_has "bitbucket env vars" "$cnout" "warn: connection bitbucket bb: BITBUCKET_API_TOKEN not set in this session"
  expect_has "unknown type is listed" "$cnout" ", zzz yy"
  expect_lacks "unknown type is not checked" "$cnout" "connection zzz"
  mkdir -p "$XDG_CONFIG_HOME/.wrangler/config"; : > "$XDG_CONFIG_HOME/.wrangler/config/default.toml"; cn "$noproj_w"
  expect_lacks "wrangler logged in" "$cnout" "wrangler not logged in"
  # profile without section, empty section
  printf '# Profile\n\n## Git\n- x\n' > "$prof"; cn "$noproj_w"
  expect_eq "profile without Connections section" "$cnout" "connections: not recorded in ~/.claude/guyb/profile.md"
  printf '# Profile\n\n## Connections\n<!-- comment -->\n\n## Other\n' > "$prof"; cn "$noproj_w"
  expect_eq "empty Connections section" "$cnout" "connections: not recorded in ~/.claude/guyb/profile.md"
  # project override and project config lines
  printf "$full" > "$prof"
  pj="$tmp/conn-proj"; make_fixture "$pj"; pj_w=${pj/#"$tmp"/$tmp_w}
  rm -f "$pj/.claude/CLAUDE.md"; cn "$pj_w"
  expect_has "project without CLAUDE.md" "$cnout" "project config: none - follows global (~/.claude/guyb/profile.md)"
  printf '# fixture\n\n- Cloud: none\n\n## Credentials (names only)\nNone.\n\nmax_parallel: 3\ncleanup_days: 5\n' > "$pj/.claude/CLAUDE.md"; cn "$pj_w"
  expect_has "project cloud none, credentials none" "$cnout" "project config: cloud none; credentials none; max_parallel 3; cleanup limits"
  printf '# fixture\n\n## Connections\n- aws prod: region=eu-west-1\n\n## Credentials\n- A: x\n- B: y\n' > "$pj/.claude/CLAUDE.md"; : > "$pj/.mcp.json"; cn "$pj_w"
  expect_has "project override replaces the global aws entry" "$cnout" "connections: github alamhanz, cloudflare main, mcp cloudflare (user), mcp Neon (user), gcp default (p), azure sub, gitlab gl, foo bar, aws prod (project)"
  expect_lacks "project override: global aws entry gone" "$cnout" "aws default"
  expect_has "project config with connections" "$cnout" "project config: connections aws prod; credentials 2 names; .mcp.json"
  cn "$noproj_w"; expect_lacks "projects root: no project line" "$cnout" "project config:"
  rm -f "$prof"; cn "$pj_w"
  expect_lacks "no profile: no connections line" "$cnout" "connections:"
  expect_has "no profile: project line stays" "$cnout" "project config:"
  printf "$full" > "$prof"
  # the real scripts: brief.sh, check.sh, the hook
  printf '{
  "mcpServers": {
    "Neon": {}
  }
}
' > "$CLAUDE_CONFIG_DIR/.claude.json"
  mkdir -p "$GH_CONFIG_DIR"; printf 'github.com:\n    user: alamhanz\n' > "$GH_CONFIG_DIR/hosts.yml"
  bout=$(GH_STUB_LISTRC=4 bash "$brief" "$pj_w" 2>&1)
  expect_has "brief.sh connections line" "$bout" "connections: github alamhanz"
  expect_has "brief.sh warn line" "$bout" "warn: connection mcp cloudflare: MCP server not configured at user scope"
  expect_has "brief.sh gh auth failed" "$bout" "warn: connection github alamhanz: gh auth failed"
  expect_has "brief.sh project config" "$bout" "project config: connections aws prod"
  cnt "$slog" 'pr list'; expect_eq "brief.sh made the one gh list call" "$cnt_n" 1
  bout2=$(bash "$brief" "$pj_w" 2>&1)
  expect_lacks "brief.sh without gh failure" "$bout2" "gh auth failed"
  cr=${bout//[!$'\r']/}; expect_eq "brief.sh connection lines carry no CR" "${#cr}" 0
  printf '
## Connections
- bitbucket bb: env=BITBUCKET_EMAIL,BITBUCKET_API_TOKEN
' >> "$prof" # a second section is read too
  bash "$check" "$pj_w" > "$cx/check.json" 2>/dev/null
  if json_ok "$(win "$cx/check.json")"; then ok; else no "check.sh with connections: output is not valid JSON"; fi
  IFS= read -r -d '' cj < "$cx/check.json"
  expect_has "check.sh connections entry" "$cj" '"id":"connections","status":"ok","blocking":false,"detail":"github alamhanz'
  expect_has "check.sh conn warn entry" "$cj" '"id":"conn-mcp-cloudflare","status":"warn","blocking":false,"detail":"MCP server not configured at user scope","fix":"","fixBy":"none"'
  expect_has "check.sh project-config entry" "$cj" '"id":"project-config","status":"ok"'
  expect_has "check.sh two warnings of one connection get distinct ids" "$cj" '"id":"conn-bitbucket-bb-2"'
  printf "$full" > "$prof"
  hk() { # dir: hook output (hooks.json command through bash -c when jq is there)
    if [ -n "$hcmd" ]; then CLAUDE_PROJECT_DIR="$1" bash -c "$hcmd" </dev/null 2>&1; else CLAUDE_PROJECT_DIR="$1" bash -c ". \"$conn_w\" hook" </dev/null 2>&1; fi
  }
  conn_w=$(win "$conn"); hcmd=""
  if command -v jq >/dev/null 2>&1; then
    hcmd=$(jq -r '.hooks.SessionStart[] | select(.matcher == "startup") | .hooks[] | select(.shell == "bash") | select(.command | contains("connections.sh")) | .command' "$root/plugins/guyb/hooks/hooks.json" | tr -d '\r')
    expect_eq "hooks.json startup connections entry" "$(printf '%s\n' "$hcmd" | grep -c .)" 1
    hcmd=${hcmd//\$\{CLAUDE_PLUGIN_ROOT\}/${root_w}/plugins/guyb}
  fi
  hout=$(hk "$pj_w")
  printf '%s\n' "$hout" > "$cx/hook.json"
  if json_ok "$(win "$cx/hook.json")"; then ok; else no "hook output is not valid JSON"; fi
  expect_has "hook systemMessage" "$hout" '{"systemMessage":"guyb connections: github alamhanz'
  expect_has "hook warn line" "$hout" '\nguyb warn: connection mcp cloudflare: MCP server not configured at user scope'
  expect_has "hook project line" "$hout" '\nguyb project config: connections aws prod'
  expect_eq "hook prints one line" "$(printf '%s\n' "$hout" | grep -c .)" 1
  hroot=$(hk "$noproj_w")
  expect_lacks "hook at the projects root: no project line" "$hroot" "project config"
  rm -f "$prof"; expect_eq "hook without profile.md prints nothing" "$(hk "$pj_w")" ""
  printf '# P\n\n## Connections\n- weird "name\\x: a=b\n' > "$prof"; hweird=$(hk "$pj_w")
  printf '%s\n' "$hweird" > "$cx/hook2.json"
  if json_ok "$(win "$cx/hook2.json")"; then ok; else no "hook output with quotes and backslashes in names is not valid JSON"; fi
  allout="$allout$bout$bout2$cj$hout$hroot$hweird"
  expect_lacks "no secret value in any output (env token)" "$allout" "$secret_a"
  expect_lacks "no secret value in any output (aws cache)" "$allout" "$secret_b"
  if [ -s "$clog" ]; then no "a CLI was run: $(cat "$clog")"; else ok; fi
}

res="$tmp/res"; mkdir -p "$res"
gorder=""
spawn() { # name function args...: run the group in the background, own HOME, output to $res/<name>; at most $jobs_max at once
  gname=$1; shift
  while :; do
    nrun=0; for _ in $(jobs -rp); do nrun=$((nrun + 1)); done
    [ "$nrun" -ge "$jobs_max" ] || break
    sleep 1
  done
  gorder="$gorder $gname"
  (
    export HOME="$tmp/h-$gname" USERPROFILE="$tmp/h-$gname"; mkdir -p "$HOME/.claude"
    pass=0; fail=0
    "$@"
    echo "@@ $pass $fail"
  ) > "$res/$gname" 2>&1 &
}

# slowest first (hung probes and the 5s gh budget), so the short groups fill the gaps
# The timed groups need no isolation: they assert "well under" the 120-300 s stub sleeps (real runs take 5-20 s), so box load cannot flake them.
spawn hang_check_std g_hang_check "$check"
spawn hang_check_notmo g_hang_check "$tmp/check-notmo.sh"
spawn hang_brief_std g_hang_brief "$brief"
spawn hang_brief_notmo g_hang_brief "$tmp/brief-notmo.sh"
spawn docker_std g_docker "$brief"
spawn docker_notmo g_docker "$tmp/brief-notmo.sh"
spawn ghsleep_std g_ghsleep "$brief" std
spawn ghsleep_notmo g_ghsleep "$tmp/brief-notmo.sh" notmo
mi=0
for r in $runners; do
  mi=$((mi + 1)); spawn "matrix$mi" g_matrix "$r" "$mi"
done
ro_chunks=1; [ "${GUYB_RO_FULL:-}" = 1 ] && ro_chunks=8; ri=0
while [ "$ri" -lt "$ro_chunks" ]; do
  spawn "readonly$ri" g_readonly "$ri" "$ro_chunks"; ri=$((ri + 1))
done
spawn migration g_migration
spawn migration_new g_migration_new
spawn env g_env
spawn cleanup_under g_cleanup_under
spawn cleanup_over g_cleanup_over
spawn drift g_drift
spawn regfmt g_regfmt
spawn guard g_guard
spawn plugin g_plugin
spawn gitignore g_gitignore
spawn overdue g_overdue
spawn emptysec g_emptysec
spawn wrapper g_wrapper
spawn connections g_connections
wait

for gname in $gorder; do
  seen=0
  while IFS= read -r line; do
    case "$line" in
      "@@ "*) seen=1; set -- $line; pass=$((pass + $2)); fail=$((fail + $3)) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$res/$gname"
  [ "$seen" -eq 1 ] || no "group $gname: no result (crashed?)"
done

echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
