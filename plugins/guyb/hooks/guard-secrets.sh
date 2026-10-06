#!/usr/bin/env bash
# guyb PreToolUse guard: block `git commit` when secret-looking files would be committed.
# PowerShell twin: guard-secrets.ps1 (keep the patterns and the commit-argument rules in both files in sync).
# Exit 2 blocks the tool call and feeds stderr back to Claude; any other exit lets it run.
#
# Reads the hook JSON on stdin (.tool_input.command, .cwd), finds every `git commit` in the command
# (git -C/-c options, chained commands, cd/pushd), works out the repo being committed, and checks the
# index; when the commit stages tracked files itself (-a, -i, -o, pathspecs) it also checks modified
# tracked files. When the same command runs `git add`/`git stage` first, it also checks untracked
# (not ignored) files and the add paths (so `git add -f .env` is seen). Deleted files never block.
# The shell parse is an approximation (no subshell scoping, no variable expansion, wrappers such as
# env/sudo/time/if/then are skipped). If the parser finds no commit but the text still names git and
# commit (backticks in quotes, aliases, bash -c "..."), it scans the cwd repo instead of allowing.
# Fail-open choice: when git cannot read any repo (target and cwd both fail), allow, since the commit
# would fail too; a git failure on the computed target is retried against the cwd first.

input=
[ -t 0 ] || IFS= read -r -d '' input
case "$input" in *commit*) ;; *) [ -n "$input" ] && exit 0 ;; esac

secret='(^|/)(\.env(\.[^/]*)?|\.envrc|\.netrc|\.npmrc|\.pypirc|[^/]*\.(pem|key|p12|p8|pfx|jks|keystore|kdbx|tfvars|tfvars\.json)|id_(rsa|ed25519|ecdsa|dsa)[^/]*|\.git-credentials|\.pgpass|\.htpasswd|[^/]*\.ppk|credentials(\.[^/]*)?|[^/]*service[-_]?account[^/]*\.json)$'
safe='\.(example|sample|template|pub|md)$'

gitargs=()
fall_all=0; fall_add=0

# scan <all> <add> [paths]: print secret-looking paths for the repo selected by gitargs; return 1 when git
# fails. all=1 adds modified tracked files, add=1 adds untracked files; paths are newline-separated names.
scan() {
  local files wt
  files=$(git "${gitargs[@]}" -c core.quotepath=off diff --cached --name-only --diff-filter=ACMRT 2>/dev/null) || return 1
  if [ "$1" = 1 ]; then
    wt=$(git "${gitargs[@]}" -c core.quotepath=off diff --name-only --diff-filter=ACMRT 2>/dev/null) || return 1
    files=$(printf '%s\n%s\n' "$files" "$wt")
  fi
  if [ "$2" = 1 ]; then
    wt=$(git "${gitargs[@]}" -c core.quotepath=off ls-files --others --exclude-standard --full-name -- :/ 2>/dev/null) || return 1
    files=$(printf '%s\n%s\n' "$files" "$wt")
  fi
  [ -n "$3" ] && files=$(printf '%s\n%s\n' "$files" "$(printf '%s\n' "$3" | tr '\\' '/')")
  printf '%s\n' "$files" | sort -u | grep -iE "$secret" | grep -viE "$safe"
  return 0
}

block() { # <where-suffix> <files>
  {
    echo "guyb: blocked git commit - secret-looking files would be committed$1:"
    printf '%s\n' "$2" | sed 's/^/  /'
    echo "Unstage them (git restore --staged <file>), add them to .gitignore, and commit again."
    echo "If a file is definitely not a secret, ask the user to confirm, then commit it manually."
  } >&2
  exit 2
}

fallback() {
  local bad
  bad=$(scan "$fall_all" "$fall_add") || { gitargs=(); bad=$(scan "$fall_all" "$fall_add") || exit 0; }
  [ -n "$bad" ] && block "" "$bad"
  exit 0
}

[ -z "$input" ] && fallback

cmd=; cwd=
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
else
  # JSON string escapes decoded by awk: \\ \" \n \t \/ ; anything else (\uXXXX) is left as is.
  dec='{ s = $0; o = ""; n = length(s)
    for (i = 1; i <= n; i++) { c = substr(s, i, 1)
      if (c == "\\" && i < n) { x = substr(s, i + 1, 1)
        if (x == "n") { o = o "\n"; i++ } else if (x == "t") { o = o "\t"; i++ }
        else if (x == "\\" || x == "\"" || x == "/") { o = o x; i++ } else o = o c
      } else o = o c }
    print o }'
  cmd=$(printf '%s' "$input" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n 1 | awk "$dec" 2>/dev/null)
  cwd=$(printf '%s' "$input" | sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n 1 | awk "$dec" 2>/dev/null)
