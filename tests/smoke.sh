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
# `pr view N` prints $GH_STUB_STATE; anything else fails quietly (no network). GH_STUB_SLEEP delays every call, GH_STUB_LOG records the arguments.
stub="$tmp/stub"; mkdir -p "$stub"
cat > "$stub/gh" <<'STUB'
#!/bin/sh
[ -n "$GH_STUB_LOG" ] && echo "$*" >> "$GH_STUB_LOG"
[ -n "$GH_STUB_SLEEP" ] && sleep "$GH_STUB_SLEEP"
if [ "$1" = pr ] && [ "$2" = list ]; then
  [ -n "$GH_STUB_LISTFAIL" ] && exit 1
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
  want="plugin: 0.6.0 installed, 0.7.0 available - run: claude plugin marketplace update guyb; claude plugin update guyb@guyb"
  for v in 0.6.0 0.7.0 0.8.0; do
    printf '{"version":2,"plugins":{"guyb@guyb":[{"scope":"user","version":"%s"}]}}\n' "$v" > "$cfg/installed_plugins.json"
    out=$(bash "$brief" "${pa_w}" 2>&1)
    if [ "$v" = 0.6.0 ]; then expect_has "plugin flag $v" "$out" "$want"; else expect_lacks "plugin flag $v" "$out" "plugin: "; fi
  done
}

g_drift() {
  echo "brief.sh STATE.md drift (stub gh)"
  pd="$tmp/f-drift"; make_fixture "$pd"; pd_w=${pd/#"$tmp"/$tmp_w}
  out=$(GH_STUB_STATE=MERGED bash "$brief" "${pd_w}" 2>&1)
  expect_has "drift MERGED" "$out" "STATE.md drift: PR #7 is MERGED - update STATE.md"
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
  mkdir -p "$lg/.claude/pipeline"
  mv "$lg/.claude/guyb/STATE.md" "$lg/.claude/STATE.md"; rmdir "$lg/.claude/guyb"
  printf "$GUYB_OLD_STATE" > "$lg/.claude/STATE.md"
  { echo "$RUNHDR"; echo '|---|'; runrow x-1 running "$today"; } > "$lg/.claude/pipeline/runs.md"
  out=$(bash "$brief" "${lg_w}" 2>&1)
  expect_has "migrate legacy" "$out" "migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/"
  expect_lacks "migrate legacy" "$out" "conflict:"
  expect_has "migrate legacy fallback" "$out" "STATE.md Next up:"
  expect_has "migrate legacy fallback" "$out" "OLD-NEXT"
  expect_has "migrate legacy runs" "$out" "unfinished runs (1):"
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
  out=$(bash "$brief" "${a_w}" 2>&1)
  expect_lacks "migrate new-only" "$out" "migrate:"
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
  out=$(bash "$brief" "${a_w}" 2>&1)
  expect_has "gitignore missing" "$out" "gitignore: .claude/guyb/pipeline/ not ignored"
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

g_cleanup_legacy() {
  echo "brief.sh cleanup suggestions (legacy pipeline)"
  lc="$tmp/legclean"; make_fixture "$lc"; lc_w=${lc/#"$tmp"/$tmp_w}
  mkdir -p "$lc/.claude/pipeline/progress"; : > "$lc/.claude/pipeline/progress/z-9.md"
  touch -t 202001010000 "$lc/.claude/pipeline/progress/z-9.md"
  out=$(bash "$brief" "${lc_w}" 2>&1)
  expect_has "cleanup stale in legacy pipeline" "$out" "cleanup: 1 pipeline files older than 14 days"
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

g_readonly() { # chunk (0-based) chunks: rows of tests/readonly-cases.tsv with row % chunks == chunk; chunk 0 also runs the extra cases
  echo "guard-readonly.sh (tests/readonly-cases.tsv, chunk $1 of $2)"
  ro="$root/plugins/guyb/hooks/guard-readonly.sh"
  cases="$root/tests/readonly-cases.tsv"
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
  ro_case() { # agent cwd command: hook exit code in $rc
    agent=$1; cwd=$2; cmd=$3
    fields=""
    [ "$agent" = "-" ] || fields="\"agent_type\":\"$agent\","
    case "$cwd" in
      -) ;;
      norepo) fields="$fields\"cwd\":\"${nr_w}\"," ;;
      *) fields="$fields\"cwd\":\"${ar_w}\"," ;;
    esac
    ro_run "{${fields}\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
  }
  n=0; rows=0
  while IFS="$(printf '\t')" read -r exp shell agent cwd cmd note; do
    n=$((n + 1)); [ "$n" -eq 1 ] && continue
    case "$shell" in both | sh) ;; *) continue ;; esac
    rows=$((rows + 1))
    [ $((rows % $2)) -eq "$1" ] || continue
    ro_case "$agent" "$cwd" "$cmd"
    expect_eq "readonly $note: $cmd" "$rc" "$exp"
  done < "$cases"
  [ "$1" -eq 0 ] || return 0
  ro_run 'not json'; expect_eq "readonly bad json" "$rc" 0
  ro_run '{"agent_type":"code-reviewer","tool_input":{"command":""}}'; expect_eq "readonly empty command" "$rc" 0
  for sel in 'Bash(*git*)' 'PowerShell(*git*)'; do
    expect_eq "hooks.json readonly filter $sel" "$(grep -cF "\"if\": \"$sel\"" "$root/plugins/guyb/hooks/hooks.json")" 1
  done
}

g_wrapper() {
  echo "hooks.json guard-readonly bash entry, end to end"
  if command -v jq >/dev/null 2>&1; then
    hcmd=$(jq -r '.hooks.PreToolUse[].hooks[] | select(.shell == "bash") | select(.command | contains("guard-readonly")) | .command' "$root/plugins/guyb/hooks/hooks.json" | tr -d '\r')
    expect_eq "hooks.json readonly bash entry count" "$(printf '%s\n' "$hcmd" | grep -c .)" 1
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
ro_chunks=8; ri=0
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
spawn cleanup_legacy g_cleanup_legacy
spawn wrapper g_wrapper
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
