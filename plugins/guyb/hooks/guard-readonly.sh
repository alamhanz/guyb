#!/usr/bin/env bash
# guyb PreToolUse guard: stop read-only subagents from running git write commands.
# PowerShell twin: guard-readonly.ps1 (same rules; tests/readonly-cases.tsv pins both).
#
# What it promises: defense in depth against routine and accidental git writes by read-only
# agents. The prompt rules stay the main control. It is not a sandbox: runtime substitution
# (g=git; $g add), scripts the agent writes then runs, language runtimes (python -c "subprocess..."),
# -c core.pager=/core.sshCommand= payloads and aliases defined in files the agent writes evade it.
# Hard enforcement would need OS-level isolation (read-only worktree, separate user).
#
# Fail open: exit 2 only on a positive match for a read-only guyb subagent. Missing field, parse
# trouble (unbalanced quotes or substitution), awk failure, any other agent: exit 0.
# A heredoc without its terminator is not an error (bash runs it): the body runs to the end of input.
#
# Sourced by hooks.json: use `exit`, never rely on $0. No fork happens before the agent check.
# The command is tokenized by one awk (quotes, separators, heredocs, substitutions, wrappers,
# bash -c / eval / find -exec runners). Unknown git verbs are looked up as aliases (git config --get).
# Known gaps (skipped to stay small): $'...' escapes (\x61) are not decoded, env -S,
# GNU parallel, arithmetic like $((1<<2)) (reads as a heredoc, so later lines are taken as its body).
#
# Verified hook stdin (Claude Code 2.1.288): PreToolUse JSON for a call made inside a subagent
# carries "agent_id" and "agent_type". Plugin agents report "agent_type":"guyb:<name>"
# (accept the bare name too). Main-session calls carry neither field.

IFS= read -r -d '' input
_gro_re='"agent_type"[[:space:]]*:[[:space:]]*"(guyb:)?(code-reviewer|architect|data-modeler|data-analyst|session-tracker|brand-designer)"'
[[ $input =~ $_gro_re ]] || exit 0
_gro_agent=${BASH_REMATCH[2]}

