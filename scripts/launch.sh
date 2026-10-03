# guyb launcher for bash/zsh (macOS, Linux, Git Bash).
# Source from your ~/.bashrc or ~/.zshrc:   source "<repo>/scripts/launch.sh"
#
#   guyb            -> pick a project from $GUYB_ROOT (or the current folder)
#   guyb myapp      -> open <root>/myapp
#   guyb /abs/path  -> open an absolute path
#   guyb --list     -> print the projects (tab-separated, most recent first) and return; never prompts
# Inside tmux it opens a new tmux window per project; otherwise it runs in the current terminal.

guyb() {
  # zsh: an unmatched glob is an error by default; make it expand to nothing instead
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options null_glob
  local root="${GUYB_ROOT:-$PWD}" target=""

  if [ "$1" = "--list" ]; then
    # Non-interactive: one tab-separated line per project, most recent activity first:
    # name, abs path, last activity (ISO 8601 UTC), is git (y/n), dirty count, has .claude/STATE.md (y/n)
    [ -d "$root" ] || { echo "Root not found: $root" >&2; return 1; }
    local d p ts ct isgit dirty state iso
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      p="$(cd "$d" && pwd)"
      ts="$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null || echo 0)"
      isgit=n; dirty=0
      if command -v git >/dev/null 2>&1 && [ -e "$p/.git" ]; then
        isgit=y
        ct="$(git -C "$p" log -1 --format=%ct 2>/dev/null)"
        [ -n "$ct" ] && [ "$ct" -gt "$ts" ] && ts="$ct"
        dirty="$(git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      fi
      state=n; [ -f "$p/.claude/STATE.md" ] && state=y
      iso="$(date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$ts" +%Y-%m-%dT%H:%M:%SZ)"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "${p##*/}" "$p" "$iso" "$isgit" "$dirty" "$state"
    done | sort -t "$(printf '\t')" -k1,1nr | cut -f2-
    return 0
  fi

  if [ -z "$1" ]; then
    local dirs=() d
    for d in "$root"/*/; do [ -d "$d" ] && dirs+=("${d%/}"); done
    [ ${#dirs[@]} -eq 0 ] && { echo "No project folders in $root" >&2; return 1; }
    PS3="Project number: "
    select d in "${dirs[@]##*/}"; do [ -n "$d" ] && target="$root/$d" && break; done
  elif [ -d "$1" ]; then
    target="$(cd "$1" && pwd)"
  elif [ -d "$root/$1" ]; then
    target="$(cd "$root/$1" && pwd)"
  else
    echo "Project not found: $1 (root: $root)" >&2; return 1
  fi

  local name; name="$(basename "$target")"
  if [ -n "$TMUX" ]; then
    tmux new-window -n "$name" -c "$target" "claude /guyb:start; exec \$SHELL"
    echo "Opened '$name' in a new tmux window"
  else
    (cd "$target" && claude /guyb:start)
  fi
}
