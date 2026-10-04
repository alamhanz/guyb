#!/usr/bin/env bash
# Smoke tests for the bash helper scripts (brief.sh, check.sh, guard-secrets.sh, guard-readonly.sh).
# Usage: bash tests/smoke.sh. Builds throwaway git repos and a fake HOME in a temp dir (removed on exit);
# writes nothing in the repo, needs no network or secrets, and stubs gh. Targets bash 3.2.
# PowerShell twin: smoke.ps1 (keep the cases in sync).
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-smoke.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
export GIT_TERMINAL_PROMPT=0
unset CLAUDE_CONFIG_DIR

# Mixed (C:/...) paths survive both git and native tools under Git Bash; elsewhere paths pass through.
win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
expect_has() { if has "$2" "$3"; then ok; else no "$1: missing '$3'"; fi; }
expect_lacks() { if has "$2" "$3"; then no "$1: unexpected '$3'"; else ok; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok; else no "$1: got '$2', want '$3'"; fi; }
crs() { printf '%s' "$1" | tr -cd '\r' | wc -c | tr -d ' '; }

json_ok() { # file
  if command -v jq >/dev/null 2>&1; then jq empty "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" >/dev/null 2>&1
  elif command -v pwsh >/dev/null 2>&1; then pwsh -NoProfile -Command 'Get-Content -Raw -LiteralPath $args[0] | ConvertFrom-Json | Out-Null' "$1" >/dev/null 2>&1
  else return 0; fi
}

# Fake HOME: no real profile, config, or git identity is read.
home="$tmp/home"; mkdir -p "$home/.claude"
export HOME="$home"
export USERPROFILE="$home"

# Stub gh: `gh pr view N` prints $GH_STUB_STATE; everything else fails quietly (no network).
stub="$tmp/stub"; mkdir -p "$stub"
cat > "$stub/gh" <<'STUB'
#!/bin/sh
if [ "$1" = pr ] && [ "$2" = view ]; then echo "${GH_STUB_STATE:-OPEN}"; exit 0; fi
exit 1
STUB
chmod +x "$stub/gh"
export PATH="$stub:$PATH"

make_fixture() { # dir
  mkdir -p "$1/.claude/guyb"
  w=$(win "$1")
  git -C "$w" init -q 2>/dev/null
  git -C "$w" config user.name smoke
  git -C "$w" config user.email smoke@example.invalid
  git -C "$w" config commit.gpgsign false
  printf '# fixture\n' > "$1/README.md"
  printf '# fixture\r\n\r\nmax_parallel: 3\r\n' > "$1/.claude/CLAUDE.md"
  printf '# State\r\n\r\n## Next up\r\n- ship the thing\r\n\r\n## Open issues\r\n- PR #7 awaiting review\r\n- flaky test\r\n' > "$1/.claude/guyb/STATE.md"
  git -C "$w" add -A >/dev/null 2>&1
  git -C "$w" commit -q -m init >/dev/null 2>&1
}

a="$tmp/proj"; b="$tmp/my proj [v2]"
make_fixture "$a"; make_fixture "$b"

runners="bash"
[ -x /bin/bash ] && runners="$runners /bin/bash"
command -v zsh >/dev/null 2>&1 && runners="$runners zsh"
run() { # runner script args...
  r=$1; shift
  if [ "$r" = zsh ]; then zsh -c 'bash "$@"' zsh "$@"; else "$r" "$@"; fi
}

brief="$root/plugins/guyb/skills/start/brief.sh"
check="$root/plugins/guyb/skills/setup/check.sh"

