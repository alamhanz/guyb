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
  mkdir -p "$1/.claude"
  w=$(win "$1")
  git -C "$w" init -q 2>/dev/null
  git -C "$w" config user.name smoke
  git -C "$w" config user.email smoke@example.invalid
  git -C "$w" config commit.gpgsign false
  printf '# fixture\n' > "$1/README.md"
  printf '# fixture\r\n\r\nmax_parallel: 3\r\n' > "$1/.claude/CLAUDE.md"
  printf '# State\r\n\r\n## Next up\r\n- ship the thing\r\n\r\n## Open issues\r\n- PR #7 awaiting review\r\n- flaky test\r\n' > "$1/.claude/STATE.md"
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
