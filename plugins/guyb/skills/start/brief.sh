#!/usr/bin/env bash
# Read-only session briefing for /guyb:start. No prompts, no cd, no secrets. Usage: brief.sh [project folder]
dir="${1:-$PWD}"
dir="${dir%/}"
[ -n "$dir" ] || dir=/
base="${dir%/}" # no trailing slash: "/" gives /x, never //x (a UNC path on msys)
export GIT_TERMINAL_PROMPT=0

# timeout binary (stock macOS has none; callers then poll and kill)
etmo=
command -v timeout >/dev/null 2>&1 && etmo=timeout
[ -z "$etmo" ] && command -v gtimeout >/dev/null 2>&1 && etmo=gtimeout
# gh capped at s seconds, run in $dir, exit 124 on timeout
ghb() { # secs args...
  gs=$1; shift
  if [ -n "$etmo" ]; then (cd "$dir" 2>/dev/null && exec "$etmo" "$gs" gh "$@") 2>/dev/null </dev/null; return $?; fi
  gf=$(mktemp "${TMPDIR:-/tmp}/guyb-gh.XXXXXX" 2>/dev/null) || return 1
  (cd "$dir" 2>/dev/null && exec gh "$@") >"$gf" 2>/dev/null </dev/null &
  gp=$!; gend=$((SECONDS + gs + 1))
  while kill -0 "$gp" 2>/dev/null && [ "$SECONDS" -lt "$gend" ]; do sleep 0.1; done
  if kill -0 "$gp" 2>/dev/null; then
    command -v pkill >/dev/null 2>&1 && pkill -P "$gp" 2>/dev/null
    kill "$gp" 2>/dev/null; wait "$gp" 2>/dev/null; rm -f "$gf"; return 124
  fi
  wait "$gp"; grc=$?; cat "$gf"; rm -f "$gf"; return $grc
}
# One gh call lists the recent PRs (open PRs and drift states); it runs in the background under a 5s budget.
ghf=""; ghp=""; ghspent=0; ghrc=""; ghlist=""
gh_start() {
  [ -z "$ghp" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  ghf=$(mktemp "${TMPDIR:-/tmp}/guyb-gh.XXXXXX" 2>/dev/null) || { ghf=""; return 0; }
  ghb 5 pr list --state all --limit 100 --json number,state,title,headRefName -q '.[] | [.number,.state,.title,.headRefName] | @tsv' >"$ghf" &
  ghp=$!
}
gh_collect() {
  [ -n "$ghp" ] || return 0
  ghw=$SECONDS
  wait "$ghp" 2>/dev/null; ghrc=$?
  ghspent=$((SECONDS - ghw))
  ghlist=""; read -r -d '' ghlist < "$ghf"; ghlist=${ghlist//$'\r'/}
  rm -f "$ghf"; ghf=""; ghp=""
}
gh_clean() { [ -n "$ghp" ] && kill "$ghp" 2>/dev/null; [ -n "$ghf" ] && rm -f "$ghf"; return 0; }
trap gh_clean EXIT
trap 'exit 1' HUP INT TERM
[ -e "$base/.git" ] && gh_start

pn=${dir##*/}; [ -n "$pn" ] || pn=/
echo "project: $pn"

# max_parallel and the four cleanup limits in one pass: first file (project, then profile) with a valid value wins per key.
# Prints "<max_parallel> <src> <claude_md_lines> <state_lines> <rows> <days>"; "-" when unset.
cfgf=()
[ -f "$base/.claude/CLAUDE.md" ] && cfgf[${#cfgf[@]}]="$base/.claude/CLAUDE.md"
[ -f "$HOME/.claude/guyb/profile.md" ] && cfgf[${#cfgf[@]}]="$HOME/.claude/guyb/profile.md"
cfgout="- - - - - -"
if [ ${#cfgf[@]} -gt 0 ]; then
  cfgout=$(awk -v proj="$base/.claude/CLAUDE.md" '
    BEGIN { split("max_parallel cleanup_claude_md_lines cleanup_state_lines cleanup_rows cleanup_days", ks, " "); for (i = 1; i <= 5; i++) { ix[ks[i]] = i; v[i] = "-" } }
    {
      s = $0; sub(/^[ \t]*/, "", s); sub(/^[-*][ \t]+/, "", s); sub(/^[`*]*/, "", s)
      if (!match(s, /^[a-z_]+/)) next
      k = substr(s, 1, RLENGTH); if (!(k in ix)) next
      s = substr(s, RLENGTH + 1)
      if (s !~ /^[`*]*[ \t]*:[`* \t\r]*[0-9]+[`* \t\r]*$/) next
      d = s; gsub(/[^0-9]/, "", d); sub(/^0+/, "", d)
      if (d == "" || length(d) > (k == "max_parallel" ? 2 : 9)) next
      n = d + 0; if (n < 1 || (k == "max_parallel" && n > 20)) next
      i = ix[k]; if (v[i] == "-") { v[i] = n; if (i == 1) src = (FILENAME == proj) ? "project" : "profile" }
    }
    END { print v[1], (src == "" ? "-" : src), v[2], v[3], v[4], v[5] }' "${cfgf[@]}")
fi
# shellcheck disable=SC2086 # six words, splitting is intended
set -- $cfgout
max_parallel=5; max_src=default
[ "$1" != "-" ] && { max_parallel=$1; max_src=$2; }
lim_claude=200; lim_state=300; lim_rows=200; lim_days=14
[ "$3" != "-" ] && lim_claude=$3
[ "$4" != "-" ] && lim_state=$4
[ "$5" != "-" ] && lim_rows=$5
[ "$6" != "-" ] && lim_days=$6
echo "max parallel: $max_parallel ($max_src)"

# Per-project files live in .claude/guyb/; legacy .claude/STATE.md and .claude/pipeline/ are read as a fallback (never written).
# A legacy STATE.md counts as guyb's only with the marker line or the four headings Next up, Open issues, Decisions, Recent changes.
state_new="$base/.claude/guyb/STATE.md"; state_old="$base/.claude/STATE.md"
pipe_new="$base/.claude/guyb/pipeline"; pipe_old="$base/.claude/pipeline"
old_owned=0
if [ -f "$state_old" ] && tr -d '\r' < "$state_old" | LC_ALL=C awk '
  BEGIN { bom = sprintf("%c%c%c", 239, 187, 191) }
  NR == 1 && substr($0, 1, 3) == bom { $0 = substr($0, 4) }
  $0 == "<!-- guyb:state -->" { m = 1 }
  match($0, /^#+[ \t]+/) {
    t = tolower(substr($0, RLENGTH + 1)); gsub(/[ \t]+$/, "", t)
    if (t == "next up") h1 = 1; else if (t == "open issues") h2 = 1; else if (t == "decisions") h3 = 1; else if (t == "recent changes") h4 = 1
  }
  END { exit !(m || (h1 && h2 && h3 && h4)) }'; then old_owned=1; fi
state=""
if [ -f "$state_new" ]; then state="$state_new"; elif [ "$old_owned" = 1 ]; then state="$state_old"; fi
pipe=""
if [ -d "$pipe_new" ]; then pipe="$pipe_new"; elif [ -d "$pipe_old" ]; then pipe="$pipe_old"; fi

mvl=""; cfl=""
if [ "$old_owned" = 1 ]; then
  if [ -f "$state_new" ]; then cfl=".claude/STATE.md and .claude/guyb/STATE.md both exist"; else mvl=".claude/STATE.md"; fi
fi
if [ -d "$pipe_old" ]; then
  if [ -d "$pipe_new" ]; then cfl="${cfl:+$cfl; conflict: }.claude/pipeline/ and .claude/guyb/pipeline/ both exist"; else mvl="${mvl:+$mvl, }.claude/pipeline/"; fi
fi
mg=""
[ -n "$mvl" ] && mg="move $mvl to .claude/guyb/"
[ -n "$cfl" ] && mg="${mg:+$mg; }conflict: $cfl"
[ -n "$mg" ] && echo "migrate: $mg"

# Outdated plugin flag: installed guyb@guyb vs the local marketplace source. Silent on any gap.
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
inst_f="$cfg/plugins/installed_plugins.json"
mk_f="$cfg/plugins/known_marketplaces.json"
if [ -f "$inst_f" ] && [ -f "$mk_f" ]; then
  if command -v jq >/dev/null 2>&1; then
    inst=$(jq -r '.plugins["guyb@guyb"][0].version // empty' "$inst_f" 2>/dev/null); inst=${inst//$'\r'/}
    srcdir=$(jq -r '.guyb.source.path // empty' "$mk_f" 2>/dev/null); srcdir=${srcdir//$'\r'/}
  else
    inst=$(tr -d '\r' < "$inst_f" | awk '
      !f { i = index($0, "\"guyb@guyb\""); if (i) { f = 1; $0 = substr($0, i) } }
      f && match($0, /"version"[ \t]*:[ \t]*"[^"]*"/) {
        v = substr($0, RSTART, RLENGTH); sub(/^"version"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v); print v; exit
      }')
    srcdir=$(tr -d '\r' < "$mk_f" | awk '
      !f && match($0, /"guyb"[ \t]*:/) { f = 1; $0 = substr($0, RSTART + RLENGTH) }
      f {
        e = index($0, "\"installLocation\""); if (e) { t = substr($0, 1, e - 1) } else { t = $0 }
        if (match(t, /"path"[ \t]*:[ \t]*"([^"\\]|\\.)*"/)) {
          v = substr(t, RSTART, RLENGTH); sub(/^"path"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v); print v; exit
        }
        if (e || index($0, "\"lastUpdated\"")) exit
      }')
  fi
  case "$srcdir" in *\\*) srcdir=${srcdir//\\\\/\\} ;; esac
  case "$srcdir" in
    [A-Za-z]:[\\/]*)
      if command -v cygpath >/dev/null 2>&1; then srcdir=$(cygpath -u "$srcdir" 2>/dev/null)
      elif command -v wslpath >/dev/null 2>&1; then srcdir=$(wslpath -u "$srcdir" 2>/dev/null); fi ;;
  esac
  pj="$srcdir/plugins/guyb/.claude-plugin/plugin.json"
  if [ -n "$inst" ] && [ -n "$srcdir" ] && [ -f "$pj" ]; then
    if command -v jq >/dev/null 2>&1; then
      avail=$(jq -r '.version // empty' "$pj" 2>/dev/null); avail=${avail//$'\r'/}
    else
      avail=$(tr -d '\r' < "$pj" | awk 'match($0, /"version"[ \t]*:[ \t]*"[^"]*"/) {
        v = substr($0, RSTART, RLENGTH); sub(/^"version"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v); print v; exit }')
    fi
    behind=$(awk -v a="$inst" -v b="$avail" 'BEGIN {
      sub(/[-+].*$/, "", a); sub(/[-+].*$/, "", b)
      if (a !~ /^[0-9]+(\.[0-9]+)*$/ || b !~ /^[0-9]+(\.[0-9]+)*$/) exit
      na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb) ? na : nb
      for (i = 1; i <= n; i++) {
        if (x[i] + 0 < y[i] + 0) { print 1; exit }
        if (x[i] + 0 > y[i] + 0) exit
      }
    }')
    [ "$behind" = "1" ] && echo "plugin: $inst installed, $avail available - run: claude plugin marketplace update guyb; claude plugin update guyb@guyb"
  fi
fi

isgit=0
if [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if ab=$(git -C "$dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
    set -- $ab
    sync="ahead $2, behind $1"
  else
    sync="no upstream"
  fi
  isgit=1
  echo "branch: $branch ($sync)"

  dirty=$(git -C "$dir" status --short 2>/dev/null)
  n=0
  [ -n "$dirty" ] && n=$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')
  echo "uncommitted: $n file(s)"
  [ "$n" -gt 0 ] && printf '%s\n' "$dirty" | head -10 | sed 's/^/  /'
  [ "$n" -gt 10 ] && echo "  ... +$((n - 10)) more"

  if grep -qE '^/?\.claude/?[[:space:]]*$' "$base/.gitignore" 2>/dev/null; then
    echo "warn: .gitignore ignores .claude/ - guyb STATE.md will not be committed"
  elif ! grep -qE '^/?\.claude/guyb/pipeline/?[[:space:]]*$' "$base/.gitignore" 2>/dev/null &&
    ! { [ "$pipe" = "$pipe_old" ] && grep -qE '^/?\.claude/pipeline/?[[:space:]]*$' "$base/.gitignore" 2>/dev/null; }; then
    echo "gitignore: .claude/guyb/pipeline/ not ignored"
  fi

  echo "last commits:"
  git -C "$dir" log -5 --format='  %h %s' 2>/dev/null

  if command -v gh >/dev/null 2>&1; then
    gh_start; gh_collect
    prs=""; pc=0
    while IFS=$'\t' read -r pn_ ps_ pt_ pb_; do
      [ "$ps_" = OPEN ] || continue
      prs="${prs:+$prs$'\n'}  $pn_ | $pt_ | $pb_"
      pc=$((pc + 1)); [ "$pc" -ge 5 ] && break
    done <<< "$ghlist"
    if [ -n "$prs" ]; then
      echo "open PRs:"
      printf '%s\n' "$prs"
    fi
  fi
else
  echo "git: not a repository"
fi

if [ -n "$state" ]; then
  for h in "Next up" "Open issues"; do
    sec=$(awk -v h="$h" '
      { sub(/\r$/, "") }
      found && /^#/ { exit }
      found && NF { gsub(/^[ \t]+|[ \t]+$/, ""); print "  " $0; if (++c >= 5) exit }
      !found && tolower($0) ~ "^#+[ \t]*" tolower(h) { found = 1 }
    ' "$state")
    [ -n "$sec" ] && { echo "STATE.md $h:"; printf '%s\n' "$sec"; }
  done
  # Drift: PRs named in live-state sections of STATE.md (Current Status, Open Issues, Next Up, In progress, Open PRs) that are already merged or closed.
  # States come from the PR list; a PR missing from it gets one `gh pr view` (max 3, within the 5s budget; none after a timeout; silent on failure).
  if [ "$isgit" = 1 ] && command -v gh >/dev/null 2>&1 && [ "$ghrc" != 124 ]; then
    for n in $(awk '
      { gsub(/\r/, "") }
      /^#/ { l = (tolower($0) ~ /^#+[ \t]*(current status|open issues|next up|in progress|open prs)/); next }
      l { s = tolower($0)
        while (match(s, /(^|[^a-z0-9])(#|pull\/|pr[ \t]+#?)[0-9]+/)) {
          m = substr(s, RSTART, RLENGTH); sub(/^.*[^0-9]/, "", m); s = substr(s, RSTART + RLENGTH)
          if (!seen[m]++ && ++c <= 3) print m
        } }' "$state"); do
      st=""
      while IFS=$'\t' read -r pn_ ps_ _; do
        [ "$pn_" = "$n" ] && { st=$ps_; break; }
      done <<< "$ghlist"
      if [ -z "$st" ]; then
        rem=$((5 - ghspent))
        [ "$rem" -ge 1 ] || continue
        ghw=$SECONDS
        st=$(ghb "$rem" pr view "$n" --json state -q .state | tr -d '\r')
        ghspent=$((ghspent + SECONDS - ghw))
      fi
      case "$st" in MERGED|CLOSED) echo "STATE.md drift: PR #$n is $st - update STATE.md" ;; esac
    done
  fi
else
  echo "STATE.md: missing"
fi

runs="$pipe/runs.md"
if [ -n "$pipe" ] && [ -f "$runs" ]; then
  unf=$(grep -E '^\|.*\|[[:space:]]*(running|queued)[[:space:]]*\|' "$runs")
  if [ -n "$unf" ]; then
    echo "unfinished runs ($(printf '%s\n' "$unf" | wc -l | tr -d ' ')):"
    printf '%s\n' "$unf" | head -5 | sed -E 's/^\|[[:space:]]*//; s/[[:space:]]*\|[[:space:]]*/ | /g; s/ \| $//; s/^/  /'
  fi
fi

qs="$pipe/questions.md"
if [ -n "$pipe" ] && [ -f "$qs" ]; then
  open=$(grep -E '^\|[[:space:]]*Q[0-9]+.*\|[[:space:]]*open[[:space:]]*\|' "$qs")
  if [ -n "$open" ]; then
    echo "open questions ($(printf '%s\n' "$open" | wc -l | tr -d ' ')):"
    printf '%s\n' "$open" | head -5 | awk -F'|' '{ n = 0; o = ""; for (i = 1; i <= NF && n < 4; i++) { c = $i; gsub(/^[ \t\r]+|[ \t\r]+$/, "", c); if (c != "") { o = o (n ? " | " : "") c; n++ } } print "  " o }'
  fi
fi

# Cleanup hints. Limits (read above): project .claude/CLAUDE.md, then ~/.claude/guyb/profile.md, then defaults; invalid values are ignored.
# One awk pass counts lines and table rows (rows = table lines minus separator rows minus 1 header) of the four files and lists the run ids
# by registry columns (ID, Status): "all|<ids>|" then "act|<running/queued/blocked ids>|".
cl=""
rf=/dev/null; qf=/dev/null; active="|"; allids="|"
cntf=()
[ -f "$base/.claude/CLAUDE.md" ] && cntf[${#cntf[@]}]="$base/.claude/CLAUDE.md"
[ -n "$state" ] && cntf[${#cntf[@]}]="$state"
if [ -n "$pipe" ]; then
  [ -f "$pipe/runs.md" ] && { rf="$pipe/runs.md"; cntf[${#cntf[@]}]="$rf"; }
  [ -f "$pipe/questions.md" ] && { qf="$pipe/questions.md"; cntf[${#cntf[@]}]="$qf"; }
fi
if [ ${#cntf[@]} -gt 0 ]; then
  cnto=$(awk -F'|' -v cm="$base/.claude/CLAUDE.md" -v st="$state" -v rf="$rf" -v qf="$qf" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { sub(/\r$/, ""); nl[FILENAME] = FNR }
    /^\|/ && !/^\|[ \t|:-]+$/ { r[FILENAME]++ }
    FILENAME == rf {
      if (!h && /^\|/) { for (i = 2; i < NF; i++) { t = trim($i); if (t == "ID") ic = i; else if (t == "Status") sc = i } h = 1; next }
      if (h && ic && sc) { id = trim($ic); if (id == "" || id ~ /^[-:]+$/) next; al = al id "|"; if (trim($sc) ~ /^(running|queued|blocked)$/) ac = ac id "|" }
    }
    END {
      print nl[cm] + 0, nl[st] + 0, nl[rf] + 0, (r[rf] > 0 ? r[rf] - 1 : 0), nl[qf] + 0, (r[qf] > 0 ? r[qf] - 1 : 0)
      print "|" al; print "|" ac
    }' "${cntf[@]}" /dev/null)
  { read -r c_cl_n c_st_n _ c_rn_r _ c_q_r; IFS= read -r allids; IFS= read -r active; } <<< "$cnto"
  [ -f "$base/.claude/CLAUDE.md" ] && [ "$c_cl_n" -gt "$lim_claude" ] && cl="CLAUDE.md $c_cl_n lines (>$lim_claude)"
  [ -n "$state" ] && [ "$c_st_n" -gt "$lim_state" ] && cl="${cl:+$cl; }STATE.md $c_st_n lines (>$lim_state)"
  [ "$c_rn_r" -gt "$lim_rows" ] && cl="${cl:+$cl; }runs.md $c_rn_r rows (>$lim_rows)"
  [ "$c_q_r" -gt "$lim_rows" ] && cl="${cl:+$cl; }questions.md $c_q_r rows (>$lim_rows)"
fi
if [ -n "$pipe" ]; then
  fdirs=()
  for sub in progress reports plans brand; do
    [ -d "$pipe/$sub" ] && fdirs[${#fdirs[@]}]="$pipe/$sub"
  done
  stale=0
  if [ ${#fdirs[@]} -gt 0 ]; then
    stale=$(find "${fdirs[@]}" -type f -mtime +"$lim_days" 2>/dev/null | awk -v pipe="$pipe/" -v act="$active" -v all="$allids" '
      BEGIN { split("progress reports plans brand", subs, " ") }
      { br = ""
        for (i = 1; i <= 4; i++) if (index($0, pipe subs[i] "/") == 1) { br = subs[i]; break }
        if (br == "") next
        f = substr($0, length(pipe br) + 2)
        if (br == "brand" && index(f, "/")) sub(/\/.*/, "", f); else { sub(/^.*\//, "", f); sub(/\.[^.]*$/, "", f) }
        id = ""
        if (index(all, "|" f "|")) id = f; else if (match(f, /^.*-[0-9]+/)) id = substr(f, 1, RLENGTH)
        if (id != "" && index(act, "|" id "|")) next
        n++ }
      END { print n + 0 }')
  fi
  [ "$stale" -gt 0 ] && cl="${cl:+$cl; }$stale pipeline files older than $lim_days days"
fi
# overdue: unfinished runs and open questions (via their run) started more than lim_days ago; date part of Started only
od=""
[ "$rf" != /dev/null ] && od=$(awk -F'|' -v rf="$rf" -v today="$(date +%Y-%m-%d)" -v lim="$lim_days" '
  function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
  function dn(s,   y, m, d, e, yo, doy) {
    if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return -1
    y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
    if (m <= 2) y--
    e = int(y / 400); yo = y - e * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    return e * 146097 + yo * 365 + int(yo / 4) - int(yo / 100) + doy
  }
  BEGIN { t = dn(today) }
  FNR == 1 { h = 0; ic = sc = dc = rc = 0 }
  !h && /^\|/ {
    for (i = 2; i < NF; i++) { hn = trim($i); if (hn == "ID" || hn == "Q") ic = i; else if (hn == "Status") sc = i; else if (hn == "Started") dc = i; else if (hn == "Run") rc = i }
    h = 1; next
  }
  !h || !ic || !sc { next }
  { id = trim($ic) }
  FILENAME == rf {
    if (id !~ /^.+-[0-9]+[A-Za-z]*$/ || !dc) next
    rd[id] = dn(trim($dc)); s = trim($sc)
    if (s !~ /^(done|failed|stopped)$/ && rd[id] >= 0 && t - rd[id] > lim) ids[++k] = id
    next
  }
  id ~ /^Q[0-9]+$/ && rc && trim($sc) == "open" { r = trim($rc); if ((r in rd) && rd[r] >= 0 && t - rd[r] > lim) ids[++k] = id }
  END {
    if (!k) exit
    o = "overdue: "
    for (i = 1; i <= k && i <= 5; i++) o = o (i > 1 ? ", " : "") ids[i]
    if (k > 5) o = o ", +" (k - 5) " more"
    print o
  }' "$rf" "$qf")
[ -n "$od" ] && echo "$od"
[ -n "$cl" ] && echo "cleanup: $cl"

# Toolchain check: prints `env:` lines only for gaps. Runs only known tools from PATH (--version / info), never project scripts.
# 3s cap on probes; without a timeout binary (stock macOS): background to a temp file, poll, kill
evt() {
  if [ -n "$etmo" ]; then "$etmo" 3 "$@"; return; fi
  evf=$(mktemp "${TMPDIR:-/tmp}/guyb-probe.XXXXXX" 2>/dev/null) || { "$@"; return; }
  "$@" >"$evf" 2>&1 </dev/null &
  evp=$!; evend=$((SECONDS + 4))
  while kill -0 "$evp" 2>/dev/null && [ "$SECONDS" -lt "$evend" ]; do sleep 0.1; done
  if kill -0 "$evp" 2>/dev/null; then
    command -v pkill >/dev/null 2>&1 && pkill -P "$evp" 2>/dev/null
    kill "$evp" 2>/dev/null
  fi
  wait "$evp" 2>/dev/null; cat "$evf" 2>/dev/null; rm -f "$evf"
}
# daemon probe, 3s cap, exit 124 on timeout; portable (no timeout binary on stock macOS: background, poll, kill)
edprobe() {
  if [ -n "$etmo" ]; then "$etmo" 3 "$@" >/dev/null 2>&1 </dev/null; return $?; fi
  "$@" >/dev/null 2>&1 </dev/null &
  edp=$!; edend=$((SECONDS + 4))
  while kill -0 "$edp" 2>/dev/null && [ "$SECONDS" -lt "$edend" ]; do sleep 0.1; done
  if kill -0 "$edp" 2>/dev/null; then
    command -v pkill >/dev/null 2>&1 && pkill -P "$edp" 2>/dev/null
    kill "$edp" 2>/dev/null; wait "$edp" 2>/dev/null; return 124
  fi
  wait "$edp"; return $?
}
# a.b vs c.d (major.minor): prints lt, eq or gt
evcmp() { awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); if (x[1] + 0 != y[1] + 0) print (x[1] + 0 < y[1] + 0) ? "lt" : "gt"; else if (x[2] + 0 != y[2] + 0) print (x[2] + 0 < y[2] + 0) ? "lt" : "gt"; else print "eq" }'; }
# first line of a file, CR and surrounding blanks removed
efirst() { head -n1 "$1" 2>/dev/null | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# python
epy=0
for f in "$base/pyproject.toml" "$base/.python-version" "$base/uv.lock"; do [ -f "$f" ] && epy=1; done
for f in "$base"/requirements*.txt; do [ -f "$f" ] && epy=1; done
if [ "$epy" = 1 ]; then
  ew=""; esrc=""; eop=""
  if [ -f "$base/.python-version" ]; then
    l=$(efirst "$base/.python-version")
    ew=$(printf '%s' "$l" | sed -n -E 's/^v?([0-9]+\.[0-9]+).*/\1/p')
    [ -n "$ew" ] && esrc=".python-version"
  fi
  if [ -z "$ew" ] && [ -f "$base/pyproject.toml" ]; then
    l=$(tr -d '\r' < "$base/pyproject.toml" | grep -m1 -E '^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*["'"'"'][[:space:]]*(>=|==|~=)?[[:space:]]*[0-9]+\.[0-9]+')
    if [ -n "$l" ]; then
      eop=$(printf '%s' "$l" | sed -E 's/^[^"'"'"']*["'"'"'][[:space:]]*(>=|==|~=)?.*/\1/')
      ew=$(printf '%s' "$l" | grep -oE '[0-9]+\.[0-9]+' | head -n1)
      if [ -n "$eop" ]; then esrc="pyproject.toml"; else ew=""; fi
    fi
  fi
  ef=""
  for pc in python3 python; do
    command -v "$pc" >/dev/null 2>&1 || continue
    ef=$(evt "$pc" --version 2>&1 </dev/null | tr -d '\r' | sed -n 's/^Python \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n1)
    [ -n "$ef" ] && break
  done
  if [ -z "$ef" ] && command -v py >/dev/null 2>&1; then
    ef=$(evt py -3 --version 2>&1 </dev/null | tr -d '\r' | sed -n 's/^Python \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n1)
  fi
  ep=""
  if [ -z "$ef" ]; then
    if [ -n "$ew" ]; then ep="python wants $ew ($esrc), not installed"; else ep="python not installed"; fi
  elif [ -n "$ew" ]; then
    c=$(evcmp "$ef" "$ew")
    if { [ "$eop" = ">=" ] && [ "$c" = lt ]; } || { [ "$eop" != ">=" ] && [ "$c" != eq ]; }; then ep="python wants $ew ($esrc), found $ef"; fi
  fi
  if [ ! -d "$base/.venv" ] && [ ! -d "$base/venv" ]; then ep="${ep:+$ep; }python .venv missing"; fi
  [ -n "$ep" ] && echo "env: $ep"
fi

# node
if [ -f "$base/package.json" ]; then
  ew=""; esrc=""; eop=""
  for nf in .nvmrc .node-version; do
    [ -f "$base/$nf" ] || continue
    ew=$(efirst "$base/$nf" | sed -n -E 's/^v?([0-9]+).*/\1/p')
    if [ -n "$ew" ]; then esrc=$nf; break; fi
  done
  if [ -z "$ew" ]; then
    l=$(tr -d '\r' < "$base/package.json" | sed -n 's/.*"node"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    ew=$(printf '%s' "$l" | sed -n -E 's/^[[:space:]]*(>=|\^|~)?[[:space:]]*v?([0-9]+).*/\2/p')
    if [ -n "$ew" ]; then
      esrc="package.json"
      case "$(printf '%s' "$l" | sed 's/^[[:space:]]*//')" in ">="*) eop=">=" ;; esac
    fi
  fi
  em=$(tr -d '\r' < "$base/package.json" | sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([a-z]*\)@.*/\1/p' | head -n1)
  case "$em" in npm|pnpm|yarn|bun) ;; *)
    em=npm
    if [ -f "$base/pnpm-lock.yaml" ]; then em=pnpm
    elif [ -f "$base/yarn.lock" ]; then em=yarn
    elif [ -f "$base/bun.lockb" ] || [ -f "$base/bun.lock" ]; then em=bun; fi ;;
  esac
  ef=""
  command -v node >/dev/null 2>&1 && ef=$(evt node --version 2>&1 </dev/null | tr -d '\r' | sed -n 's/^v\{0,1\}\([0-9][0-9]*\).*/\1/p' | head -n1)
  eparts=""
  if [ -z "$ef" ]; then
    if [ -n "$ew" ]; then eparts="node wants $ew ($esrc), not installed"; else eparts="node not installed"; fi
  elif [ -n "$ew" ]; then
    if { [ "$eop" = ">=" ] && [ "$ef" -lt "$ew" ]; } || { [ "$eop" != ">=" ] && [ "$ef" -ne "$ew" ]; }; then eparts="node wants $ew ($esrc), found $ef"; fi
  fi
  [ -d "$base/node_modules" ] || eparts="${eparts:+$eparts; }node_modules missing ($em)"
  if ! { [ "$em" = npm ] && [ -z "$ef" ]; } && ! command -v "$em" >/dev/null 2>&1; then eparts="${eparts:+$eparts; }$em not installed"; fi
  [ -n "$eparts" ] && echo "env: $eparts"
fi

# docker / podman
elabel=""
for cf in compose.yaml compose.yml docker-compose.yml docker-compose.yaml Dockerfile; do
  [ -f "$base/$cf" ] && { elabel=$cf; break; }
done
if [ -n "$elabel" ]; then
  eb=""
  if command -v docker >/dev/null 2>&1; then eb=docker; elif command -v podman >/dev/null 2>&1; then eb=podman; fi
  if [ -z "$eb" ]; then echo "env: docker not installed ($elabel)"
  else
    if [ "$eb" = docker ]; then edprobe docker info --format '{{.ServerVersion}}'; erc=$?
    else edprobe podman info --format '{{.Version.Version}}'; erc=$?; fi
    if [ "$erc" = 124 ]; then echo "env: $eb daemon not responding ($elabel)"
    elif [ "$erc" != 0 ]; then echo "env: $eb daemon not running ($elabel)"; fi
  fi
fi
