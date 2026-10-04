# guyb PreToolUse guard: stop read-only subagents from running git write commands.
# PowerShell twin of guard-readonly.sh: keep the verb list and agent list in both files in sync.
# The whole command string is scanned, so git after cd/&&/;/|/newline is seen (hooks.json filters on *git*).
# Fail open: exit 2 only when the hook input names a read-only guyb subagent AND the command
# is a git write verb. Missing field, parse trouble, or any other agent: exit 0.
#
# Verified hook stdin (Claude Code 2.1.288): PreToolUse JSON for a call made inside a subagent
# carries "agent_id" and "agent_type". Plugin agents report "agent_type":"guyb:<name>"
# (accept the bare name too). Main-session calls carry neither field.
# Works on Windows PowerShell 5.1 and PowerShell 7.

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $data = $raw | ConvertFrom-Json
    $agent = [string]$data.agent_type
    $cmd = [string]$data.tool_input.command
} catch { exit 0 }

$name = $agent -replace '^guyb:', ''
if (@('code-reviewer', 'architect', 'data-modeler', 'data-analyst') -notcontains $name) { exit 0 }
if (-not $cmd) { exit 0 }

# Write verbs always blocked; stash, branch, tag, worktree, remote, reflog, config are blocked only in their
# write forms (stash list/show, branch/tag listing, worktree list, config --get/--list stay allowed).
# Matching is case-insensitive; git may be quoted or a full path, and options may carry quoted values.
$verbs = 'add|stage|commit|reset|checkout|switch|clean|restore|rebase|merge|push|rm|mv|apply|cherry-pick|pull|fetch|revert|am|notes|update-ref|symbolic-ref|replace|gc|prune|repack|submodule|init|clone|filter-branch|maintenance|sparse-checkout|read-tree|checkout-index|update-index|bisect'
$arg = '("[^"]*"|''[^'']*''|\S+)'
$opts = "(-c\s+$arg|-C\s+$arg|-[pP]|--(git-dir|work-tree|namespace|exec-path|super-prefix|config-env)\s+$arg|--[a-z-]+(=\S*)?)"
$pre = "(^|[^\w.-])[`"']?git(\.exe)?[`"']?(\s+$opts)*\s+"
$patterns = @(
    "$pre($verbs)([^\w-]|`$)",
    "${pre}stash(\s*(`$|[;&|])|\s+(push|pop|apply|drop|clear|save|branch|create|store|-))",
    "${pre}branch\s+(([^|;&]*\s)?(-[dDmMcCf]|--delete|--move|--copy|--force)(\s|`$)|[^-\s|;&])",
    "${pre}tag\s+(([^|;&]*\s)?(-[dasfm]|--delete|--annotate|--sign|--force|--message)(\s|`$)|[^-\s|;&])",
    "${pre}worktree\s+(add|remove|move|prune|lock|unlock|repair)([^\w-]|`$)",
    "${pre}remote\s+(add|remove|rm|rename|set-url|set-head|set-branches|prune|update)([^\w-]|`$)",
    "${pre}reflog\s+(expire|delete)([^\w-]|`$)"
)
# config is judged per segment, so a read in one segment never excuses a write in another.
# Allowed reads: --get*/--list/-l/--show-origin, or a single key with no value.
$hit = $false
$configRead = "${pre}config\s+(([^|;&]*\s)?(--get[a-z-]*|--list|-l|--show-origin)([^\w-]|`$)|[^-\s]\S*\s*`$)"
foreach ($seg in ($cmd -split '[;&|\r\n]')) {
    if ($seg -match "${pre}config([^\w-]|`$)" -and $seg -notmatch $configRead) { $hit = $true }
}
foreach ($p in $patterns) { if ($cmd -match $p) { $hit = $true; break } }
if ($hit) {
    [Console]::Error.WriteLine("guyb: blocked - read-only agent '$name' may not run git write commands.")
    [Console]::Error.WriteLine('Report what you would change instead; the orchestrator or git-ops makes repo changes.')
    exit 2
}
exit 0
