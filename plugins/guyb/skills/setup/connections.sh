#!/usr/bin/env bash
# guyb connections status. Sourced by brief.sh, check.sh and the SessionStart hook; read-only, local files and env presence only.
# shellcheck disable=SC2034 # gc_* results are read by the scripts that source this file
# No CLI is run (command -v only), no network, no prompts. Secrets files are read only for the "expiresAt" value (aws caches);
# env var VALUES are never read. Usage (sourced): . connections.sh hook   -> prints {"systemMessage":"..."} or nothing, always exits 0.
# guyb_conn <brief|check|hook> <dir> sets: gc_cfg (six cfg words for brief.sh), gc_list ("connections: ..." or ""),
# gc_gh1 (first github name), gc_wl (lines "type<US>name<US>reason" for broken connections), gc_pcfg ("project config: ..." or "").

# One awk: cfg values (max_parallel and cleanup limits, project file first), the Connections sections of the project
# and profile, then checks that read other files only for recorded types. Paths and flags arrive in ENVIRON, not -v.
gc_awk='
function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
function dn(y, m, d,   e, yo) {
  if (m <= 2) y--
  e = int(y / 400); yo = y - e * 400
  return e * 146097 + yo * 365 + int(yo / 4) - int(yo / 100) + int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
}
function ts(s) {
  if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return -1
  return dn(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2)
}
function kvparse(rest,   n, i, t, p, a) {
  split("", kv); n = split(rest, a, /[ \t]+/)
  for (i = 1; i <= n; i++) { t = a[i]; p = index(t, "="); if (p > 1) kv[substr(t, 1, p - 1)] = substr(t, p + 1) }
}
function W(t, n, r) { print "W" US t US n US r }
function X(t, n, c, d) { print "X" US t US n US c US d }
function setvars(list, t, n,   a, k, i) {
  k = split(list, a, ",")
  for (i = 1; i <= k; i++) if (a[i] != "" && !(a[i] in ENVIRON)) W(t, n, a[i] " not set in this session")
}
function cfg(s,   k, d, n, i) {
  sub(/^[ \t]*/, "", s); sub(/^[-*][ \t]+/, "", s); sub(/^[`*]*/, "", s)
  if (!match(s, /^[a-z_]+/)) return
  k = substr(s, 1, RLENGTH); if (!(k in ix)) return
  s = substr(s, RLENGTH + 1)
  if (s !~ /^[`*]*[ \t]*:[`* \t\r]*[0-9]+[`* \t\r]*$/) return
  d = s; gsub(/[^0-9]/, "", d); sub(/^0+/, "", d)
  if (d == "" || length(d) > (k == "max_parallel" ? 2 : 9)) return
  n = d + 0; if (n < 1 || (k == "max_parallel" && n > 20)) return
  i = ix[k]; if (v[i] == "-") { v[i] = n; if (role == 1) pdef[i] = 1; if (i == 1) src = (role == 1) ? "project" : "profile" }
}
function hasuser(f, name,   l, s, ok) {
  ok = 0
  if (f == "") return 0
  while ((getline l < f) > 0) { s = trim(l); if (s == name ":" || s == "user: " name) { ok = 1; break } }
  close(f); return ok
}
function awsprof(f, name,   l, s, ok) {
  ok = 0
  if (f == "") return 0
  while ((getline l < f) > 0) {
    s = trim(l); if (substr(s, 1, 1) != "[") continue
    sub(/[ \t]*[#;].*$/, "", s)
    if (s == "[" name "]" || s == "[profile " name "]") { ok = 1; break }
  }
  close(f); return ok
}
function scanexp(f,   l, s, m, t) {
  while ((getline l < f) > 0) {
    s = l
    while (match(s, /"expiresAt"[ \t]*:[ \t]*"[^"]*"/)) {
      m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      sub(/^"expiresAt"[ \t]*:[ \t]*"/, "", m); sub(/"$/, "", m)
      t = ts(m); if (t >= 0 && (newest < 0 || t > newest)) { newest = t; newdate = substr(m, 1, 10) }
    }
  }
  close(f)
}
function infile(f, needle,   l, ok) {
  ok = 0
  if (f == "") return 0
  while ((getline l < f) > 0) if (index(l, needle)) { ok = 1; break }
  close(f); return ok
}
function mcpnames(f,   l, ins, nm) {
  if (f == "") return
  while ((getline l < f) > 0) {
    sub(/\r$/, "", l)
    if (!ins) {
      if (l ~ /^  "mcpServers"[ \t]*:/) { mshape = 1; if (l ~ /\{[ \t]*\}/ || l !~ /\{[ \t]*$/) break; ins = 1 }
      continue
    }
    if (l ~ /^  [}\]]/) break
    if (match(l, /^    "[^"]+"[ \t]*:/)) { nm = substr(l, 6); sub(/".*$/, "", nm); mnames[nm] = 1 }
  }
  close(f)
}
function expired(   n, i, f, nw, d) {
  if ("AWS_ACCESS_KEY_ID" in ENVIRON) return ""
  n = split(ENVIRON["GC_AWSCACHE"], f, "\n"); newest = -1
  for (i = 1; i <= n; i++) if (f[i] != "") scanexp(f[i])
  if (newest < 0) return ""
  nw = ENVIRON["GC_NOW"]
  if (nw == "") { "date -u +%Y-%m-%dT%H:%M:%S" | getline nw; close("date -u +%Y-%m-%dT%H:%M:%S") }
  d = ts(nw); if (d < 0 || newest >= d - 43200) return ""
  return newdate
}
BEGIN {
  US = sprintf("%c", 31)
  proj = ENVIRON["GC_PROJ"]
  split("max_parallel cleanup_claude_md_lines cleanup_state_lines cleanup_rows cleanup_days", ks, " ")
  for (i = 1; i <= 5; i++) { ix[ks[i]] = i; v[i] = "-" }
  split("github gitlab bitbucket aws gcp azure cloudflare mcp db service", kt, " ")
  for (i = 1; i <= 10; i++) known[kt[i]] = 1
}
FNR == 1 { role = (FILENAME == proj) ? 1 : 2; sec = "" }
{
  line = $0; sub(/\r$/, "", line); gsub(/[\001-\010\013-\037]/, " ", line)
  if (line ~ /^#/) {
    sec = ""
    if (line ~ /^##[ \t]+[Cc]onnections[ \t]*$/) sec = "conn"
    else if (role == 1 && line ~ /^##[ \t]+[Cc]redentials/) { sec = "cred"; hascred = 1 }
    next
  }
  if (sec == "conn" && match(line, /^[ \t]*-[ \t]+[^ \t:]+[ \t]+[^ \t:]+[ \t]*:/)) {
    t = line; sub(/^[ \t]*-[ \t]+/, "", t); p = index(t, ":")
    split(substr(t, 1, p - 1), hw, /[ \t]+/)
    n = ++cnt[role]; et[role, n] = tolower(hw[1]); en[role, n] = hw[2]; ek[role, n] = substr(t, p + 1)
  } else if (sec == "cred" && line ~ /^[ \t]*[-*][ \t]+/) {
    t = line; sub(/^[ \t]*[-*][ \t]+/, "", t); t = tolower(trim(t)); if (t !~ /^none[.]?$/) ncred++
  } else if (role == 1 && cloud == "" && match(line, /^[ \t]*[-*][ \t]+[*`]*Cloud[*`]*[ \t]*:/)) {
    cloud = substr(line, RSTART + RLENGTH); gsub(/[*`]/, "", cloud); cloud = trim(cloud); cloud = trim(substr(cloud, 1, 40))
  }
  cfg($0)
}
END {
  print "K " v[1], (src == "" ? "-" : src), v[2], v[3], v[4], v[5]
  hp = (ENVIRON["GC_HASPROF"] == "1")
  for (i = 1; i <= cnt[1]; i++) povr[et[1, i]] = 1
  m = 0
  if (hp) {
    for (i = 1; i <= cnt[2]; i++) if (!(et[2, i] in povr)) { m++; mr[m] = 2; mi[m] = i }
    for (i = 1; i <= cnt[1]; i++) { m++; mr[m] = 1; mi[m] = i }
    if (m == 0) print "L connections: not recorded in ~/.claude/guyb/profile.md"
  }
  list = ""
  for (j = 1; j <= m; j++) {
    r = mr[j]; i = mi[j]; ty = et[r, i]; nm = en[r, i]; kvparse(ek[r, i])
    d = ""
    if (r == 1) d = "project"; else if (ty == "aws") d = kv["region"]; else if (ty == "gcp") d = kv["project"]; else if (ty == "mcp") d = kv["scope"]
    list = list (j > 1 ? ", " : "") ty " " nm (d != "" ? " (" d ")" : "")
    if (!(ty in known)) continue
    if (ty == "github") {
      if (gh1 == "") gh1 = nm
      c = ("cli" in kv) ? kv["cli"] : "gh"; dep = ""
      if (c == "gh" && !("GH_TOKEN" in ENVIRON) && !("GITHUB_TOKEN" in ENVIRON) && !hasuser(ENVIRON["GC_GHHOSTS"], nm)) dep = "gh not logged in as " nm
      X(ty, nm, c, dep)
    } else if (ty == "gitlab") {
      X(ty, nm, ("cli" in kv) ? kv["cli"] : "glab", "")
    } else if (ty == "bitbucket") {
      setvars(("env" in kv) ? kv["env"] : "BITBUCKET_EMAIL,BITBUCKET_API_TOKEN", ty, nm)
    } else if (ty == "aws") {
      X(ty, nm, ("cli" in kv) ? kv["cli"] : "aws", "")
      if (!awsprof(ENVIRON["GC_AWSCFG"], nm) && !awsprof(ENVIRON["GC_AWSCRED"], nm)) W(ty, nm, "profile " nm " missing from ~/.aws/config")
      if (kv["login"] == "sso" || kv["login"] == "aws-login") { e = expired(); if (e != "") W(ty, nm, "login session likely expired (last refresh " e ")") }
    } else if (ty == "gcp") {
      dep = ""
      f = ENVIRON["GC_GCDIR"] "/configurations/config_" nm
      if ((getline l < f) < 0) dep = "configuration " nm " missing"; else if (ENVIRON["GC_GCCRED"] != "1") dep = "not logged in"
      close(f)
      X(ty, nm, ("cli" in kv) ? kv["cli"] : "gcloud", dep)
    } else if (ty == "azure") {
      dep = ""
      if (kv["subscription"] != "" && !infile(ENVIRON["GC_AZPROF"], kv["subscription"])) dep = "subscription " kv["subscription"] " not in az profile"
      X(ty, nm, ("cli" in kv) ? kv["cli"] : "az", dep)
    } else if (ty == "cloudflare") {
      if (kv["auth"] == "wrangler") X(ty, nm, ("cli" in kv) ? kv["cli"] : "wrangler", (ENVIRON["GC_WRANGLER"] == "1") ? "" : "wrangler not logged in")
      else if (kv["auth"] == "env") setvars("CLOUDFLARE_API_TOKEN", ty, nm)
    } else if (ty == "mcp") {
      if (kv["scope"] == "" || kv["scope"] == "user") {
        if (!mdone) { mcpnames(ENVIRON["GC_CLAUDEJSON"]); mdone = 1 }
        if (mshape && !(nm in mnames)) W(ty, nm, "MCP server not configured at user scope")
      }
    } else if (ty == "db" || ty == "service") {
      if ("cli" in kv) X(ty, nm, kv["cli"], "")
      if (ty == "service" && ("env" in kv)) setvars(kv["env"], ty, nm)
    }
  }
  if (list != "") print "L connections: " list
  if (gh1 != "") print "G " gh1
  if (ENVIRON["GC_ISPROJ"] == "1") {
    parts = ""
    if (cnt[1]) { s = ""; for (i = 1; i <= cnt[1]; i++) s = s (i > 1 ? ", " : "") et[1, i] " " en[1, i]; parts = "connections " s }
    if (cloud != "") parts = parts (parts != "" ? "; " : "") "cloud " cloud
    if (hascred) parts = parts (parts != "" ? "; " : "") (ncred ? "credentials " ncred " names" : "credentials none")
    if (src == "project") parts = parts (parts != "" ? "; " : "") "max_parallel " v[1]
    if (pdef[2] || pdef[3] || pdef[4] || pdef[5]) parts = parts (parts != "" ? "; " : "") "cleanup limits"
    if (ENVIRON["GC_MCPJSON"] == "1") parts = parts (parts != "" ? "; " : "") ".mcp.json"
    print "P project config: " (parts == "" ? "none - follows global (~/.claude/guyb/profile.md)" : parts)
  }
}'

guyb_conn() { # mode dir
  gc_mode=$1; gc_d=${2%/}; [ -n "$gc_d" ] || gc_d=/
  gc_cfg="- - - - - -"; gc_list=""; gc_wl=""; gc_pcfg=""; gc_gh1=""
  gc_h=${HOME//\\//}
  gc_pj="$gc_d/.claude/CLAUDE.md"; gc_pm="$gc_h/.claude/guyb/profile.md"
  gc_files=(); gc_isproj=0; gc_hasprof=0; gc_mj=0
  [ -f "$gc_pj" ] && { gc_files[${#gc_files[@]}]=$gc_pj; gc_isproj=1; }
  [ -f "$gc_pm" ] && { gc_files[${#gc_files[@]}]=$gc_pm; gc_hasprof=1; }
  [ -e "$gc_d/.git" ] && gc_isproj=1
  [ -f "$gc_d/.mcp.json" ] && gc_mj=1
  if [ ${#gc_files[@]} -eq 0 ]; then
    if [ "$gc_isproj" = 1 ]; then
      gc_pcfg="project config: none - follows global (~/.claude/guyb/profile.md)"
      [ "$gc_mj" = 1 ] && gc_pcfg="project config: .mcp.json"
    fi
    return 0
  fi
  # paths of the other tools; backslashes become slashes (awk gets them through ENVIRON, no escape processing)
  gc_cj=${CLAUDE_CONFIG_DIR:+${CLAUDE_CONFIG_DIR//\\//}/.claude.json}; gc_cj=${gc_cj:-$gc_h/.claude.json}
  gc_gh=${GH_CONFIG_DIR//\\//}
  if [ -z "$gc_gh" ]; then
    if [ -n "${APPDATA:-}" ]; then gc_gh="${APPDATA//\\//}/GitHub CLI"; else gc_gh="${XDG_CONFIG_HOME:-$gc_h/.config}/gh"; fi
  fi
  gc_gc=${CLOUDSDK_CONFIG//\\//}
  if [ -z "$gc_gc" ]; then
    if [ -n "${APPDATA:-}" ]; then gc_gc="${APPDATA//\\//}/gcloud"; else gc_gc="$gc_h/.config/gcloud"; fi
  fi
  gc_az=${AZURE_CONFIG_DIR:+${AZURE_CONFIG_DIR//\\//}}; gc_az=${gc_az:-$gc_h/.azure}
  gc_ac=${AWS_CONFIG_FILE//\\//}; gc_ac=${gc_ac:-$gc_h/.aws/config}
  gc_ar=${AWS_SHARED_CREDENTIALS_FILE//\\//}; gc_ar=${gc_ar:-$gc_h/.aws/credentials}
  gc_cc=""
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    for gc_f in "$gc_h"/.aws/login/cache/*.json "$gc_h"/.aws/sso/cache/*.json; do
      [ -f "$gc_f" ] && gc_cc="$gc_cc$gc_f"$'\n'
    done
  fi
  gc_gcc=0; [ -f "$gc_gc/credentials.db" ] && gc_gcc=1
  gc_wr=0
  gc_xdg=${XDG_CONFIG_HOME//\\//}
  for gc_f in "${gc_xdg:-$gc_h/.config}/.wrangler/config/default.toml" "$gc_h/Library/Preferences/.wrangler/config/default.toml" \
    "$gc_h/.wrangler/config/default.toml" "${APPDATA//\\//}/xdg.config/.wrangler/config/default.toml"; do
    [ -f "$gc_f" ] && { gc_wr=1; break; }
  done
  gc_now=""
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    TZ=UTC printf -v gc_now '%(%Y-%m-%dT%H:%M:%S)T' -1
  fi
  gc_out=$(GC_PROJ="$gc_pj" GC_HASPROF="$gc_hasprof" GC_ISPROJ="$gc_isproj" GC_MCPJSON="$gc_mj" GC_NOW="$gc_now" \
    GC_CLAUDEJSON="$gc_cj" GC_GHHOSTS="$gc_gh/hosts.yml" GC_AWSCFG="$gc_ac" GC_AWSCRED="$gc_ar" GC_AWSCACHE="$gc_cc" \
    GC_GCDIR="$gc_gc" GC_GCCRED="$gc_gcc" GC_AZPROF="$gc_az/azureProfile.json" GC_WRANGLER="$gc_wr" \
    awk "$gc_awk" "${gc_files[@]}" 2>/dev/null)
  gc_us=$'\037'
  while IFS= read -r gc_l; do
    case $gc_l in
      "K "*) gc_cfg=${gc_l#K } ;;
      "L "*) gc_list=${gc_l#L } ;;
      "P "*) gc_pcfg=${gc_l#P } ;;
      "G "*) gc_gh1=${gc_l#G } ;;
      W*) IFS=$gc_us read -r _ gc_t gc_n gc_r <<< "$gc_l"; gc_wl="${gc_wl:+$gc_wl$'\n'}$gc_t$gc_us$gc_n$gc_us$gc_r" ;;
      X*)
        IFS=$gc_us read -r _ gc_t gc_n gc_c gc_r <<< "$gc_l"
        if ! command -v "$gc_c" >/dev/null 2>&1; then gc_r="$gc_c not on PATH"; fi
        [ -n "$gc_r" ] && gc_wl="${gc_wl:+$gc_wl$'\n'}$gc_t$gc_us$gc_n$gc_us$gc_r" ;;
    esac
  done <<< "$gc_out"
  return 0
}

# the three line kinds, ready to print: connections, warn: connection ..., project config
guyb_conn_lines() {
  gc_lines=""
  [ -n "$gc_list" ] && gc_lines=$gc_list
  while IFS=$'\037' read -r gc_t gc_n gc_r; do
    [ -n "$gc_t" ] && gc_lines="${gc_lines:+$gc_lines$'\n'}warn: connection $gc_t $gc_n: $gc_r"
  done <<< "$gc_wl"
  [ -n "$gc_pcfg" ] && gc_lines="${gc_lines:+$gc_lines$'\n'}$gc_pcfg"
  return 0
}

guyb_conn_hook() {
  [ -f "${HOME//\\//}/.claude/guyb/profile.md" ] || return 0
  guyb_conn hook "${CLAUDE_PROJECT_DIR:-$PWD}" || return 0
  guyb_conn_lines
  [ -n "$gc_lines" ] || return 0
  gc_m=""
  while IFS= read -r gc_l; do
    gc_l=${gc_l//\\/\\\\}; gc_l=${gc_l//\"/\\\"}; gc_l=${gc_l//$'\t'/ }
    gc_m="${gc_m:+$gc_m\\n}guyb $gc_l"
  done <<< "$gc_lines"
  printf '{"systemMessage":"%s"}\n' "$gc_m"
  return 0
}

case "${1:-}" in
  hook) guyb_conn_hook 2>/dev/null ;;
esac
true
