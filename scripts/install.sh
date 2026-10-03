#!/usr/bin/env bash
# Installs the guyb plugin, merges recommended permissions (needs jq), and adds the `guyb` launcher to your shell rc.
# Usage: ./scripts/install.sh [--root ~/projects] [--skip-permissions] [--skip-launcher]
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
root="" skip_perms=0 skip_launcher=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --skip-permissions) skip_perms=1; shift ;;
    --skip-launcher) skip_launcher=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v claude >/dev/null || { echo "Claude Code (claude) is not on PATH" >&2; exit 1; }

echo "1/3 Installing plugin..."
claude plugin marketplace add "$repo"
claude plugin install guyb@guyb

if [ $skip_perms -eq 0 ]; then
  echo "2/3 Merging recommended permissions into ~/.claude/settings.json..."
  if command -v jq >/dev/null; then
    s="$HOME/.claude/settings.json"; mkdir -p "$HOME/.claude"; [ -f "$s" ] || echo '{}' > "$s"
    cp "$s" "$s.bak-$(date +%Y%m%d%H%M%S)"
    jq -s '.[0] as $cur | .[1] as $rec | $cur
      | .permissions.allow = (($cur.permissions.allow // []) + $rec.permissions.allow | unique)
      | .permissions.ask   = (($cur.permissions.ask   // []) + $rec.permissions.ask   | unique)' \
      "$s" "$repo/settings/recommended-permissions.json" > "$s.tmp" && mv "$s.tmp" "$s"
  else
    echo "   jq not found - merge settings/recommended-permissions.json into ~/.claude/settings.json by hand"
  fi
else echo "2/3 Skipped permissions."; fi

if [ $skip_launcher -eq 0 ]; then
  rc="$HOME/.bashrc"; [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = zsh ] && rc="$HOME/.zshrc"
  echo "3/3 Adding guyb launcher to $rc..."
  line="source \"$repo/scripts/launch.sh\""
  grep -qF "$line" "$rc" 2>/dev/null || printf '\n# guyb\n%s\n' "$line" >> "$rc"
  [ -n "$root" ] && ! grep -q GUYB_ROOT "$rc" && echo "export GUYB_ROOT=\"$root\"" >> "$rc"
else echo "3/3 Skipped launcher."; fi

echo; echo "Done. Open a new terminal, then run: guyb"
