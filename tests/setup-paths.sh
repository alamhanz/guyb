#!/usr/bin/env bash
# Tests that skills/setup/check.sh expands ~, $HOME and ${HOME} in the rc lines it reads, strips quotes,
# and falls back to known_marketplaces.json when the rc path has no launcher (issue #19).
# Usage: bash tests/setup-paths.sh. Fake HOME per case in a temp dir (removed on exit); the cases run in
# parallel (each check.sh run takes ~20 s on Windows). Needs no network or secrets. Targets bash 3.2.
# PowerShell twin: setup-paths.ps1 (same cases for check.ps1).
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-setuppaths.XXXXXX") || exit 1
tmp=$(cd "$tmp" && pwd)
trap 'rm -rf "$tmp"' EXIT
check="$root/plugins/guyb/skills/setup/check.sh"

win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
has() { case $2 in *"$3"*) ok ;; *) no "$1: output lacks '$3'" ;; esac; }

# mkcase <name> <rc text, @H@ = the fake HOME> [marketplace]: HOME with r/scripts/launch.sh and p/ and a .bashrc
mkcase() {
  local h="$tmp/$1"
  mkdir -p "$h/r/scripts" "$h/p" "$h/.claude/plugins"
  : > "$h/r/scripts/launch.sh"
  printf '%s\n' "${2//@H@/$h}" > "$h/.bashrc"
  if [ -n "${3:-}" ]; then
    printf '{"guyb":{"source":{"source":"directory","path":"%s"}}}\n' "$(win "$h/r")" > "$h/.claude/plugins/known_marketplaces.json"
  fi
}
runcase() { # name: run check.sh with the case HOME, output to $tmp/<name>.out
  ( export HOME="$tmp/$1" USERPROFILE="$tmp/$1"; unset GUYB_ROOT CLAUDE_CONFIG_DIR
    bash "$check" > "$tmp/$1.out" 2>&1 ) &
}

mkcase dq   'source "$HOME/r/scripts/launch.sh"'
mkcase tilde '. ~/r/scripts/launch.sh
GUYB_ROOT=~/p'
mkcase brace 'source "${HOME}/r/scripts/launch.sh"
export GUYB_ROOT="${HOME}/p"'
mkcase sq   "source '@H@/r/scripts/launch.sh'"
mkcase fall 'source "@H@/nope/scripts/launch.sh"' yes
for c in dq tilde brace sq fall; do runcase "$c"; done
wait

launcher='"id":"launcher","status":"ok"'
for c in dq tilde brace sq; do has "$c launcher" "$(cat "$tmp/$c.out")" "$launcher"; done
has "fall launcher" "$(cat "$tmp/fall.out")" "$launcher"
has "fall source" "$(cat "$tmp/fall.out")" "launcher found (marketplace)"
has "dq source" "$(cat "$tmp/dq.out")" "launcher found (rc line)"
has "tilde root" "$(cat "$tmp/tilde.out")" "GUYB_ROOT=$tmp/tilde/p (rc line)"
has "brace root" "$(cat "$tmp/brace.out")" "GUYB_ROOT=$tmp/brace/p (rc line)"

echo "setup-paths: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
