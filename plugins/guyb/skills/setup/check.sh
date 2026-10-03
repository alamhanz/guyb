#!/usr/bin/env bash
# guyb setup checks. Read-only: prints one JSON object, never prompts, never changes cwd or config.
# Usage: check.sh [start-dir]
start_dir="${1:-}"

esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   '; }
has() { command -v "$1" >/dev/null 2>&1; }
# first string value of "key" in a JSON file (no jq needed)
jval() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -n1; }

out=""; blockfail=0
add() { # id status blocking detail fix fixBy
  [ "$2" = fail ] && [ "$3" = true ] && blockfail=$((blockfail + 1))
  [ -n "$out" ] && out="$out,"
  out="$out
    {\"id\":\"$1\",\"status\":\"$2\",\"blocking\":$3,\"detail\":\"$(esc "$4")\",\"fix\":\"$(esc "${5:-}")\",\"fixBy\":\"${6:-none}\"}"
}

claude_dir="$HOME/.claude"
rctext=""
for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zprofile"; do
  [ -f "$f" ] && rctext="$rctext
$(cat "$f" 2>/dev/null)"
done
# rc file to suggest in fix hints: zsh -> .zshrc; macOS bash reads .bash_profile (login shells); else .bashrc
case "$(basename "${SHELL:-}")" in
  zsh) rcfile="~/.zshrc" ;;
  *) if [ "$(uname -s 2>/dev/null)" = Darwin ]; then rcfile="~/.bash_profile"; else rcfile="~/.bashrc"; fi ;;
esac

# GUYB_ROOT: process env -> rc line
root=""; rootsrc=""
if [ -n "${GUYB_ROOT:-}" ]; then root="$GUYB_ROOT"; rootsrc="process env"
else
  line=$(printf '%s\n' "$rctext" | grep -E '^[[:space:]]*(export[[:space:]]+)?GUYB_ROOT=' | tail -n1)
  if [ -n "$line" ]; then root=$(printf '%s' "${line#*GUYB_ROOT=}" | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'); rootsrc="rc line"; fi
fi

# Repo: source line in rc, else known_marketplaces.json
repo=""; reposrc=""
line=$(printf '%s\n' "$rctext" | grep -E '^[[:space:]]*(source|\.)[[:space:]]+.*scripts/launch\.sh' | tail -n1)
if [ -n "$line" ]; then
  repo=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+//; s/^["'"'"']//; s/["'"'"']?[[:space:]]*$//; s#/scripts/launch\.sh.*##'); reposrc="rc line"
fi
mk="$claude_dir/plugins/known_marketplaces.json"
if [ -z "$repo" ] && [ -f "$mk" ]; then
  entry=$(tr -d '\n' < "$mk" | awk '{i=index($0,"\"guyb\""); if(!i)exit; t=substr($0,i); d=0; o=""; for(k=1;k<=length(t);k++){c=substr(t,k,1); o=o c; if(c=="{")d++; else if(c=="}"){d--; if(d==0)break}} print o}')
  p=$(printf '%s' "$entry" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 | sed 's/\\\\/\\/g')
  [ -z "$p" ] && p=$(printf '%s' "$entry" | sed -n 's/.*"installLocation"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 | sed 's/\\\\/\\/g')
  [ -n "$p" ] && repo="$p" && reposrc="marketplace"
fi
launcher=""; [ -n "$repo" ] && launcher="$repo/scripts/launch.sh"

# --- blocking ---
if has claude; then add claude ok true "claude found on PATH"
else add claude fail true "claude not on PATH" "Install Claude Code: https://docs.claude.com/en/docs/claude-code/setup" user; fi

if has git; then add git ok true "$(git --version 2>/dev/null)"
else add git fail true "git not installed" "brew install git (macOS) or sudo apt install git (Linux)" claude-after-consent; fi

if has git; then
  n=$(git config --global user.name 2>/dev/null); e=$(git config --global user.email 2>/dev/null)
  miss=""; [ -z "$n" ] && miss="user.name"; [ -z "$e" ] && miss="${miss:+$miss, }user.email"
  if [ -n "$miss" ]; then add git-identity fail true "missing global $miss" 'git config --global user.name "<name>"; git config --global user.email "<email>"' claude-after-consent
  else add git-identity ok true "global user.name and user.email set"; fi
else add git-identity skip true "git missing"; fi

if [ -n "$launcher" ] && [ -f "$launcher" ]; then add launcher ok true "launcher found ($reposrc)"
else
  d="guyb repo not found"; [ -n "$repo" ] && d="repo $repo has no scripts/launch.sh"
  add launcher fail true "$d" "Run scripts/install.sh from the guyb repo; without it, cd into the project and run claude manually" user
fi

# --- warnings ---
if [ -n "$root" ]; then add root ok false "GUYB_ROOT=$root ($rootsrc)"
else
  fb=""; tgt="<projects folder>"; [ -n "$start_dir" ] && fb="; session start folder $start_dir is used" && tgt="$start_dir"
  add root warn false "GUYB_ROOT not set$fb" "echo 'export GUYB_ROOT=\"$tgt\"' >> $rcfile" claude-after-consent
fi

if printf '%s\n' "$rctext" | grep -q 'scripts/launch\.sh'; then add launcher-profile ok false "launcher source line present in shell rc"
else
  fx="Run scripts/install.sh"; [ -n "$repo" ] && fx="echo 'source \"$repo/scripts/launch.sh\"' >> $rcfile"
  add launcher-profile warn false "no launcher source line in shell rc (the guyb command is unavailable in your terminals)" "$fx" claude-after-consent
fi

profile_md="$claude_dir/guyb/profile.md"
if has gh; then
  gout=$(gh auth status 2>/dev/null); gcode=$?
  if [ $gcode -eq 0 ]; then
    acct=$(printf '%s' "$gout" | sed -n -e 's/.*account \([^ ]*\).*/\1/p' -e t -e 's/.* as \([^ ]*\).*/\1/p' | head -n1); acct="${acct:-unknown}"
    add gh-auth ok false "logged in: yes, account $acct"
    if git config --global --get-all credential.https://github.com.helper 2>/dev/null | grep -Eq "gh(\.exe)?['\"]?[[:space:]]+auth[[:space:]]+git-credential"; then
      add git-cred ok false "HTTPS credential helper: gh"
    else add git-cred warn false "gh is not the HTTPS credential helper for github.com" "gh auth setup-git" claude-after-consent; fi
  else
    add gh-auth warn false "logged in: no" "! gh auth login" user
    add git-cred skip false "gh not logged in"
  fi
elif [ -f "$profile_md" ] && grep -q GitHub "$profile_md"; then
  add gh-auth warn false "gh not installed but profile.md lists GitHub" "Install GitHub CLI (brew install gh), then ! gh auth login" user
  add git-cred skip false "gh missing"
else
  add gh-auth skip false "gh not installed"
  add git-cred skip false "gh not installed"
fi

case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) onwin=1 ;; *) onwin=0 ;; esac
if [ $onwin -eq 1 ]; then
  add terminal ok false "bash launcher runs claude in the current terminal; use the PowerShell launcher (launch.ps1) for new tabs"