fi
[ -z "$cmd" ] && fallback

base=.
if [ -n "$cwd" ]; then
  if [ -d "$cwd" ]; then base=$cwd
  elif command -v cygpath >/dev/null 2>&1 && u=$(cygpath -u "$cwd" 2>/dev/null) && [ -d "$u" ]; then base=$u
  fi
fi
[ "$base" != . ] && gitargs=(-C "$base")

# Loose text checks, used when the parser finds no commit: does it look like a commit that stages or uses -a?
flat=$(printf '%s' "$cmd" | tr '\n\r' '  ')
if printf '%s' "$flat" | grep -qiE '(^|[^[:alnum:]_-])(add|stage)([^[:alnum:]_-]|$)'; then fall_add=1; fall_all=1; fi
if printf '%s' "$flat" | grep -qiE 'commit.*[[:space:]](-[A-Za-z]*[aio][A-Za-z]*|--all|--include|--only)([[:space:]]|$)'; then fall_all=1; fi

# One line per git commit invocation: <all>\t<unknown>\t<add>\t_<chain>\t_<addpaths>
# chain = C:<dir> (cd / -C), G:<dir> (--git-dir), W:<dir> (--work-tree) joined by \037; add = 1 when a
# git add/stage ran earlier in the command, addpaths = its non-option words.
prog='
function dirunk(s) { return (index(s, "$") > 0 || index(s, "`") > 0) }
function isgit(s) { s = tolower(s); return (s == "git" || s == "git.exe" || s ~ /(\/|\\)git(\.exe)?$/) }
function iskw(s) { return (s ~ /^(if|elif|while|until|then|do|else|time|env|command|exec|nohup|sudo|nice|builtin|!|\{)$/) }
function endword() {
  if (!inw) return
  inw = 0
  if (skipnext) { skipnext = 0; cur = ""; return }
  if (cur ~ /^[0-9]*[<>]/) {
    if (cur ~ /^[0-9]*>>?$/ || cur ~ /^[0-9]*<$/) skipnext = 1
    cur = ""; return
  }
  nw++; w[nw] = cur; cur = ""
}
function addgd(t, v) { if (dirunk(v)) return 1; ng++; gd[ng] = t v; return 0 }
function endseg(   i, k, f, d, a, j, ch, q, L, all, u, afterdd, nm, e) {
  endword()
  if (nw == 0) return
  i = 1
  while (i <= nw) {
    if (w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
    else if (iskw(w[i])) { i++; while (i <= nw && substr(w[i], 1, 1) == "-" && w[i] != "-") i++ }
    else break
  }
  if (i > nw) { nw = 0; return }
  f = w[i]
  if (f == "cd" || f == "pushd") {
    d = ""
    for (k = i + 1; k <= nw; k++) if (substr(w[k], 1, 1) != "-" || w[k] == "-") { d = w[k]; break }
    if (d == "" || d == "~") d = home
    else if (substr(d, 1, 2) == "~/") d = home substr(d, 2)
    if (d == "" || d == "-" || dirunk(d)) gunk = 1
    else { nd++; dirs[nd] = d }
  } else if (isgit(f)) {
    ng = nd
    for (k = 1; k <= nd; k++) gd[k] = "C:" dirs[k]
    u = gunk
    k = i + 1
    while (k <= nw) {
      a = w[k]
      if (a == "-C" || a == "--git-dir" || a == "--work-tree") {
        d = (a == "-C") ? "C:" : ((a == "--git-dir") ? "G:" : "W:")
        k++
        if (k <= nw && addgd(d, w[k])) u = 1
        k++
      } else if (a ~ /^--(git-dir|work-tree)=/) {
        if (addgd((a ~ /^--git/) ? "G:" : "W:", substr(a, index(a, "=") + 1))) u = 1
        k++
      } else if (a == "-c" || a == "--namespace" || a == "--super-prefix" || a == "--config-env") k += 2
      else if (substr(a, 1, 1) == "-") k++
      else break
    }
    if (k <= nw && (w[k] == "add" || w[k] == "stage")) {
      gadd = 1
      for (j = k + 1; j <= nw; j++) if (substr(w[j], 1, 1) != "-") addp = addp (addp == "" ? "" : "\037") w[j]
    }
    if (k <= nw && w[k] == "commit") {
      all = 0; afterdd = 0
      for (j = k + 1; j <= nw; j++) {
        a = w[j]
        if (afterdd) { all = 1; continue }
        if (a == "--") { afterdd = 1; continue }
        if (substr(a, 1, 2) == "--") {
          if (a == "--all" || a == "--include" || a == "--only") all = 1
          else if (index(a, "=") == 0 && (a == "--message" || a == "--file" || a == "--reuse-message" || a == "--reedit-message" || a == "--template" || a == "--author" || a == "--date" || a == "--fixup" || a == "--squash" || a == "--cleanup" || a == "--trailer" || a == "--pathspec-from-file")) j++
        } else if (substr(a, 1, 1) == "-" && length(a) > 1) {
          L = length(a)
          for (q = 2; q <= L; q++) {
            ch = substr(a, q, 1)
            if (ch == "a" || ch == "i" || ch == "o") all = 1
            if (index("mFCctuS", ch) > 0) { if (q == L && index("mFCct", ch) > 0) j++; break }
          }
        } else all = 1
      }
      e = ""
      for (k = 1; k <= ng; k++) e = e (k > 1 ? "\037" : "") gd[k]
      printf "%d\t%d\t%d\t_%s\t_%s\n", all, u, gadd, e, addp
    }
  }
  nw = 0
}
{ buf = (NR > 1) ? buf "\n" $0 : $0 }
END {
  home = ENVIRON["HOME"]
  sq = "\047"; dq = "\""
  n = length(buf); state = 0; cur = ""; inw = 0
  for (p = 1; p <= n; p++) {
    c = substr(buf, p, 1)
    if (state == 1) { if (c == sq) state = 0; else cur = cur (c == "\n" ? " " : c); continue }
    if (state == 2) {
      if (c == dq) state = 0
      else if (c == "\\") {
        nx = substr(buf, p + 1, 1)
        if (nx == dq || nx == "\\" || nx == "$" || nx == "`") { cur = cur nx; p++ } else cur = cur c
      } else cur = cur (c == "\n" ? " " : c)
      continue
    }
    if (c == sq) { state = 1; inw = 1 }
    else if (c == dq) { state = 2; inw = 1 }
    else if (c == "\\") { nx = substr(buf, p + 1, 1); p++; if (nx != "\n") { cur = cur nx; inw = 1 } }
    else if (c == " " || c == "\t" || c == "\r") endword()
    else if (c == "\n" || c == ";" || c == "|" || c == "&" || c == "(" || c == ")" || c == "`") endseg()
    else { cur = cur c; inw = 1 }
  }
  endseg()
}'
lines=$(printf '%s\n' "$cmd" | awk "$prog" 2>/dev/null) || fallback
if [ -z "$lines" ]; then
  # Parser found no commit: if the text still looks like one, scan the cwd repo rather than allow.
  printf '%s' "$flat" | grep -qiE 'git(\.exe)?["'"'"']?[[:space:]].*(commit|alias\.)' && fallback
  exit 0
fi

while IFS= read -r line; do
  all=0; unk=0; add=0; chain=; addp=; dirs=()
  IFS=$'\t' read -r all unk add chain addp <<< "$line"
  chain=${chain#_}; addp=${addp#_}
  if [ "$unk" = 1 ]; then
    dirs=()
  else
    IFS=$'\037' read -r -a dirs <<< "$chain"
  fi
  addp=$(printf '%s' "$addp" | tr '\037' '\n')
  [ "$add" = 1 ] && all=1
  gitargs=(-C "$base")
  for d in "${dirs[@]}"; do
    case "$d" in
      G:*) gitargs=("${gitargs[@]}" "--git-dir=${d#G:}") ;;
      W:*) gitargs=("${gitargs[@]}" "--work-tree=${d#W:}") ;;
      *) gitargs=("${gitargs[@]}" -C "${d#C:}") ;;
    esac
  done
  bad=$(scan "$all" "$add" "$addp") || { gitargs=(-C "$base"); bad=$(scan "$all" "$add" "$addp") || continue; }
  if [ -n "$bad" ]; then
    where=
    if [ "$base" != . ] || [ "${#dirs[@]}" -gt 0 ]; then
      top=$(git "${gitargs[@]}" rev-parse --show-toplevel 2>/dev/null)
      [ -n "$top" ] && where=" ($top)"
    fi
    block "$where" "$bad"
  fi
done <<< "$lines"
exit 0
