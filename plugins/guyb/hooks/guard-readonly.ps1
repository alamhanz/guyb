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

# Write verbs always blocked; stash, branch, tag, worktree are blocked only in their write forms
# (stash list/show, branch/tag listing and worktree list stay allowed).
$verbs = 'add|commit|reset|checkout|switch|clean|restore|rebase|merge|push|rm|mv|apply|cherry-pick|pull|fetch|revert|am'
$opts = '(-c\s+\S+|-C\s+\S+|--[a-z-]+(=\S*)?)'
$pre = "(^|[^\w.-])git(\.exe)?(\s+$opts)*\s+"
$patterns = @(
    "$pre($verbs)([^\w-]|`$)",
    "${pre}stash(\s*(`$|[;&|])|\s+(push|pop|apply|drop|clear|save|branch|create|store|-))",
    "${pre}branch\s+(([^|;&]*\s)?(-[dDmMcCf]|--delete|--move|--copy|--force)(\s|`$)|[^-\s|;&])",
    "${pre}tag\s+(([^|;&]*\s)?(-[dasfm]|--delete|--annotate|--sign|--force|--message)(\s|`$)|[^-\s|;&])",
    "${pre}worktree\s+(add|remove|move|prune|lock|unlock|repair)([^\w-]|`$)"
)
foreach ($p in $patterns) {
    if ($cmd -cmatch $p) {
        [Console]::Error.WriteLine("guyb: blocked - read-only agent '$name' may not run git write commands.")
        [Console]::Error.WriteLine('Report what you would change instead; the orchestrator or git-ops makes repo changes.')
        exit 2
    }
}
exit 0
