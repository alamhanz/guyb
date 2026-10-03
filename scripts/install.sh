#!/usr/bin/env bash
# Installs the guyb plugin, merges recommended permissions (needs jq), and adds the `guyb` launcher to your shell rc.
# Usage: ./scripts/install.sh [--root ~/projects] [--skip-permissions] [--skip-launcher]
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
root="" skip_perms=0 skip_launcher=0 perms_missed=0
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
    # drop rules older guyb versions added but no longer recommends ("obsolete"), then add the current ones
    if jq -s '.[0] as $cur | .[1] as $rec | ($rec.obsolete // []) as $old | $cur
      | .permissions.allow = ((($cur.permissions.allow // []) - $old) + $rec.permissions.allow | unique)
      | .permissions.ask   = ((($cur.permissions.ask   // []) - $old) + $rec.permissions.ask   | unique)
      | .permissions.deny  = ((($cur.permissions.deny  // []) - $old) + $rec.permissions.deny  | unique)' \
      "$s" "$repo/settings/recommended-permissions.json" > "$s.tmp"; then
      mv "$s.tmp" "$s"
    else
      rm -f "$s.tmp"
      echo "Could not merge permissions: $s is not valid JSON. Fix it and re-run (backup kept as $s.bak-*)." >&2
      exit 1
    fi
  else
    perms_missed=1
    echo "   WARNING: jq not found, so permissions were NOT merged."
    echo "   Install jq (brew install jq / apt install jq / winget install jqlang.jq) and re-run,"
    echo "   or merge $repo/settings/recommended-permissions.json into ~/.claude/settings.json by hand."
  fi
else echo "2/3 Skipped permissions."; fi

if [ $skip_launcher -eq 0 ]; then
  # zsh -> .zshrc; macOS bash reads .bash_profile (login shells), not .bashrc
  rc="$HOME/.bashrc"
  if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = zsh ]; then rc="$HOME/.zshrc"
  elif [ "$(uname -s)" = Darwin ]; then rc="$HOME/.bash_profile"; fi
  echo "3/3 Adding guyb launcher to $rc..."
  line="source \"$repo/scripts/launch.sh\""
  grep -qF "$line" "$rc" 2>/dev/null || printf '\n# guyb\n%s\n' "$line" >> "$rc"
  [ -n "$root" ] && ! grep -q GUYB_ROOT "$rc" && echo "export GUYB_ROOT=\"$root\"" >> "$rc"
else echo "3/3 Skipped launcher."; fi

echo
if [ $perms_missed -eq 1 ]; then echo "Done (permissions NOT merged). Open a new terminal, then run: guyb"
else echo "Done. Open a new terminal, then run: guyb"; fi
