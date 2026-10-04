#!/usr/bin/env bash
# guyb status line for Claude Code: prints one line "guyb > <project>  <branch>  N running  M question(s)".
# Read-only, no network, no gh, no git subprocess, ASCII only, never prompts, always exits 0.
# Location independent: Claude Code runs it from settings.json (setup copies it to ~/.claude/guyb/).
# Reads the session JSON on stdin (workspace.current_dir, then cwd, then $PWD); stdin read is capped and times out.
# Registry: <root>/.claude/guyb/pipeline/{runs,questions}.md, else the legacy .claude/pipeline/ copy when
# the legacy .claude/STATE.md is guyb-owned. Typical runtime: tens of ms (a few forks, no git).
# PowerShell twin: guyb-status.ps1 (keep the rules in sync). Targets bash 3.2.
exec 2>/dev/null
export LC_ALL=C

json=
if [ ! -t 0 ]; then IFS= read -r -t 2 -n 65536 -d '' json; fi
json=${json#$'\xef\xbb\xbf'}

jget() { # key: sets v to the string value of the first "key": "..." in $json
  v=
  local rest
  case $json in *\""$1"\"*) rest=${json#*\""$1"\"} ;; *) return 1 ;; esac
  case $rest in *:*) rest=${rest#*:} ;; *) return 1 ;; esac
  rest=${rest#"${rest%%[![:space:]]*}"}
  case $rest in \"*) rest=${rest#\"} ;; *) return 1 ;; esac
  v=${rest%%\"*}
  case $v in *\\*) v=$(printf %s "$v" | sed 's/\\\\/\\/g; s/\\\//\//g') ;; esac
  [ -n "$v" ]
}

tounix() { # path: sets u; a Windows-style drive path is converted when a converter exists
  u=$1
  case $1 in
    [A-Za-z]:[\\/]*|[A-Za-z]:)
      if command -v cygpath >/dev/null; then u=$(cygpath -u "$1")
      elif command -v wslpath >/dev/null; then u=$(wslpath -u "$1"); fi ;;
  esac
}

dir=
for key in current_dir cwd; do
  if jget "$key"; then
    tounix "$v"
    case $u in /*) [ -d "$u" ] && { dir=$u; break; } ;; esac
  fi
done
[ -z "$dir" ] && dir=$PWD

walk() { # names...: first dir from $dir up (max 6 parents) holding any name; sets found
  found=
  local d=$dir i=0 n p
  while [ "$i" -le 6 ]; do
    for n in "$@"; do
      # ~/.claude/guyb holds user-level files (the copied scripts), not a project
      [ "$n" = .claude/guyb ] && [ "$d" = "$HOME" ] && continue
      if [ -e "$d/$n" ]; then found=$d; return 0; fi
    done
    [ "$d" = / ] && break
    p=${d%/*}
    [ -z "$p" ] && p=/
    [ "$p" = "$d" ] && break
    d=$p
    i=$((i + 1))
  done
  return 1
}

ascii() { # text: sets asc to printable ASCII only, other bytes become ? (no fork unless needed)
  asc=$1
  case $1 in *[!\ -~]*) asc=$(printf %s "$1" | tr -c ' -~' '?') ;; esac
}

root=$dir
walk .claude/guyb .git && root=$found
project=${root%/}
ascii "${project##*/}"
project=$asc
out="guyb"
[ -n "$project" ] && out="guyb > $project"

# Branch from .git/HEAD (dir, or "gitdir: <path>" file for worktrees).
branch=
if walk .git; then
  g=$found/.git
  if [ -f "$g" ]; then
    IFS= read -r line < "$g"
    line=${line%$'\r'}
    case $line in
      "gitdir: "*)
        tounix "${line#gitdir: }"
        g=$u
        case $g in /*) ;; *) g=$found/$g ;; esac ;;
      *) g= ;;
    esac
  fi
  if [ -n "$g" ] && [ -f "$g/HEAD" ]; then
    IFS= read -r head < "$g/HEAD"
    head=${head%$'\r'}
    case $head in
      "ref: refs/heads/"*) branch=${head#ref: refs/heads/} ;;
      "ref: "*) branch=${head#ref: } ;;
      ?????????*) branch=${head:0:7} ;;
    esac
    ascii "$branch"
    branch=$asc
  fi
fi

legacy_owned() { # legacy STATE.md is guyb's: marker line, or all four headings
  local s=$root/.claude/STATE.md
  [ -f "$s" ] || return 1
  awk '
    NR == 1 && substr($0, 1, 3) == sprintf("%c%c%c", 239, 187, 191) { $0 = substr($0, 4) }
    { sub(/\r$/, "") }
    $0 == "<!-- guyb:state -->" { m = 1 }
    { l = tolower($0) }
    l ~ /^#+[ \t]*next up[ \t]*$/ { a = 1 }
    l ~ /^#+[ \t]*open issues[ \t]*$/ { b = 1 }
    l ~ /^#+[ \t]*decisions[ \t]*$/ { c = 1 }
    l ~ /^#+[ \t]*recent changes[ \t]*$/ { d = 1 }
    END { exit !(m || (a && b && c && d)) }
  ' "$s"
}

legacy=
reg() { # file name: sets rpath to the registry file to read (new path first), else empty
  rpath=
  if [ -f "$root/.claude/guyb/pipeline/$1" ]; then
    rpath=$root/.claude/guyb/pipeline/$1
  elif [ -f "$root/.claude/pipeline/$1" ]; then
    [ -z "$legacy" ] && { if legacy_owned; then legacy=yes; else legacy=no; fi; }
    [ "$legacy" = yes ] && rpath=$root/.claude/pipeline/$1
  fi
}

reg runs.md; rfile=$rpath
reg questions.md; qfile=$rpath
running=0
questions=0
if [ -n "$rfile$qfile" ]; then
  # One awk for both tables. Columns are found by header name (runs: ID, Status; questions: Q or ID, Status);
  # if the header lacks Status, fall back to the documented column (runs 7, questions 6).
  counts=$(awk -F'|' -v rf="$rfile" '
    function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    FNR == 1 {
      if (substr($0, 1, 3) == sprintf("%c%c%c", 239, 187, 191)) $0 = substr($0, 4)
      kind = (FILENAME == rf) ? "r" : "q"
      seen = 0; sc = 0; ic = 0
      idn = (kind == "r") ? ",id," : ",q,id,"
      def = (kind == "r") ? 7 : 6
      want = (kind == "r") ? "running" : "open"
    }
    index($0, "|") == 0 { next }
    !seen {
      seen = 1
      for (i = 1; i <= NF; i++) {
        t = tolower(trim($i))
        if (t == "status") sc = i
        if (t != "" && index(idn, "," t ",")) ic = i
      }
      if (sc) { if (!ic) ic = 2; next }
      sc = def + 1; ic = 2
    }
    {
      id = trim($ic)
      if (id == "" || id ~ /^[-: ]+$/) next
      if (tolower(trim($sc)) == want) n[kind]++
    }
    END { print n["r"] + 0, n["q"] + 0 }
  ' ${rfile:+"$rfile"} ${qfile:+"$qfile"})
  set -- $counts
  case $1 in ''|*[!0-9]*) ;; *) running=$1 ;; esac
  case $2 in ''|*[!0-9]*) ;; *) questions=$2 ;; esac
fi

[ -n "$branch" ] && out="$out  $branch"
[ "$running" -gt 0 ] && out="$out  $running running"
if [ "$questions" -eq 1 ]; then out="$out  1 question"
elif [ "$questions" -gt 1 ]; then out="$out  $questions questions"; fi
printf '%s\n' "$out"
exit 0
