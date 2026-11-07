# guyb launcher for bash/zsh (macOS, Linux, Git Bash).
# shellcheck shell=bash
# Source from your ~/.bashrc or ~/.zshrc:   source "<repo>/scripts/launch.sh"
#
#   guyb            -> pick a project from $GUYB_ROOT (or the current folder)
#                      GUYB_ROOT may be a path list (';' on Windows/Git Bash, ':' elsewhere); names in several roots show as "name  [root]"
#   guyb myapp      -> open <root>/myapp (name in several roots: error listing full paths; pass the full path)
#   guyb /abs/path  -> open an absolute path
#   guyb --list     -> print the projects (tab-separated, most recent first, last column = root) and return; never prompts
# Inside tmux it opens a new tmux window per project; otherwise it runs in the current terminal.
# Every launched claude gets CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 so the tab keeps the project title.

# Tabs: the project name locks the tab title (tmux window / OSC 0) and tints it from a fixed palette.
# GUYB_DRYRUN=1 prints the launch command lines (tmux: / here:) and launches nothing.

# Strip control chars (C0, DEL, and C1 U+0080-U+009F as UTF-8) from a name before it reaches a title.
_guyb_clean() {
  printf %s "$1" | LC_ALL=C tr -d '\000-\037\177' |
    LC_ALL=C sed "s/$(printf '\302')[$(printf '\200')-$(printf '\237')]//g"
}

# tmux format-expands -n/-c values (double '#') and reads an argv element ending in ';' as a command separator.
_guyb_tmux_arg() {
  local s="${1//\#/##}"
  case "$s" in *\;) s="${s%;}\\;" ;; esac
  printf '%s' "$s"
}

# Tab title: "<done icon> <name>" at launch; plugins/guyb/hooks/tab-status.sh swaps the icon as Claude works (needs GUYB_TAB_NAME).
# Icon is U+2705 built from bytes (file stays ASCII); "+" when GUYB_TAB_ASCII=1 or TERM is linux/dumb.
_guyb_title() {
  local g=$'\342\234\205'
  case "${GUYB_TAB_ASCII:-}" in 1) g=+ ;; esac
  case "${TERM:-}" in linux|dumb) g=+ ;; esac
  printf '%s %s' "$g" "$1"
}

# Tab colour: djb2 (32-bit) over the UTF-8 bytes of the name, mod 8, fixed palette. Same result in launch.ps1.
_guyb_color() {
  local h=5381 b bytes
  bytes="$(printf %s "$1" | LC_ALL=C od -An -v -tu1 | tr -s ' ' '\n')"
  while read -r b; do
    [ -n "$b" ] || continue
    h=$(( (h * 33 + b) % 4294967296 ))
  done <<EOF2
$bytes
EOF2
  case $(( h % 8 )) in
    0) echo '#E06C75' ;; 1) echo '#E5A445' ;; 2) echo '#98C379' ;; 3) echo '#56B6C2' ;;
    4) echo '#61AFEF' ;; 5) echo '#C678DD' ;; 6) echo '#D19A66' ;; *) echo '#4DB6AC' ;;
  esac
}

# Set a window option on one tmux window (never -g), or print the command under GUYB_DRYRUN.
_guyb_tmux_opt() {
  if [ -n "${GUYB_DRYRUN:-}" ]; then printf 'tmux: set-window-option -t %s %s %s\n' "$1" "$2" "$3"
  else tmux set-window-option -t "$1" "$2" "$3" >/dev/null 2>&1; fi
}