echo "brief.sh and check.sh on fixtures ($runners)"
for r in $runners; do
  for d in "$a" "$b"; do
    name=$(basename "$d"); dw=$(win "$d")
    out=$(run "$r" "$brief" "$dw" 2>&1); rc=$?
    expect_eq "brief $r $name exit" "$rc" 0
    expect_has "brief $r $name" "$out" "project: $name"
    expect_has "brief $r $name" "$out" "branch: "
    expect_has "brief $r $name" "$out" "max parallel: 3 (project)"
    expect_has "brief $r $name" "$out" "STATE.md Next up:"
    expect_has "brief $r $name" "$out" "STATE.md Open issues:"
    expect_eq "brief $r $name CR count" "$(crs "$out")" 0
    expect_lacks "brief $r $name" "$out" "plugin: "
    run "$r" "$check" "$dw" > "$tmp/check.json" 2>/dev/null; rc=$?
    expect_eq "check $r $name exit" "$rc" 0
    if json_ok "$(win "$tmp/check.json")"; then ok; else no "check $r $name: output is not valid JSON"; fi
    expect_has "check $r $name" "$(cat "$tmp/check.json")" '"version": 1'
  done
done

echo "brief.sh outdated plugin flag"
cfg="$home/.claude/plugins"; mk="$tmp/marketplace"
mkdir -p "$cfg" "$mk/plugins/guyb/.claude-plugin"
printf '{"name":"guyb","version":"0.7.0"}\n' > "$mk/plugins/guyb/.claude-plugin/plugin.json"
printf '{"guyb":{"source":{"source":"directory","path":"%s"}}}\n' "$(win "$mk")" > "$cfg/known_marketplaces.json"
want="plugin: 0.6.0 installed, 0.7.0 available - run: claude plugin marketplace update guyb; claude plugin update guyb@guyb"
for v in 0.6.0 0.7.0 0.8.0; do
  printf '{"version":2,"plugins":{"guyb@guyb":[{"scope":"user","version":"%s"}]}}\n' "$v" > "$cfg/installed_plugins.json"
  out=$(bash "$brief" "$(win "$a")" 2>&1)
  if [ "$v" = 0.6.0 ]; then expect_has "plugin flag $v" "$out" "$want"; else expect_lacks "plugin flag $v" "$out" "plugin: "; fi
done
rm -f "$cfg/installed_plugins.json" "$cfg/known_marketplaces.json"

echo "brief.sh STATE.md drift (stub gh)"
out=$(GH_STUB_STATE=MERGED bash "$brief" "$(win "$a")" 2>&1)
expect_has "drift MERGED" "$out" "STATE.md drift: PR #7 is MERGED - update STATE.md"
out=$(GH_STUB_STATE=OPEN bash "$brief" "$(win "$a")" 2>&1)
expect_lacks "drift OPEN" "$out" "STATE.md drift"

# Fixture helpers for migration and cleanup cases (bash 3.2, BSD touch -t for mtimes).
gen_lines() { awk -v n="$1" -v p="$2" 'BEGIN { for (i = 1; i <= n; i++) print p " " i }'; } # count prefix
gen_table() { # file header count id-prefix status
  { printf '%s\n|---|\n' "$2"; awk -v n="$3" -v p="$4" -v s="$5" 'BEGIN { for (i = 1; i <= n; i++) print "| " p i " | x-1 | q | no | a | " s " |" }'; } > "$1"
}
RUNHDR='| ID | Agent | Model | Task | Wave | After | Status | Started | Tokens |'
runrow() { printf '| %s | implementer | sonnet | t | 1 | - | %s | %s | 1k |\n' "$1" "$2" "$3"; } # id status date
GUYB_OLD_STATE='# State\n\n## Next up\n- OLD-NEXT\n\n## Open issues\n- old issue\n\n## Decisions\n- d\n\n## Recent changes\n- c\n'
today=$(date +%Y-%m-%d)

