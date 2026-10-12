#!/usr/bin/env bash
# Installs pwsh and shellcheck on a Linux dev box/container that lacks them. Idempotent, silent on success.
# Never prompts, never fails the session (always exit 0). sudo only as root or via `sudo -n`; pwsh goes under $HOME/.local.
# Worst case ~150 s (apt 60 s + curl 2 x 45 s), under the 180 s hook timeout in .claude/settings.json.
set -u
PWSH_VER=7.4.20
SHA_X64=ed8008345c7f5337f5e293145f5e243ce132e5ee4dfc24ac551c45a4b3092181
SHA_ARM64=4d1a7b468eae627809eac5fae79c4e645cd9362fdf9f626298686b4489eb4724

have() { command -v "$1" >/dev/null 2>&1; }
bindir="$HOME/.local/bin"
dest="$HOME/.local/pwsh"
LOG="$HOME/.cache/guyb-cloud-setup.log"
mkdir -p "$HOME/.cache" 2>/dev/null || LOG=/dev/null
warn() { echo "cloud-setup: $1 not installed ($2); see $LOG" >&2; }
have_pwsh() { have pwsh || [ -x "$bindir/pwsh" ]; }

export_path() { # make a user-local pwsh visible to later Bash calls, once per env file
  [ -x "$bindir/pwsh" ] && ! have pwsh || return 0
  [ -n "${CLAUDE_ENV_FILE:-}" ] || return 0
  grep -qsF "$bindir" "$CLAUDE_ENV_FILE" || echo "export PATH=\"$bindir:\$PATH\"" >>"$CLAUDE_ENV_FILE"
}

tmp=""
trap '[ -n "$tmp" ] && rm -rf "$tmp"' EXIT

main() {
  if have_pwsh && have shellcheck; then return 0; fi
  [ "$(uname -s)" = Linux ] || return 0

  if ! have shellcheck; then
    priv=""
    if [ "$(id -u)" != 0 ]; then
      if have sudo && sudo -n true >/dev/null 2>&1; then priv="sudo -n"; else priv="none"; fi
    fi
    if [ "$priv" = none ]; then warn shellcheck "needs root or passwordless sudo"
    elif have apt-get; then
      tmo=""
      if have timeout; then tmo="timeout 60"; fi
      # shellcheck disable=SC2086 # priv and tmo are empty or fixed words
      DEBIAN_FRONTEND=noninteractive $tmo $priv apt-get install -y -qq -o DPkg::Lock::Timeout=20 shellcheck </dev/null >>"$LOG" 2>&1 || warn shellcheck "apt-get failed"
    else warn shellcheck "no apt-get"; fi
  fi

  have_pwsh && return 0
  case "$(uname -m)" in
    x86_64 | amd64) arch=x64; sha=$SHA_X64 ;;
    aarch64 | arm64) arch=arm64; sha=$SHA_ARM64 ;;
    *) warn pwsh "unsupported arch $(uname -m)"; return 0 ;;
  esac
  if ! have curl || ! have sha256sum || ! have tar; then warn pwsh "curl, sha256sum or tar missing"; return 0; fi
  tmp=$(mktemp -d 2>/dev/null) || { tmp=""; warn pwsh "mktemp failed"; return 0; }
  tgz="$tmp/pwsh.tar.gz"
  url="https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VER/powershell-$PWSH_VER-linux-$arch.tar.gz"
  if ! curl -fsSL --connect-timeout 10 --max-time 45 --retry 1 -o "$tgz" "$url" </dev/null 2>>"$LOG"; then warn pwsh "download failed"; return 0; fi
  if [ "$(sha256sum "$tgz" | cut -d' ' -f1)" != "$sha" ]; then warn pwsh "sha256 mismatch"; return 0; fi
  new="$dest.new.$$"
  old="$dest.old.$$"
  rm -rf "$new" "$old"
  if ! { mkdir -p "$new" "$bindir" && tar -xzf "$tgz" -C "$new" >>"$LOG" 2>&1 && chmod +x "$new/pwsh"; }; then
    rm -rf "$new"; warn pwsh "extract failed"; return 0
  fi
  [ -e "$dest" ] && mv "$dest" "$old"
  if mv "$new" "$dest" && ln -sf "$dest/pwsh" "$bindir/pwsh"; then rm -rf "$old"
  else
    rm -rf "$new" "$dest"; [ -e "$old" ] && mv "$old" "$dest"
    warn pwsh "install failed"; return 0
  fi
  "$bindir/pwsh" -NoProfile -Command exit >>"$LOG" 2>&1 || warn pwsh "installed but does not start (missing libicu?)"
}

main
export_path
exit 0