# Roots: $GUYB_ROOT is a path list (';' on Windows incl. Git Bash, ':' elsewhere), else $PWD. Entries: trimmed, one pair of quotes
# removed, empties dropped, duplicates dropped. Missing entries warn ("guyb: root not found: <entry>") and are skipped.
# Prints the existing roots, one per line, normalized with `cd && pwd`.
_guyb_roots() {
  local rest="${GUYB_ROOT:-$PWD}" sep=: e n k seen="" nl="
" more=1
  case "${OSTYPE:-}" in msys*|cygwin*|win32*) sep=';' ;; esac
  while [ -n "$more" ]; do
    case "$rest" in
      *"$sep"*) e="${rest%%"$sep"*}"; rest="${rest#*"$sep"}" ;;
      *) e="$rest"; more="" ;;
    esac
    e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"
    case "$e" in \"?*\") e="${e#\"}"; e="${e%\"}" ;; \'?*\') e="${e#\'}"; e="${e%\'}" ;; esac
    [ -n "$e" ] || continue
    [ -d "$e" ] || { echo "guyb: root not found: $e" >&2; continue; }
    n="$(cd "$e" && pwd)"; k="$n"
    [ "$sep" = ';' ] && k="$(printf %s "$n" | tr 'A-Z' 'a-z')"
    case "$nl$seen$nl" in *"$nl$k$nl"*) continue ;; esac
    seen="$seen$nl$k"
    printf '%s\n' "$n"
  done
}

# Project folders of the roots ($1 = newline-separated roots), one line each: index<TAB>root<TAB>abs path.
# A folder that is itself a root or $GUYB_HOME is not a project.
_guyb_projects() {
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options null_glob
  local skip="$1" r d p h i=0 tab nl="
"
  tab="$(printf '\t')"
  if [ -n "${GUYB_HOME:-}" ] && [ -d "$GUYB_HOME" ]; then h="$(cd "$GUYB_HOME" && pwd)"; skip="$skip$nl$h"; fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    for d in "$r"/*/; do
      [ -d "$d" ] || continue
      p="$(cd "$d" && pwd)"
      case "$nl$skip$nl" in *"$nl$p$nl"*) continue ;; esac
      printf '%s%s%s%s%s\n' "$i" "$tab" "$r" "$tab" "$p"
    done
    i=$((i + 1))
  done <<EOF3
$1
EOF3
}

guyb() {
  # zsh: an unmatched glob is an error by default; make it expand to nothing instead
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options null_glob
  local roots target="" tab nl="
"
  tab="$(printf '\t')"
  roots="$(_guyb_roots)"
  if [ -z "$roots" ] && { [ "${1:-}" = "--list" ] || [ -z "${1:-}" ] || [ ! -d "$1" ]; }; then
    echo "Root not found: ${GUYB_ROOT:-$PWD}" >&2; return 1
  fi

  if [ "${1:-}" = "--list" ]; then
    # Non-interactive: one tab-separated line per project, most recent activity first:
    # name, abs path, last activity (ISO 8601 UTC), is git (y/n), dirty count, has .claude/guyb/STATE.md or legacy .claude/STATE.md (y/n), root
    local idx rt p ts ct isgit dirty state iso
    _guyb_projects "$roots" | while IFS="$tab" read -r idx rt p; do
      ts="$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null || echo 0)"
      isgit=n; dirty=0
      if command -v git >/dev/null 2>&1 && [ -e "$p/.git" ]; then
        isgit=y
        ct="$(git -C "$p" log -1 --format=%ct 2>/dev/null)"
        [ -n "$ct" ] && [ "$ct" -gt "$ts" ] && ts="$ct"
        dirty="$(git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      fi
      state=n; { [ -f "$p/.claude/guyb/STATE.md" ] || [ -f "$p/.claude/STATE.md" ]; } && state=y
      iso="$(date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$ts" +%Y-%m-%dT%H:%M:%SZ)"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "${p##*/}" "$p" "$iso" "$isgit" "$dirty" "$state" "$rt"
    done | sort -t "$tab" -k1,1nr | cut -f2-
    return 0
  fi

  if [ -z "${1:-}" ]; then
    local plist labels=() n i r p dups line sel
    # sorted by name, then root order; "name  [root]" when the name occurs in more than one root
    plist="$(_guyb_projects "$roots" | while IFS="$tab" read -r i r p; do printf '%s\t%s\t%s\n' "${p##*/}" "$i" "$r$tab$p"; done |
      LC_ALL=C sort -t "$tab" -k1,1 -k2,2n)"
    [ -n "$plist" ] || { echo "No project folders in ${roots//$nl/; }" >&2; return 1; }
    dups="$(printf '%s\n' "$plist" | cut -f1 | uniq -d)"
    local lmap=""
    while IFS="$tab" read -r n i r p; do
      case "$nl$dups$nl" in *"$nl$n$nl"*) n="$n  [$r]" ;; esac
      labels+=("$n")
      lmap="$lmap$n$tab$p$nl"
    done <<EOF4