echo "brief.sh migration detection"
lg="$tmp/legacy"; make_fixture "$lg"
mkdir -p "$lg/.claude/pipeline"
mv "$lg/.claude/guyb/STATE.md" "$lg/.claude/STATE.md"; rmdir "$lg/.claude/guyb"
printf "$GUYB_OLD_STATE" > "$lg/.claude/STATE.md"
{ echo "$RUNHDR"; echo '|---|'; runrow x-1 running "$today"; } > "$lg/.claude/pipeline/runs.md"
out=$(bash "$brief" "$(win "$lg")" 2>&1)
expect_has "migrate legacy" "$out" "migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/"
expect_lacks "migrate legacy" "$out" "conflict:"
expect_has "migrate legacy fallback" "$out" "STATE.md Next up:"
expect_has "migrate legacy fallback" "$out" "OLD-NEXT"
expect_has "migrate legacy runs" "$out" "unfinished runs (1):"
expect_has "migrate legacy gitignore" "$out" "gitignore: .claude/guyb/pipeline/ not ignored"
printf '.claude/pipeline/\n' > "$lg/.gitignore"
out=$(bash "$brief" "$(win "$lg")" 2>&1)
expect_lacks "legacy gitignore accepted while legacy pipe is used" "$out" "gitignore:"
printf '<!-- guyb:state -->\n# State\n' > "$lg/.claude/STATE.md"
out=$(bash "$brief" "$(win "$lg")" 2>&1)
expect_has "migrate marker file" "$out" "migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/"
printf '\357\273\277<!-- guyb:state -->\n# State\n' > "$lg/.claude/STATE.md"
out=$(bash "$brief" "$(win "$lg")" 2>&1)
expect_has "migrate BOM before marker" "$out" "migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/"
printf '# Project\r\n\r\n## Overview\r\n\r\n## Next Up\r\n- TC-NEXT\r\n\r\n## Open Issues\r\n\r\n## Last Updated\r\n2026-01-01\r\n\r\n## Decisions\r\n\r\n## Recent Changes\r\n' > "$lg/.claude/STATE.md"
out=$(bash "$brief" "$(win "$lg")" 2>&1)
expect_has "migrate real-world title-case headings" "$out" "migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/"
expect_has "migrate real-world headings read" "$out" "TC-NEXT"
printf '# Notes\n\n## Next up\n\n## Open issues\n\n## Decisions\n- FOREIGN3\n' > "$lg/.claude/STATE.md"
out=$(bash "$brief" "$(win "$lg")" 2>&1)
expect_lacks "foreign file with 3 of 4 headings" "$out" "migrate: move .claude/STATE.md"
expect_lacks "foreign file with 3 of 4 headings" "$out" "FOREIGN3"
printf '# Notes from another tool\n\n## Next up\n- FOREIGN-NEXT\n' > "$lg/.claude/STATE.md"
out=$(bash "$brief" "$(win "$lg")" 2>&1)
expect_has "foreign STATE.md not moved" "$out" "migrate: move .claude/pipeline/ to .claude/guyb/"
expect_lacks "foreign STATE.md not moved" "$out" "migrate: move .claude/STATE.md"
expect_lacks "foreign STATE.md not read" "$out" "FOREIGN-NEXT"
expect_has "foreign STATE.md not read" "$out" "STATE.md: missing"
out=$(bash "$brief" "$(win "$a")" 2>&1)
expect_lacks "migrate new-only" "$out" "migrate:"
printf "$GUYB_OLD_STATE" > "$a/.claude/STATE.md"
out=$(bash "$brief" "$(win "$a")" 2>&1)
expect_has "migrate both STATE" "$out" "conflict: .claude/STATE.md and .claude/guyb/STATE.md both exist"
expect_lacks "migrate both STATE" "$out" "OLD-NEXT"
expect_has "migrate both STATE" "$out" "ship the thing"
printf '# Notes from another tool\n' > "$a/.claude/STATE.md"
out=$(bash "$brief" "$(win "$a")" 2>&1)
expect_lacks "foreign STATE.md beside new one" "$out" "migrate:"
rm -f "$a/.claude/STATE.md"
mkdir -p "$a/.claude/pipeline" "$a/.claude/guyb/pipeline"
out=$(bash "$brief" "$(win "$a")" 2>&1)
expect_has "migrate both pipeline" "$out" "migrate: conflict: .claude/pipeline/ and .claude/guyb/pipeline/ both exist"
rmdir "$a/.claude/pipeline"

