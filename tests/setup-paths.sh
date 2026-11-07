#!/usr/bin/env bash
# Tests that skills/setup/check.sh expands ~, $HOME and ${HOME} in the rc lines it reads, strips quotes,
# falls back to known_marketplaces.json when the rc path has no launcher (issue #19), and reports
# GUYB_HOME and a multi-entry GUYB_ROOT (roots, missing entries, per-entry ~ expansion).
# Usage: bash tests/setup-paths.sh. Fake HOME per case in a temp dir (removed on exit); the cases run in
# parallel (each check.sh run takes ~20 s on Windows). Needs no network or secrets. Targets bash 3.2.
# PowerShell twin: setup-paths.ps1 (same cases for check.ps1).
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-setuppaths.XXXXXX") || exit 1
tmp=$(cd "$tmp" && pwd)
trap 'rm -rf "$tmp"' EXIT
check="$root/plugins/guyb/skills/setup/check.sh"

case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) sep=';' ;; *) sep=':' ;; esac
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
  ( export HOME="$tmp/$1" USERPROFILE="$tmp/$1"; unset GUYB_ROOT GUYB_HOME CLAUDE_CONFIG_DIR
    bash "$check" > "$tmp/$1.out" 2>&1 ) &
}

mkcase dq   'source "$HOME/r/scripts/launch.sh"'
mkcase tilde '. ~/r/scripts/launch.sh
GUYB_ROOT=~/p'
mkcase brace 'source "${HOME}/r/scripts/launch.sh"
export GUYB_ROOT="${HOME}/p"'
mkcase sq   "source '@H@/r/scripts/launch.sh'"
mkcase fall 'source "@H@/nope/scripts/launch.sh"' yes
mkcase multi "export GUYB_ROOT=\"~/p$sep~/q$sep~/gone\""
mkdir -p "$tmp/multi/q"
mkcase home 'export GUYB_HOME=~/h'
mkdir -p "$tmp/home/h"
mkcase nohome ''
mkcase homegone 'export GUYB_HOME="@H@/gone"'
for c in dq tilde brace sq fall multi home nohome homegone; do runcase "$c"; done
wait

launcher='"id":"launcher","status":"ok"'
for c in dq tilde brace sq; do has "$c launcher" "$(cat "$tmp/$c.out")" "$launcher"; done
has "fall launcher" "$(cat "$tmp/fall.out")" "$launcher"
has "fall source" "$(cat "$tmp/fall.out")" "launcher found (marketplace)"
has "dq source" "$(cat "$tmp/dq.out")" "launcher found (rc line)"
has "tilde root" "$(cat "$tmp/tilde.out")" "GUYB_ROOT=$tmp/tilde/p (rc line)"
has "brace root" "$(cat "$tmp/brace.out")" "GUYB_ROOT=$tmp/brace/p (rc line)"
has "multi roots" "$(cat "$tmp/multi.out")" "\"roots\": [\"$tmp/multi/p\", \"$tmp/multi/q\", \"$tmp/multi/gone\"]"
has "multi root warn" "$(cat "$tmp/multi.out")" "GUYB_ROOT entry not found: $tmp/multi/gone (rc line)"
has "multi root str" "$(cat "$tmp/multi.out")" "\"root\": \"$tmp/multi/p$sep$tmp/multi/q$sep$tmp/multi/gone\""
has "tilde roots" "$(cat "$tmp/tilde.out")" "\"roots\": [\"$tmp/tilde/p\"]"
has "tilde root ok" "$(cat "$tmp/tilde.out")" '"id":"root","status":"ok"'
has "home" "$(cat "$tmp/home.out")" "GUYB_HOME=$tmp/home/h (rc line)"
has "home json" "$(cat "$tmp/home.out")" "\"home\": \"$tmp/home/h\""
has "nohome" "$(cat "$tmp/nohome.out")" "GUYB_HOME not set; home = none"
has "nohome roots" "$(cat "$tmp/nohome.out")" '"roots": []'
has "homegone" "$(cat "$tmp/homegone.out")" "GUYB_HOME not found: $tmp/homegone/gone (rc line)"

echo "setup-paths: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
