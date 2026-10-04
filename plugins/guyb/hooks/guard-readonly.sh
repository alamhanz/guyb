#!/usr/bin/env bash
# guyb PreToolUse guard: stop read-only subagents from running git write commands.
# PowerShell twin: guard-readonly.ps1 (keep the verb list and agent list in both files in sync).
# The whole command string is scanned, so git after cd/&&/;/|/newline is seen (hooks.json filters on *git*).
# Fail open: exit 2 only when the hook input names a read-only guyb subagent AND the command
# is a git write verb. Missing field, parse trouble, or any other agent: exit 0.
#
# Verified hook stdin (Claude Code 2.1.288): PreToolUse JSON for a call made inside a subagent
# carries "agent_id" and "agent_type". Plugin agents report "agent_type":"guyb:<name>"
# (accept the bare name too). Main-session calls carry neither field.

input=$(cat 2>/dev/null) || exit 0
[ -z "$input" ] && exit 0

if command -v jq >/dev/null 2>&1; then
  agent=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  agent=$(printf '%s' "$input" | sed -nE 's/.*"agent_type"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n 1)
  cmd=$(printf '%s' "$input" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\]|\\.)*)".*/\1/p' | head -n 1)
  # JSON newline escapes act as separators; \" and \\ are decoded so quoted paths match
  cmd=$(printf '%s' "$cmd" | sed -e 's/\\[nrt]/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g')
fi

case "${agent#guyb:}" in
  code-reviewer|architect|data-modeler|data-analyst) ;;
  *) exit 0 ;;
esac
[ -z "$cmd" ] && exit 0

# Write verbs always blocked; stash, branch, tag, worktree, remote, reflog, config are blocked only in their
# write forms (stash list/show, branch/tag listing, worktree list, config --get/--list stay allowed).
# Matching is case-insensitive; git may be quoted or a full path, and options may carry quoted values.
verbs='add|stage|commit|reset|checkout|switch|clean|restore|rebase|merge|push|rm|mv|apply|cherry-pick|pull|fetch|revert|am|notes|update-ref|symbolic-ref|replace|gc|prune|repack|submodule|init|clone|filter-branch|maintenance|sparse-checkout|read-tree|checkout-index|update-index|bisect'
arg='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)'
opts="(-c[[:space:]]+$arg|-C[[:space:]]+$arg|-[pP]|--(git-dir|work-tree|namespace|exec-path|super-prefix|config-env)[[:space:]]+$arg|--[a-z-]+(=[^[:space:]]*)?)"
pre="(^|[^[:alnum:]_.-])[\"']?git(\.exe)?[\"']?([[:space:]]+$opts)*[[:space:]]+"
hit=
chk() { printf '%s' "$cmd" | grep -qiE "$1"; }
chk "$pre($verbs)([^[:alnum:]_-]|\$)" && hit=1
chk "${pre}stash([[:space:]]*(\$|[;&|\"\\])|[[:space:]]+(push|pop|apply|drop|clear|save|branch|create|store|-))" && hit=1
chk "${pre}branch[[:space:]]+(([^|;&]*[[:space:]])?(-[dDmMcCf]|--delete|--move|--copy|--force)([^[:alnum:]_-]|\$)|[^-[:space:]|;&])" && hit=1
chk "${pre}tag[[:space:]]+(([^|;&]*[[:space:]])?(-[dasfm]|--delete|--annotate|--sign|--force|--message)([^[:alnum:]_-]|\$)|[^-[:space:]|;&])" && hit=1
chk "${pre}worktree[[:space:]]+(add|remove|move|prune|lock|unlock|repair)([^[:alnum:]_-]|\$)" && hit=1
chk "${pre}remote[[:space:]]+(add|remove|rm|rename|set-url|set-head|set-branches|prune|update)([^[:alnum:]_-]|\$)" && hit=1
chk "${pre}reflog[[:space:]]+(expire|delete)([^[:alnum:]_-]|\$)" && hit=1
if chk "${pre}config([^[:alnum:]_-]|\$)" && ! chk "${pre}config[[:space:]]+([^|;&]*[[:space:]])?(--get[a-z-]*|--list|-l|--show-origin)([^[:alnum:]_-]|\$)"; then hit=1; fi
if [ -n "$hit" ]; then
  {
    echo "guyb: blocked - read-only agent '${agent#guyb:}' may not run git write commands."
    echo "Report what you would change instead; the orchestrator or git-ops makes repo changes."
  } >&2
  exit 2
fi
exit 0
