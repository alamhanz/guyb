#!/usr/bin/env bash
# Static checks for the guyb repo. Read-only; writes nothing. Usage: bash tests/lint.sh
# Checks: bash -n on *.sh, JSON/SVG validity, ASCII only, sh files LF, ps1 files CRLF, no bash 4+ syntax.
# Targets bash 3.2 (macOS /bin/bash): no mapfile, associative arrays, or ${v,,}.
# PowerShell twin: lint.ps1 (parses ps1 files; keep the file rules in sync).
cd "$(dirname "$0")/.." || exit 1

fail=0
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
count() { tr -cd "$1" < "$2" | wc -c | tr -d ' '; }

list() { find "$@" -type f 2>/dev/null | sort; }
sh_files=$(list plugins scripts tests -name '*.sh')
ps1_files=$(list plugins scripts tests -name '*.ps1')
json_files=$(list plugins scripts tests settings .claude-plugin -name '*.json')
svg_files=$(list docs -name '*.svg')
text_files=$( { list plugins scripts tests settings .claude-plugin docs .github \( -name '*.sh' -o -name '*.ps1' -o -name '*.json' -o -name '*.svg' -o -name '*.yml' \); ls .gitattributes 2>/dev/null; } )

parse_with() { # kind file: validate JSON or XML with the first tool available; 2 = no tool
  if [ "$1" = json ] && command -v jq >/dev/null 2>&1; then jq empty "$2" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    if [ "$1" = json ]; then python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$2" >/dev/null 2>&1
    else python3 -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "$2" >/dev/null 2>&1; fi
  elif command -v pwsh >/dev/null 2>&1; then
    if [ "$1" = json ]; then pwsh -NoProfile -Command 'Get-Content -Raw -LiteralPath $args[0] | ConvertFrom-Json | Out-Null' "$2" >/dev/null 2>&1
    else pwsh -NoProfile -Command '[xml](Get-Content -Raw -LiteralPath $args[0]) | Out-Null' "$2" >/dev/null 2>&1; fi
  else return 2; fi
}

echo "bash -n"
for f in $sh_files; do bash -n "$f" 2>/dev/null || bad "$f: bash -n failed"; done

echo "bash 3.2 syntax"
for f in $sh_files; do
  [ "$f" = tests/lint.sh ] && continue
  grep -nE 'declare -A|typeset -A|mapfile|readarray|\$\{[A-Za-z_0-9]+(,,|\^\^)' "$f" >/dev/null 2>&1 && bad "$f: bash 4+ syntax"
done

echo "json"
for f in $json_files; do
  parse_with json "$f"; rc=$?
  [ $rc -eq 1 ] && bad "$f: invalid JSON"
  [ $rc -eq 2 ] && { echo "skip: no jq, python3 or pwsh to validate JSON"; break; }
done

echo "svg"
for f in $svg_files; do
  parse_with xml "$f"; rc=$?
  [ $rc -eq 1 ] && bad "$f: not well-formed XML"
  [ $rc -eq 2 ] && { echo "skip: no python3 or pwsh to validate XML"; break; }
done

echo "ascii (scripts, JSON, SVG, YAML; Markdown may carry the severity emoji)"
for f in $text_files; do
  [ -f "$f" ] || continue
  n=$(LC_ALL=C tr -d '\011\012\015\040-\176' < "$f" | wc -c | tr -d ' ')
  [ "$n" -gt 0 ] && bad "$f: $n non-ASCII or control byte(s)"
done

echo "line endings (sh = LF, ps1 = CRLF)"
for f in $sh_files; do
  [ "$(count '\r' "$f")" -gt 0 ] && bad "$f: sh file contains CR (must be LF)"
done
for f in $ps1_files; do
  lf=$(count '\n' "$f"); cr=$(count '\r' "$f")
  [ "$lf" -ne "$cr" ] && bad "$f: ps1 file is not CRLF ($lf LF, $cr CR)"
done

if [ "$fail" -gt 0 ]; then echo "lint: $fail problem(s)"; exit 1; fi
echo "lint: ok"