echo "brief.sh empty section, question rows, root dir"
ep="$tmp/empty-sec"; mkdir -p "$ep/.claude/guyb/pipeline"
printf '# Next up\n\n# Open issues\n- one\n' > "$ep/.claude/guyb/STATE.md"
printf '| Q | Question | Run | Status |\n|---|---|---|---|\n| Q1 | what | me | open |\n| Q2 | a |  | open |\n' > "$ep/.claude/guyb/pipeline/questions.md"
out=$(bash "$brief" "$(win "$ep")" 2>&1)
expect_lacks "empty section heading" "$out" "STATE.md Next up:"
expect_has "empty section heading" "$out" "STATE.md Open issues:"
expect_has "question row no trailing space" "$out" "  Q1 | what | me | open"
case "$out" in *"open "$'\n'*|*"open ") no "question row trailing space" ;; *) ok ;; esac
out=$(bash "$brief" / 2>&1 </dev/null)
expect_has "root dir kept" "$out" "project: /"

echo "brief.sh gitignore check"
out=$(bash "$brief" "$(win "$a")" 2>&1)
expect_has "gitignore missing" "$out" "gitignore: .claude/guyb/pipeline/ not ignored"
for gi in '.claude/guyb/pipeline/' '/.claude/guyb/pipeline'; do
  printf 'node_modules/\n%s\n' "$gi" > "$a/.gitignore"
  out=$(bash "$brief" "$(win "$a")" 2>&1)
  expect_lacks "gitignore $gi" "$out" "gitignore:"
  expect_lacks "gitignore $gi" "$out" "warn:"
done
printf '.claude/\n' > "$a/.gitignore"
out=$(bash "$brief" "$(win "$a")" 2>&1)
expect_has "gitignore .claude/" "$out" "warn: .gitignore ignores .claude/ - guyb STATE.md will not be committed"
expect_lacks "gitignore .claude/" "$out" "gitignore:"
rm -f "$a/.gitignore"; rmdir "$a/.claude/guyb/pipeline"

echo "brief.sh cleanup suggestions"
mk_clean() { # dir claude-lines state-lines registry-rows
  make_fixture "$1"
  gen_lines "$2" "line" > "$1/.claude/CLAUDE.md"
  { printf '# State\n\n## Next up\n- x\n\n## Open issues\n- y\n'; gen_lines "$(($3 - 7))" "filler"; } > "$1/.claude/guyb/STATE.md"
  p="$1/.claude/guyb/pipeline"; mkdir -p "$p/progress" "$p/reports" "$p/plans" "$p/brand/x-1"
  { echo "$RUNHDR"; echo '|---|'; runrow x-1 done 2020-01-01; runrow x-2 running "$today"; awk -v n="$4" 'BEGIN { for (i = 1; i <= n - 2; i++) printf "| f-%d | implementer | sonnet | t | 1 | - | done | 2020-01-01 | 1k |\n", i }'; } > "$p/runs.md"
  gen_table "$p/questions.md" '| ID | Run | Question | Blocking | Assumed | Status |' "$4" Q answered
  : > "$p/progress/x-1.md"; : > "$p/progress/x-2.md"; : > "$p/progress/x-3.md"; : > "$p/brand/x-1/a.svg"
  touch -t 202001010000 "$p/progress/x-1.md" "$p/progress/x-2.md" "$p/brand/x-1/a.svg"
}
snap() { { find "$1" | sort; git -C "$(win "$1")" status --short 2>/dev/null; }; }
ov="$tmp/over"; mk_clean "$ov" 201 301 201
before=$(snap "$ov")
out=$(bash "$brief" "$(win "$ov")" 2>&1)
after=$(snap "$ov")
expect_has "cleanup over" "$out" "cleanup: CLAUDE.md 201 lines (>200); STATE.md 301 lines (>300); runs.md 201 rows (>200); questions.md 201 rows (>200); 2 pipeline files older than 14 days"
expect_lacks "cleanup over" "$out" "overdue:"
expect_eq "brief leaves fixture unchanged" "$after" "$before"
un="$tmp/under"; mk_clean "$un" 200 300 200
rm -f "$un/.claude/guyb/pipeline/progress/x-1.md" "$un/.claude/guyb/pipeline/brand/x-1/a.svg"
out=$(bash "$brief" "$(win "$un")" 2>&1)
expect_lacks "cleanup under limits" "$out" "cleanup:"
printf '# fixture\n\n- cleanup_state_lines: 10\ncleanup_days: 0\ncleanup_rows: abc\n' > "$un/.claude/CLAUDE.md"
out=$(bash "$brief" "$(win "$un")" 2>&1)
expect_has "cleanup override" "$out" "cleanup: STATE.md 300 lines (>10)"
expect_lacks "cleanup invalid rows ignored" "$out" "rows"
expect_lacks "cleanup invalid days ignored" "$out" "older than"
mkdir -p "$home/.claude/guyb"; printf 'cleanup_days: 3\n' > "$home/.claude/guyb/profile.md"
touch -t 202001010000 "$un/.claude/guyb/pipeline/progress/x-3.md"
out=$(bash "$brief" "$(win "$un")" 2>&1)
expect_has "cleanup profile days" "$out" "1 pipeline files older than 3 days"
rm -f "$home/.claude/guyb/profile.md"
lc="$tmp/legclean"; make_fixture "$lc"
mkdir -p "$lc/.claude/pipeline/progress"; : > "$lc/.claude/pipeline/progress/z-9.md"
touch -t 202001010000 "$lc/.claude/pipeline/progress/z-9.md"
out=$(bash "$brief" "$(win "$lc")" 2>&1)
expect_has "cleanup stale in legacy pipeline" "$out" "cleanup: 1 pipeline files older than 14 days"