$plist
EOF4
    PS3="Project number: "
    select sel in "${labels[@]}"; do
      [ -n "$sel" ] || continue
      while IFS="$tab" read -r line p; do
        [ "$line" = "$sel" ] && { target="$p"; break; }
      done <<EOF5
$lmap
EOF5
      break
    done
  elif [ -d "${1:-}" ]; then
    target="$(cd "${1:-}" && pwd)"
  else
    local found="" cnt=0 r c p
    while IFS= read -r r; do
      [ -d "$r/$1" ] || continue
      c="$(cd "$r/$1" && pwd)"
      case "$nl$found$nl" in *"$nl$c$nl"*) continue ;; esac
      found="${found:+$found$nl}$c"; cnt=$((cnt + 1))
    done <<EOF6
$roots
EOF6
    if [ "$cnt" -eq 0 ]; then
      if [ "$(printf '%s\n' "$roots" | wc -l | tr -d ' ')" -eq 1 ]; then echo "Project not found: $1 (root: $roots)" >&2
      else echo "Project not found: $1 (roots: ${roots//$nl/; })" >&2; fi
      return 1
    elif [ "$cnt" -gt 1 ]; then
      echo "Ambiguous project: $1 is in $cnt roots:" >&2
      printf '%s\n' "$found" >&2
      echo "Run: guyb '$(printf %s "${found%%"$nl"*}" | sed "s/'/'\\\\''/g")'" >&2
      return 1
    fi
    target="$found"
  fi
  [ -n "$target" ] || return 1

  local name clean hex title q; name="$(basename "$target")"
  clean="$(_guyb_clean "$name")"; hex="$(_guyb_color "$name")"
  title="$(_guyb_title "$clean")"
  q="'$(printf %s "$clean" | sed "s/'/'\\''/g")'"  # shell-quoted name for GUYB_TAB_NAME
  local env_off="CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1"
  # Called from inside a Claude Code session: drop its variables so the new claude starts as a normal top-level session (parity with launch.ps1).
  local drop=""
  if [ -n "${CLAUDECODE:-}" ] && [ -z "${GUYB_DRYRUN:-}" ]; then
    drop="unset NO_COLOR CLAUDECODE CLAUDE_PID $(env | sed -n 's/^\(CLAUDE_CODE_[A-Za-z0-9_]*\)=.*/\1/p' | tr '\n' ' '); "
  fi
  if [ -n "${TMUX:-}" ]; then
    local id="@dry" cmd="${drop}GUYB_TAB_NAME=$q $env_off claude /guyb:start; exec \$SHELL" tn tc
    tn="$(_guyb_tmux_arg "$title")"; tc="$(_guyb_tmux_arg "$target")"
    if [ -n "${GUYB_DRYRUN:-}" ]; then
      printf "tmux: new-window -P -F '#{window_id}' -n '%s' -c '%s' '%s'\n" "$tn" "$tc" "$cmd"
    else
      id="$(tmux new-window -P -F '#{window_id}' -n "$tn" -c "$tc" "$cmd")" || return 1
    fi
    _guyb_tmux_opt "$id" automatic-rename off
    _guyb_tmux_opt "$id" allow-rename off
    _guyb_tmux_opt "$id" window-status-style "bg=$hex,fg=#000000"
    _guyb_tmux_opt "$id" window-status-current-style "bg=$hex,fg=#000000,bold"
    [ -n "${GUYB_DRYRUN:-}" ] || echo "Opened '$clean' in a new tmux window"
  elif [ -n "${GUYB_DRYRUN:-}" ]; then
    echo "here: osc0 $title"
    echo "here: cd '$target' && GUYB_TAB_NAME=$q $env_off claude /guyb:start"
  else
    printf '\033]0;%s\007' "$title"
    (cd "$target" && { eval "$drop"; env "GUYB_TAB_NAME=$clean" "$env_off" claude /guyb:start; })
  fi
}
