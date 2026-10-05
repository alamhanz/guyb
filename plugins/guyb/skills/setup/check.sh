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
# shellcheck disable=SC2088 # rcfile is display text, the tilde is meant literally
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

# --- toolchain (never blocking, never installs) ---
tmo=""
has timeout && tmo=timeout
[ -z "$tmo" ] && has gtimeout && tmo=gtimeout
# 3s cap on probes; without a timeout binary (stock macOS): background to a temp file, poll, kill
vt() {
  if [ -n "$tmo" ]; then "$tmo" 3 "$@"; return; fi
  vf=$(mktemp "${TMPDIR:-/tmp}/guyb-probe.XXXXXX" 2>/dev/null) || { "$@"; return; }
  "$@" >"$vf" 2>&1 </dev/null &
  vp=$!; vn=0
  while kill -0 "$vp" 2>/dev/null && [ $vn -lt 30 ]; do sleep 0.1; vn=$((vn + 1)); done
  if kill -0 "$vp" 2>/dev/null; then
    has pkill && pkill -P "$vp" 2>/dev/null
    kill "$vp" 2>/dev/null
  fi
  wait "$vp" 2>/dev/null; cat "$vf" 2>/dev/null; rm -f "$vf"
}
# daemon probe, 3s cap, exit 124 on timeout; portable (no timeout binary on stock macOS: background, poll, kill)
dprobe() {
  if [ -n "$tmo" ]; then "$tmo" 3 "$@" >/dev/null 2>&1 </dev/null; return $?; fi
  "$@" >/dev/null 2>&1 </dev/null &
  dp=$!; dn=0
  while kill -0 "$dp" 2>/dev/null && [ $dn -lt 30 ]; do sleep 0.1; dn=$((dn + 1)); done
  if kill -0 "$dp" 2>/dev/null; then
    has pkill && pkill -P "$dp" 2>/dev/null
    kill "$dp" 2>/dev/null; wait "$dp" 2>/dev/null; return 124
  fi
  wait "$dp"; return $?
}
case "$(uname -s 2>/dev/null)" in
  Darwin) cfix="brew install --cask docker (or brew install podman)"; ufix="brew install uv"; nfix="brew install fnm" ;;
  *) if [ $onwin -eq 1 ]; then
       cfix="winget install Docker.DockerDesktop (needs admin and WSL2; license terms apply to larger companies; alternative: podman)"
       ufix="winget install astral-sh.uv"; nfix="winget install Schniz.fnm"
     else
       cfix="sudo apt install docker.io docker-compose-v2 (or sudo apt install podman)"
       ufix="curl -LsSf https://astral.sh/uv/install.sh | sh"; nfix="curl -fsSL https://fnm.vercel.app/install | bash"
     fi ;;
esac

# container-use: project folders one level under the root with container files (cap 200, no recursion)
cscan="${root:-$start_dir}"; ncont=0; nscan=0
if [ -n "$cscan" ] && [ -d "$cscan" ]; then
  for d in "$cscan"/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in node_modules) continue ;; esac
    nscan=$((nscan + 1)); [ $nscan -gt 200 ] && break
    for cf in Dockerfile compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
      [ -f "${d}$cf" ] && { ncont=$((ncont + 1)); break; }
    done
  done
fi

cbin=""
if has docker; then cbin=docker; elif has podman; then cbin=podman; fi
if [ -n "$cbin" ]; then
  cv=$(vt "$cbin" --version 2>/dev/null </dev/null | tr -d '\r' | sed -n 's/.*[Vv]ersion \([0-9][0-9.]*\).*/\1/p' | head -n1)
  cd1="$cbin${cv:+ $cv}"
  if [ "$cbin" = docker ]; then dprobe docker info --format '{{.ServerVersion}}'; crc=$?
  else dprobe podman info --format '{{.Version.Version}}'; crc=$?; fi
  if [ $crc -eq 0 ]; then add container ok false "$cd1, daemon running"
  else
    if [ "$cbin" = podman ]; then dfix="podman machine start"
    elif [ $onwin -eq 1 ] || [ "$(uname -s 2>/dev/null)" = Darwin ]; then dfix="Start Docker Desktop"
    else dfix="sudo systemctl start docker"; fi
    dd="daemon not running"; [ $crc -eq 124 ] && dd="daemon not responding"
    add container warn false "$cd1, $dd" "$dfix" user
  fi
elif [ $ncont -gt 0 ]; then
  add container warn false "docker/podman not installed; $ncont project folder(s) use containers" "$cfix" user
else add container skip false "docker/podman not installed; no container projects found"; fi

pv=""
for pc in python3 python; do
  has "$pc" || continue
  pv=$(vt "$pc" --version 2>&1 </dev/null | tr -d '\r' | sed -n 's/^Python \([0-9][0-9]*\.[0-9][0-9.]*\).*/\1/p' | head -n1)
  [ -n "$pv" ] && break
done
if [ -z "$pv" ] && [ $onwin -eq 1 ] && has py; then
  pv=$(vt py -3 --version 2>&1 </dev/null | tr -d '\r' | sed -n 's/^Python \([0-9][0-9]*\.[0-9][0-9.]*\).*/\1/p' | head -n1)
fi
if [ -n "$pv" ]; then add python ok false "python $pv"
else add python skip false "python not installed" "uv python install <version>" user; fi

nv=""
has node && nv=$(vt node --version 2>&1 </dev/null | tr -d '\r' | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9.]*\).*/\1/p' | head -n1)
if [ -n "$nv" ]; then add node ok false "node $nv"
else add node skip false "node not installed" "$nfix" user; fi

uvv=""
has uv && uvv=$(vt uv --version 2>&1 </dev/null | tr -d '\r' | sed -n 's/^uv \([0-9][0-9]*\.[0-9][0-9.]*\).*/\1/p' | head -n1)
if [ -n "$uvv" ]; then add uv ok false "uv $uvv"
else add uv skip false "uv not installed" "$ufix" user; fi

os=unix; [ $onwin -eq 1 ] && os=windows
printf '{\n  "version": 1,\n  "os": "%s",\n  "root": "%s",\n  "repo": "%s",\n  "blockingFailures": %s,\n  "checks": [%s\n  ]\n}\n' \
  "$os" "$(esc "$root")" "$(esc "$repo")" "$blockfail" "$out"