echo "brief.sh overdue items"
od="$tmp/overdue"; make_fixture "$od"; mkdir -p "$od/.claude/guyb/pipeline"
{ echo "$RUNHDR"; echo '|---|'; runrow y-1 running 2020-01-01; runrow y-2 queued "2020-01-02 10:30"; runrow y-3 done 2020-01-01; runrow y-4 running "$today"; runrow y-5 blocked 2020-02-01
  runrow y-6 running 2020-03-01; runrow y-7 running 2020-03-02; } > "$od/.claude/guyb/pipeline/runs.md"
{ echo '| ID | Run | Question | Blocking | Assumed | Status |'; echo '|---|---|---|---|---|---|'
  echo '| Q1 | y-1 | old open | no | a | open |'; echo '| Q2 | y-4 | fresh open | no | a | open |'; echo '| Q3 | y-1 | old answered | no | a | answered |'; } > "$od/.claude/guyb/pipeline/questions.md"
out=$(bash "$brief" "$(win "$od")" 2>&1)
expect_has "overdue list" "$out" "overdue: y-1, y-2, y-5, y-6, y-7, +1 more"
{ echo "$RUNHDR"; echo '|---|'; runrow y-1 running 2020-01-01; runrow y-3 done 2020-01-01; } > "$od/.claude/guyb/pipeline/runs.md"
out=$(bash "$brief" "$(win "$od")" 2>&1)
expect_has "overdue runs and questions" "$out" "overdue: y-1, Q1"

echo "brief.sh registry formats and run ids"
rg="$tmp/regfmt"; make_fixture "$rg"; rp="$rg/.claude/guyb/pipeline"; mkdir -p "$rp/progress"
{ echo "$RUNHDR"; echo '|---|'; runrow mien-dev-3 running 2020-01-01; runrow r-6b running "$today"; runrow r-6 done 2020-01-01; } > "$rp/runs.md"
{ echo '| Q | Run | Agent | Question | Blocking | Assumed | Status | Answer |'; echo '|---|---|---|---|---|---|---|---|'
  echo '| Q1 | mien-dev-3 | architect | old open | no | a | open | |'; echo '| Q2 | r-6b | architect | fresh | no | a | open | |'; } > "$rp/questions.md"
