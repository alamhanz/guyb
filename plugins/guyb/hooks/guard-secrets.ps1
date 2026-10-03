# guyb PreToolUse guard: block `git commit` when secret-looking files are staged.
# PowerShell twin of guard-secrets.sh: keep the patterns in both files in sync.
# Exit 2 blocks the tool call and feeds stderr back to Claude; any other exit lets it run.
# Ignores stdin. Works on Windows PowerShell 5.1 and PowerShell 7.

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { exit 0 }

$files = & git -c core.quotepath=off diff --cached --name-only 2>$null
if ($LASTEXITCODE -ne 0 -or -not $files) { exit 0 }

$secret = '(^|/)(\.env(\.[^/]*)?|[^/]*\.(pem|key|p12|pfx|jks|keystore)|id_(rsa|ed25519|ecdsa)[^/]*|credentials(\.[^/]*)?|[^/]*service[-_]?account[^/]*\.json)$'
$safe = '\.(example|sample|template|pub)$'

$bad = @($files | Where-Object { $_ -match $secret -and $_ -notmatch $safe })

if ($bad.Count -gt 0) {
    [Console]::Error.WriteLine('guyb: blocked git commit - secret-looking files are staged:')
    foreach ($f in $bad) { [Console]::Error.WriteLine("  $f") }
    [Console]::Error.WriteLine('Unstage them (git restore --staged <file>), add them to .gitignore, and commit again.')
    [Console]::Error.WriteLine('If a file is definitely not a secret, ask the user to confirm, then commit it manually.')
    exit 2
}
exit 0
