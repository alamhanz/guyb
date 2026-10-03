# guyb launcher for bash/zsh (macOS, Linux, Git Bash).
# Source from your ~/.bashrc or ~/.zshrc:   source "<repo>/scripts/launch.sh"
#
#   guyb            -> pick a project from $GUYB_ROOT (or the current folder)
#   guyb myapp      -> open <root>/myapp
#   guyb /abs/path  -> open an absolute path
# Inside tmux it opens a new tmux window per project; otherwise it runs in the current terminal.

guyb() {
  # zsh: an unmatched glob is an error by default; make it expand to nothing instead
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options null_glob
  local root="${GUYB_ROOT:-$PWD}" target=""

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