out=$(bash "$brief" "$(win "$rg")" 2>&1)
expect_has "overdue hyphenated id, Q-format questions" "$out" "overdue: mien-dev-3, Q1"
printf '| ID | Run | Question | Blocking | Assumed | Status |\n|---|---|---|---|---|---|\n| Q1 | mien-dev-3 | old open | no | a | open |\n' > "$rp/questions.md"
out=$(bash "$brief" "$(win "$rg")" 2>&1)
expect_has "overdue ID-format questions" "$out" "overdue: mien-dev-3, Q1"
: > "$rp/progress/r-6b.md"; : > "$rp/progress/r-6.md"; : > "$rp/progress/mien-dev-3-notes.md"
touch -t 202001010000 "$rp/progress/r-6b.md" "$rp/progress/r-6.md" "$rp/progress/mien-dev-3-notes.md"
out=$(bash "$brief" "$(win "$rg")" 2>&1)
expect_has "stale: r-6b and prefix ids active, r-6 done" "$out" "cleanup: 1 pipeline files older than 14 days"
printf '.Claude/guyb/pipeline/\n' > "$rg/.gitignore"
out=$(bash "$brief" "$(win "$rg")" 2>&1)
expect_has "gitignore is case-sensitive" "$out" "gitignore: .claude/guyb/pipeline/ not ignored"

echo "brief.sh and check.sh toolchain detection"
ep="$tmp/envpy"; mkdir -p "$ep"; printf '99.1\r\n' > "$ep/.python-version"
out=$(bash "$brief" "$(win "$ep")" 2>&1)
expect_has "env python" "$out" "env: python wants 99.1 (.python-version), found"
expect_has "env python" "$out" ".venv missing"
mkdir -p "$ep/.venv"; out=$(bash "$brief" "$(win "$ep")" 2>&1)
expect_lacks "env python venv present" "$out" ".venv missing"
en="$tmp/envnode"; mkdir -p "$en"; printf '{"name":"x"}\n' > "$en/package.json"; : > "$en/pnpm-lock.yaml"
out=$(bash "$brief" "$(win "$en")" 2>&1)
expect_has "env node" "$out" "node_modules missing (pnpm)"
ee="$tmp/envempty"; mkdir -p "$ee"
out=$(bash "$brief" "$(win "$ee")" 2>&1)
expect_lacks "env empty folder" "$out" "env:"
ed="$tmp/envdocker"; mkdir -p "$ed"; : > "$ed/compose.yaml"
mkdir -p "$tmp/dfail" "$tmp/dsleep"
printf '#!/bin/sh\nexit 1\n' > "$tmp/dfail/docker"; printf '#!/bin/sh\nsleep 30 &\nsleep 30\n' > "$tmp/dsleep/docker"
chmod +x "$tmp/dfail/docker" "$tmp/dsleep/docker"
# Run twice: as shipped, and with timeout/gtimeout hidden (stock macOS) to exercise the poll-and-kill fallback.
sed -e 's/command -v timeout /command -v no-such-timeout /' -e 's/command -v gtimeout /command -v no-such-gtimeout /' "$brief" > "$tmp/brief-notmo.sh"
for bv in "$brief" "$tmp/brief-notmo.sh"; do
  bn=$(basename "$bv")
  out=$(PATH="$tmp/dfail:$PATH" bash "$bv" "$(win "$ed")" 2>&1)
  expect_has "env docker down $bn" "$out" "env: docker daemon not running (compose.yaml)"
  t0=$SECONDS; out=$(PATH="$tmp/dsleep:$PATH" bash "$bv" "$(win "$ed")" 2>&1); dt=$((SECONDS - t0))
  expect_has "env docker hung $bn" "$out" "env: docker daemon not responding (compose.yaml)"
  if [ "$dt" -lt 10 ]; then ok; else no "env docker hung $bn: brief took ${dt}s"; fi
done
if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
  out=$(bash "$brief" "$(win "$ed")" 2>&1)
  expect_has "env docker missing" "$out" "env: docker not installed (compose.yaml)"
  cr="$tmp/croot"; mkdir -p "$cr/svc"; : > "$cr/svc/Dockerfile"
  GUYB_ROOT="$(win "$cr")" bash "$check" > "$tmp/check2.json" 2>/dev/null
  expect_has "check container" "$(cat "$tmp/check2.json")" '"id":"container","status":"warn"'
  expect_has "check container" "$(cat "$tmp/check2.json")" '"fix":"'