elif [ -n "${TMUX:-}" ]; then add terminal ok false "inside tmux"
elif has tmux; then add terminal warn false "tmux installed but not inside a tmux session" "Run guyb <name> yourself, or start tmux first" user
else add terminal warn false "tmux not installed" "Install tmux" user; fi

inst="$claude_dir/plugins/installed_plugins.json"
if [ ! -f "$inst" ] || ! grep -q '"guyb@guyb"' "$inst"; then
  add plugin warn false "guyb plugin not found in installed_plugins.json" "claude plugin install guyb@guyb" claude-after-consent
else
  blk=$(sed -n '/"guyb@guyb"/,/\]/p' "$inst")
  iv=$(printf '%s' "$blk" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  isha=$(printf '%s' "$blk" | sed -n 's/.*"gitCommitSha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  sv=""; ssha=""
  if [ -n "$repo" ]; then
    sv=$(jval "$repo/plugins/guyb/.claude-plugin/plugin.json" version)
    has git && ssha=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
  fi
  fix="claude plugin marketplace update guyb; claude plugin update guyb@guyb (then restart Claude)"
  if [ -z "$sv" ]; then add plugin ok false "installed $iv (${isha:0:7}); source version unknown"
  elif [ "$iv" != "$sv" ] || { [ -n "$ssha" ] && [ -n "$isha" ] && [ "$isha" != "$ssha" ]; }; then
    add plugin warn false "installed $iv (${isha:0:7}), source $sv (${ssha:0:7})" "$fix" claude-after-consent
  else add plugin ok false "up to date: $iv (${isha:0:7})"; fi
fi

if [ -f "$profile_md" ]; then add profile ok false "profile.md exists"
else add profile warn false "no ~/.claude/guyb/profile.md" "/guyb:setup" user; fi

os=unix; [ $onwin -eq 1 ] && os=windows
printf '{\n  "version": 1,\n  "os": "%s",\n  "root": "%s",\n  "repo": "%s",\n  "blockingFailures": %s,\n  "checks": [%s\n  ]\n}\n' \
  "$os" "$(esc "$root")" "$(esc "$repo")" "$blockfail" "$out"