# Reads hook JSON (or, with GUYB_MODE=cmd, a bare command) on stdin; GUYB_CWD gives the default dir.
# Prints BLOCK, or lines ALIAS<US>verb<US>dir<US>quoted args, or nothing.
_gro_awk() {
  awk '
function base(t,   p) {
  t = tolower(t)
  while ((p = index(t, "/")) > 0) t = substr(t, p + 1)
  while ((p = index(t, "\\")) > 0) t = substr(t, p + 1)
  if (length(t) > 4 && substr(t, length(t) - 3) == ".exe") t = substr(t, 1, length(t) - 4)
  return t
}
function inset(v, set) { return v != "" && index(set, "|" v "|") > 0 }
function quote(a,   o, p) {
  gsub(/\n/, " ", a)
  o = ""
  while ((p = index(a, "\047")) > 0) { o = o substr(a, 1, p - 1) "\047\\\047\047"; a = substr(a, p + 1) }
  return "\047" o a "\047"
}
function jget(key,   s, k, n, i, p, c, out, lit, m) {
  if (!match(raw, "\"" key "\"[ \t\r\n]*:[ \t\r\n]*\"")) return ""
  s = substr(raw, RSTART + RLENGTH)
  if (!match(s, /^([^"\\]|\\.)*/) || substr(s, RLENGTH + 1, 1) != "\"") { BAD = 1; return "" }
  s = substr(s, 1, RLENGTH)
  n = split(s, P, "\\")
  out = P[1]; lit = 0
  for (i = 2; i <= n; i++) {
    p = P[i]
    if (lit) { out = out p; lit = 0; continue }
    if (p == "") { out = out "\\"; lit = 1; continue }
    c = substr(p, 1, 1); m = substr(p, 2)
    if (c == "n") out = out "\n" m
    else if (c == "t") out = out "\t" m
    else if (c == "r") out = out "\r" m
    else if (c == "u") out = out "\\u" m
    else out = out c m
  }
  return out
}
function endword(l) {
  if (INW[l]) { if (RDR[l]) RDR[l] = 0; else { NW[l]++; W[l, NW[l]] = WRD[l] } }
  WRD[l] = ""; INW[l] = 0
}
function endseg(l) {
  endword(l)
  if (NW[l] > 0) classify(l, 1, NW[l])
  NW[l] = 0; RDR[l] = 0
}
function runstr(str) { DEPTH++; scan(str, 0); DEPTH-- }
function joinw(l, a, e,   r, k) { r = ""; for (k = a; k <= e; k++) r = r (k > a ? " " : "") W[l, k]; return r }
function qargs(l, a, e,   r, k) { r = ""; for (k = a; k <= e; k++) r = r (k > a ? " " : "") quote(W[l, k]); return r }
function isshell(b) { return b ~ /^(bash|sh|zsh|dash|ksh)$/ }
function cflag(l, a, e,   k) { for (k = a; k <= e; k++) if (W[l, k] ~ /^-[A-Za-z]*c[A-Za-z]*$/) return k; return 0 }
# index of the command word after assignments and wrappers, or 0
function strip(l, a, e,   i, t, b, j, u) {
  i = a
  while (i <= e) {
    t = W[l, i]
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
    b = base(t)
    if (b == "!" || b == "{" || b ~ /^(if|then|elif|else|do|while|until)$/) { i++; continue }
    if (b ~ /^(env|command|builtin|exec|nohup|nice|time|sudo|doas|ionice|timeout|watch|stdbuf|xargs|wsl)$/) {
      i++
      while (i <= e) {
        u = W[l, i]
        if (u ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
        if (substr(u, 1, 1) != "-" || u == "-") break
        if (b == "command" && (u == "-v" || u == "-V")) return 0
        if ((b == "env" && inset(u, "|-u|-C|-S|--unset|--chdir|")) || (b == "sudo" && inset(u, "|-u|-g|-C|-D|-h|-p|-r|-t|-T|-U|-R|")) || (b == "timeout" && inset(u, "|-s|-k|")) || (b == "xargs" && inset(u, "|-I|-i|-n|-P|-d|-L|-a|-E|-s|")) || (b == "doas" && inset(u, "|-u|-C|-a|")) || (b == "ionice" && inset(u, "|-c|-n|-p|-P|-u|")) || (b == "wsl" && inset(u, "|-d|--distribution|-u|--user|--cd|--shell-type|")) || (b == "nice" && u == "-n") || (b == "watch" && u == "-n") || (b == "stdbuf" && inset(u, "|-i|-o|-e|")) || (b == "exec" && u == "-a")) i++
        i++
      }
      if (b == "timeout") i++
      continue
    }
    if (b == "cmd") {
      u = 0
      j = i + 1
      while (j <= e && tolower(W[l, j]) ~ /^\/[a-z]$/) { if (tolower(W[l, j]) ~ /^\/[ck]$/) u = 1; j++ }
      if (!u) return i
      if (j == e) { runstr(W[l, j]); return 0 }
      i = j; continue
    }
    break
  }
  return i <= e ? i : 0
}
function classify(l, a, e,   i, b, k, m) {
  i = strip(l, a, e)
  if (!i) return
  b = base(W[l, i])
  if (b == "git") gitcheck(l, i, e)
  else if (isshell(b)) { k = cflag(l, i + 1, e); if (k && k < e) runstr(W[l, k + 1]) }
  else if (b == "eval") runstr(joinw(l, i + 1, e))
  else if (b == "pwsh" || b == "powershell") {
    for (k = i + 1; k <= e; k++) if (tolower(W[l, k]) ~ /^-c(o(m(m(a(n(d)?)?)?)?)?)?$/) { runstr(joinw(l, k + 1, e)); break }
  }
  else if (b == "iex" || b == "invoke-expression") {
    k = i + 1; if (tolower(W[l, k]) ~ /^-c/) k++
    runstr(joinw(l, k, e))
  }
  else if (b == "find") {
    for (k = i + 1; k <= e; k++) if (inset(W[l, k], "|-exec|-execdir|-ok|-okdir|")) {
      for (m = k + 1; m <= e && W[l, m] != ";" && W[l, m] != "+"; m++) ;
      if (m > k + 1) classify(l, k + 1, m - 1)
      k = m
    }
  }
}
function gitcheck(l, i, e,   j, t, dir, verb, s, wr, a, k, kv, eq, nm, v, c, d, bad, lst) {
  GEN++
  j = i + 1; dir = ""
  while (j <= e) {
    t = W[l, j]
    if (t == "-C") { dir = W[l, j + 1]; j += 2 }
    else if (t == "-c") {
      kv = W[l, j + 1]; eq = index(kv, "=")
      if (tolower(substr(kv, 1, 6)) == "alias." && eq > 7) { nm = tolower(substr(kv, 7, eq - 7)); ALG[nm] = GEN; ALV[nm] = substr(kv, eq + 1) }
      j += 2
    }
    else if (inset(t, "|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--exec-path|")) j += 2
    else if (substr(t, 1, 1) == "-") j++
    else break
  }
  if (j > e) return
  verb = tolower(W[l, j]); s = j + 1; wr = 0
  a = (s <= e) ? tolower(W[l, s]) : ""
  if (inset(verb, WV)) wr = 1
  else if (verb == "stash") wr = (s > e || substr(a, 1, 1) == "-" || inset(a, "|push|pop|apply|drop|clear|save|branch|create|store|"))
  else if (verb == "branch" || verb == "tag") {
    # write flag: write; list mode (flag below, or no name given): read; a name otherwise creates
    c = 0; lst = 0
    for (k = s; k <= e && !wr; k++) {
      t = W[l, k]
      if (inset(t, (verb == "branch") ? BO : TO)) wr = 1
      else if (verb == "branch" && t ~ /^-[^-]*[dDmMcCfu]/) wr = 1
      else if (verb == "tag" && t ~ /^-[^-]*[dasfmFu]/) wr = 1
      else if (verb == "branch" && index(t, "--set-upstream-to=") == 1) wr = 1
      else if (verb == "tag" && (index(t, "--message=") == 1 || index(t, "--file=") == 1)) wr = 1
      else if (t ~ /^-[^-]*[lv]/ || t ~ /^--(list|(no-)?contains|(no-)?merged|points-at)(=|$)/) lst = 1
      else if (verb == "branch" && t ~ /^--(verbose|show-current)$/) lst = 1
      else if (verb == "tag" && (t ~ /^-n[0-9]*$/ || t == "--verify")) lst = 1
      else if (inset(t, "|--sort|--format|")) k++
      else if (substr(t, 1, 1) != "-") c++
    }
    if (!wr) wr = (c > 0 && !lst)
  }
  else if (inset(verb, "|submodule|notes|bisect|sparse-checkout|")) {
    # read subcommands are listed; any other subcommand writes; none: read
    for (k = s; k <= e && substr(W[l, k], 1, 1) == "-"; k++) if (W[l, k] == "--ref") k++
    if (k > e) return
    a = tolower(W[l, k])
    if (verb == "submodule" && a == "foreach") {
      for (k++; k <= e && substr(W[l, k], 1, 1) == "-"; k++) ;
      if (k <= e) classify(l, k, e)
      return
    }
    wr = !inset(a, verb == "submodule" ? "|status|summary|" : verb == "notes" ? "|list|show|" : verb == "bisect" ? "|log|visualize|view|help|" : "|list|check-rules|")
  }
  else if (verb == "symbolic-ref") {
    c = 0
    for (k = s; k <= e; k++) {
      t = W[l, k]
      if (t == "-d" || t == "--delete") wr = 1
      else if (t == "-m") k++
      else if (substr(t, 1, 1) != "-") c++
    }
    if (c >= 2) wr = 1
  }
  else if (verb == "replace") {
    wr = (s <= e)
    for (k = s; k <= e; k++) if (W[l, k] == "-l" || W[l, k] == "--list") wr = 0
  }
  else if (verb == "clean") {
    wr = 1
    for (k = s; k <= e; k++) if (W[l, k] ~ /^-[A-Za-z]*n[A-Za-z]*$/ || W[l, k] == "--dry-run") wr = 0
  }
  else if (verb == "worktree") wr = inset(a, "|add|remove|move|prune|lock|unlock|repair|")
  else if (verb == "remote") wr = inset(a, "|add|remove|rm|rename|set-url|set-head|set-branches|prune|update|")
  else if (verb == "reflog") wr = inset(a, "|expire|delete|")
  else if (verb == "config") {
    c = 0; d = 0; bad = 0; v = ""
    for (k = s; k <= e; k++) {
      t = W[l, k]
      if (inset(t, "|--unset|--unset-all|--add|--replace-all|--rename-section|--remove-section|--edit|-e|")) bad = 1
      else if (inset(t, "|--get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|--list|-l|--show-origin|--show-scope|")) d = 1
      else if (inset(t, "|--file|-f|--blob|--type|--default|")) k++
      else if (substr(t, 1, 1) != "-") { c++; if (c == 1) v = tolower(t) }
    }
    if (bad || inset(v, "|set|unset|rename-section|remove-section|edit|")) wr = 1
    else if (d || v == "get" || v == "list") wr = 0
    else wr = (c >= 2)
  }
  else if (inset(verb, RV)) return
  else {
    if (dir != "" && cwd != "" && dir !~ /^([\/~\\]|[A-Za-z]:)/) dir = cwd "/" dir
    if (dir == "") dir = cwd
    if (ALG[verb] == GEN) {
      v = ALV[verb]
      if (substr(v, 1, 1) == "!") BLK = 1
      else if (v != "") runstr("git " (dir != "" ? "-C " quote(dir) " " : "") v " " qargs(l, s, e))
    } else ALS = ALS "ALIAS\037" verb "\037" dir "\037" qargs(l, s, e) "\n"
    return
  }
  if (wr) BLK = 1
}
function shellhd(l,   i, e) {
  e = NW[l]; i = strip(l, 1, e)
  return (i && isshell(base(W[l, i])) && !cflag(l, i + 1, e)) ? 1 : 0
}
# tokenize s into segments and classify each; with stop, end at the unmatched ) and return chars used
function scan(s, stop,   l, i, n, c, c2, inq, par, nhd, j, k, q, d, ds, rest, body, line, p) {
  if (DEPTH > 3) return length(s) + 1
  l = ++LV; NW[l] = 0; WRD[l] = ""; INW[l] = 0; RDR[l] = 0
  inq = 0; par = 0; nhd = 0; n = length(s); i = 1
  while (i <= n && !PERR) {
    c = substr(s, i, 1); c2 = substr(s, i + 1, 1)
    if (inq) {
      if (c == "\"") { inq = 0; i++ }
      else if (c == "\\") {
        if (c2 == "\n") i += 2
        else if (c2 == "\"" || c2 == "\\" || c2 == "$" || c2 == "`") { WRD[l] = WRD[l] c2; i += 2 }
        else { WRD[l] = WRD[l] c; i++ }
      }
      else if (c == "$" && c2 == "(") { i += 2 + scan(substr(s, i + 2), 1) }
      else if (c == "`") {
        j = index(substr(s, i + 1), "`")
        if (!j) PERR = 1
        else { scan(substr(s, i + 1, j - 1), 0); i += j + 1 }
      }
      else { WRD[l] = WRD[l] c; i++ }
      continue
    }
    if (c == "\\") {
      if (c2 == "\n") i += 2
      else { WRD[l] = WRD[l] c2; INW[l] = 1; i += 2 }
    }
    else if (c == "\047") {
      j = index(substr(s, i + 1), "\047")
      if (!j) PERR = 1
      else { WRD[l] = WRD[l] substr(s, i + 1, j - 1); INW[l] = 1; i += j + 1 }
    }
    else if (c == "\"") { inq = 1; INW[l] = 1; i++ }
    else if (c == "$" && c2 == "\047") i++
    else if (c == " " || c == "\t" || c == "\r") { endword(l); i++ }
    else if (c == "#" && !INW[l]) { j = index(substr(s, i), "\n"); i = j ? i + j - 1 : n + 1 }
    else if (c == "\n") {
      endseg(l); i++
      if (nhd > 0) {
        rest = substr(s, i)
        for (k = 1; k <= nhd && !PERR; k++) {
          body = ""
          while (rest != "") {
            p = index(rest, "\n")
            if (p) { line = substr(rest, 1, p - 1); rest = substr(rest, p + 1) } else { line = rest; rest = "" }
            sub(/\r$/, "", line)
            if (HDS[l, k]) sub(/^\t+/, "", line)
            if (line == HDW[l, k]) break
            body = body line "\n"
          }
          if (HDX[l, k]) runstr(body)
        }
        i = n - length(rest) + 1; nhd = 0
      }
    }
    else if (c == ";" || c == "|" || c == "&" || c == "`") { endseg(l); i++ }
    else if (c == "(") { endseg(l); par++; i++ }
    else if (c == ")") {
      endseg(l)
      if (stop && par == 0) { LV--; return i }
      if (par > 0) par--
      i++
    }
    else if (c == "<" && c2 == "<" && substr(s, i + 2, 1) != "<") {
      endword(l); j = i + 2; ds = 0
      if (substr(s, j, 1) == "-") { ds = 1; j++ }
      while (substr(s, j, 1) == " " || substr(s, j, 1) == "\t") j++
      d = ""
      while (j <= n && !PERR) {
        q = substr(s, j, 1)
        if (q == "\047" || q == "\"") {
          k = index(substr(s, j + 1), q)
          if (!k) PERR = 1
          else { d = d substr(s, j + 1, k - 1); j += k + 1 }
        }
        else if (q == "\\") { d = d substr(s, j + 1, 1); j += 2 }
        else if (q ~ /[ \t\r\n;&|()<>]/) break
        else { d = d q; j++ }
      }
      if (d == "") i += 2
      else { nhd++; HDW[l, nhd] = d; HDS[l, nhd] = ds; HDX[l, nhd] = shellhd(l); i = j }
    }
    else if (c == "<" || c == ">") {
      if (INW[l] && WRD[l] ~ /^[0-9]+$/) { WRD[l] = ""; INW[l] = 0 } else endword(l)
      while (substr(s, i, 1) == "<" || substr(s, i, 1) == ">") i++
      if (substr(s, i, 1) == "&" || substr(s, i, 1) == "|") i++
      RDR[l] = 1
    }
    else { WRD[l] = WRD[l] c; INW[l] = 1; i++ }
  }
  if (inq || stop) PERR = 1
  if (!PERR) endseg(l)
  LV--
  return i
}
BEGIN {
  MODE = ENVIRON["GUYB_MODE"]; cwd = ENVIRON["GUYB_CWD"]
  WV = "|add|stage|commit|reset|checkout|switch|restore|rebase|merge|push|rm|mv|apply|cherry-pick|pull|fetch|revert|am|update-ref|gc|prune|repack|init|clone|filter-branch|maintenance|read-tree|checkout-index|update-index|"
  RV = "|status|log|diff|show|grep|blame|annotate|ls-files|ls-tree|ls-remote|rev-parse|rev-list|cat-file|describe|shortlog|show-ref|show-branch|for-each-ref|merge-base|name-rev|var|help|version|whatchanged|range-diff|cherry|diff-tree|diff-index|diff-files|check-ignore|check-attr|check-mailmap|count-objects|verify-commit|verify-tag|fsck|format-patch|archive|bundle|request-pull|fast-export|"
  BO = "|--delete|--move|--copy|--force|--set-upstream-to|--unset-upstream|--edit-description|"
  TO = "|--delete|--annotate|--sign|--force|--message|--file|"
}
{ raw = raw (NR > 1 ? "\n" : "") $0 }
END {
  if (MODE == "cmd") cmd = raw
  else { cmd = jget("command"); cwd = jget("cwd") }
  if (BAD || cmd == "") exit 0
  scan(cmd, 0)
  if (PERR) exit 0
  if (BLK) print "BLOCK"
  else printf "%s", ALS
}'
}

_gro_block() {
  {
    echo "guyb: blocked - read-only agent '$_gro_agent' may not run git write commands."
    echo "Report what you would change instead; the orchestrator or git-ops makes repo changes."
  } >&2
  exit 2
}

# _gro_handle <awk output> <depth>: block, or resolve ALIAS lines through git config
_gro_handle() {
  local tag verb dir qargs v out
  while IFS=$'\037' read -r tag verb dir qargs; do
    case $tag in
      BLOCK) _gro_block ;;
      ALIAS)
        [ "$2" -gt 3 ] && continue
        if [ -n "$dir" ]; then v=$(git -C "$dir" config --get "alias.$verb" 2>/dev/null); else v=$(git config --get "alias.$verb" 2>/dev/null); fi
        [ -z "$v" ] && continue
        case $v in '!'*) _gro_block ;; esac
        out=$(GUYB_MODE=cmd GUYB_CWD=$dir _gro_awk <<<"git $v $qargs") || continue
        _gro_handle "$out" "$(($2 + 1))"
        ;;
    esac
  done <<<"$1"
}

_gro_out=$(_gro_awk <<<"$input") || exit 0
[ -n "$_gro_out" ] && _gro_handle "$_gro_out" 1
exit 0