fi
bash "$check" "$(win "$ee")" > "$tmp/check3.json" 2>/dev/null
if json_ok "$(win "$tmp/check3.json")"; then ok; else no "check toolchain: output is not valid JSON"; fi
for id in container python node uv; do expect_has "check $id" "$(cat "$tmp/check3.json")" "\"id\":\"$id\""; done
expect_lacks "check toolchain" "$(cat "$tmp/check3.json")" '"blocking":true,"detail":"python'

# every version probe is capped too: a hanging node must not stall check.sh or brief.sh (with and without timeout)
mkdir -p "$tmp/nsleep"; printf '#!/bin/sh\nsleep 30 &\nsleep 30\n' > "$tmp/nsleep/node"; chmod +x "$tmp/nsleep/node"
sed -e 's/has timeout \&\& tmo=timeout/has no-such-timeout \&\& tmo=timeout/' -e 's/has gtimeout \&\& /has no-such-gtimeout \&\& /' "$check" > "$tmp/check-notmo.sh"
en2="$tmp/envnode2"; mkdir -p "$en2"; printf '{"name":"x"}\n' > "$en2/package.json"
for cv in "$check" "$tmp/check-notmo.sh"; do
  t0=$SECONDS; PATH="$tmp/nsleep:$PATH" bash "$cv" "$(win "$ee")" > "$tmp/check4.json" 2>/dev/null; dt=$((SECONDS - t0))
  if [ "$dt" -lt 25 ]; then ok; else no "check hung node $(basename "$cv"): took ${dt}s"; fi
done
for bv in "$brief" "$tmp/brief-notmo.sh"; do
  t0=$SECONDS; out=$(PATH="$tmp/nsleep:$PATH" bash "$bv" "$(win "$en2")" 2>&1); dt=$((SECONDS - t0))
  expect_has "env hung node $(basename "$bv")" "$out" "node not installed"
  if [ "$dt" -lt 12 ]; then ok; else no "brief hung node $(basename "$bv"): took ${dt}s"; fi
done

echo "guard-secrets.sh"
g="$tmp/guarded"; make_fixture "$g"
guard="$root/plugins/guyb/hooks/guard-secrets.sh"
printf 'KEY=value\n' > "$g/.env"; printf 'KEY=\n' > "$g/.env.example"
git -C "$(win "$g")" add .env >/dev/null 2>&1
err=$(cd "$g" && bash "$guard" 2>&1 >/dev/null); rc=$?
expect_eq "guard staged .env exit" "$rc" 2
expect_has "guard staged .env" "$err" ".env"
git -C "$(win "$g")" reset -q >/dev/null 2>&1
git -C "$(win "$g")" add .env.example >/dev/null 2>&1
(cd "$g" && bash "$guard" >/dev/null 2>&1); expect_eq "guard staged .env.example exit" "$?" 0
(cd "$tmp" && bash "$guard" >/dev/null 2>&1); expect_eq "guard outside a repo exit" "$?" 0

echo "guard-readonly.sh"
ro="$root/plugins/guyb/hooks/guard-readonly.sh"
hook() { printf '{"agent_type":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2" | bash "$ro" >/dev/null 2>&1; echo $?; }
expect_eq "readonly reviewer git add" "$(hook guyb:code-reviewer 'git add .')" 2
expect_eq "readonly bare architect git push" "$(hook architect 'git push origin main')" 2
expect_eq "readonly reviewer git status" "$(hook guyb:code-reviewer 'git status')" 0
expect_eq "readonly implementer git add" "$(hook guyb:implementer 'git add .')" 0
expect_eq "readonly main session git add" "$(printf '{"tool_input":{"command":"git add ."}}' | bash "$ro" >/dev/null 2>&1; echo $?)" 0
expect_eq "readonly bad json" "$(printf 'not json' | bash "$ro" >/dev/null 2>&1; echo $?)" 0

echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
