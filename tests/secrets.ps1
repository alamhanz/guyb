# Tests for plugins/guyb/hooks/guard-secrets.ps1 (git -C/-c, chained commands, commit -a, target repo).
# Works on Windows PowerShell 5.1 and PowerShell 7:   pwsh -File tests/secrets.ps1
# Builds throwaway git repos in a temp dir (removed on exit); writes nothing in the repo, needs no network
# or secrets. The guard runs in a child process of the same PowerShell edition, fed hook JSON on stdin.
# Bash twin: secrets.sh (keep the cases in sync).
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$ps = (Get-Process -Id $PID).Path
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('guyb-secrets-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$script:pass = 0; $script:fail = 0
function Ok { $script:pass++ }
function No($msg) { $script:fail++; Write-Host "FAIL: $msg" }
function Expect-Eq($label, $got, $want) { if ("$got" -eq "$want") { Ok } else { No "${label}: got '$got', want '$want'" } }
function Git-Quiet { & git @args *> $null }
function Write-File($path, $text) {
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

$guard = Join-Path $root 'plugins/guyb/hooks/guard-secrets.ps1'

# Run the guard with $stdin (string; '' = empty stdin) from $workdir (the process cwd); returns @(exit code, stderr text).
function Run-Guard([string]$workdir, [string]$stdin) {
  Push-Location -LiteralPath $workdir
  try {
    $raw = $stdin | & $ps -NoProfile -ExecutionPolicy Bypass -File $guard 2>&1
    $code = $LASTEXITCODE
  } finally { Pop-Location }
  return @($code, (@($raw | ForEach-Object { "$_" }) -join "`n"))
}
function Hook-Json([string]$cwd, [string]$cmd) {
  return (@{ session_id = 's'; cwd = $cwd; tool_name = 'PowerShell'; tool_input = @{ command = $cmd } } | ConvertTo-Json -Compress)
}
# Chk <label> <want> <cwd in JSON> <command>; the process cwd is a non-repo dir
function Chk($label, $want, $cwd, $cmd) { Expect-Eq $label (Run-Guard $out (Hook-Json $cwd $cmd))[0] $want }

try {
  $home2 = Join-Path $tmp 'home'
  New-Item -ItemType Directory -Force -Path $home2 | Out-Null
  $env:HOME = $home2; $env:USERPROFILE = $home2
  $env:GIT_TERMINAL_PROMPT = '0'

  function Make-Fixture($dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Git-Quiet -C $dir init -q
    Git-Quiet -C $dir config user.name secrets
    Git-Quiet -C $dir config user.email secrets@example.invalid
    Git-Quiet -C $dir config commit.gpgsign false
    Write-File (Join-Path $dir 'README.md') "# fixture`n"
    Git-Quiet -C $dir add -A
    Git-Quiet -C $dir commit -q -m init
  }

  $out = Join-Path $tmp 'out'; New-Item -ItemType Directory -Force -Path $out | Out-Null
  $par = Join-Path $tmp 'par'; $r = Join-Path $par 'child'; $sp = Join-Path $tmp 'sp dir [v2]'
  Make-Fixture $r; Make-Fixture $sp
  function G { Git-Quiet -C $r @args }
  function GS { Git-Quiet -C $sp @args }

  Write-Host 'plain'
  Write-File (Join-Path $r '.env') "KEY=value`n"; Write-File (Join-Path $r '.env.example') "KEY=`n"
  G add .env
  Chk 'plain staged .env' 2 $r 'git commit -m x'
  G reset -q; G add .env.example
  Chk 'plain staged .env.example' 0 $r 'git commit -m x'
  G reset -q
  Chk 'plain nothing staged' 0 $r 'git commit -m x'

  Write-Host 'git options and target repo'
  G add .env
  Chk '-C repo' 2 $out "git -C '$r' commit -m x"
  Chk '-C parent -C child' 2 $out "git -C '$par' -C child commit -m x"
  Chk '-c k=v' 2 $r 'git -c user.name=a commit -m x'
  Chk '--no-pager' 2 $r 'git --no-pager commit -m x'
  Chk 'git.exe' 2 $r 'git.exe commit -m x'
  Chk 'call operator, quoted -C' 2 $out "& git -C '$r' commit -m x"
  Chk '-C other clean repo' 0 $r "git -C '$sp' commit -m x"
  Chk '-C spaced path, double quotes' 0 $r "git -C `"$sp`" commit -m x"
  Chk 'unquoted bare -C repo' 2 $out "git -C $r commit -m x"

  Write-Host 'chains'
  Chk 'add ; commit' 2 $r 'git add . ; git commit -m x'
  Chk 'Set-Location ; commit' 2 $out "Set-Location '$r'; git commit -m x"
  Chk 'cd && commit' 2 $out "cd '$r' && git commit -m x"
  Chk 'sl alias' 2 $out "sl $r; git commit -m x"
  Chk 'Push-Location -Path' 2 $out "Push-Location -Path '$r'; git commit -m x"
  Chk 'or' 2 $r 'false || git commit -m x'
  Chk 'newline' 2 $r "Write-Host hi`ngit commit -m x"
  Chk 'no commit word' 0 $r 'git status | Out-Null'
  Chk 'echo commit' 0 $r 'echo commit'
  Chk 'recommit' 0 $r 'recommit now'
  Write-File (Join-Path $sp '.env') "KEY=value`n"; GS add .env
  Chk 'Set-Location spaced repo' 2 $out "Set-Location '$sp'; git commit -m x"
  Chk 'Set-Location -LiteralPath' 2 $out "Set-Location -LiteralPath `"$sp`"; git commit -m x"
  Chk 'cd away from the bad repo' 0 $r "cd '$par'; git -C '$out' commit -m x"
  GS reset -q

  Write-Host 'here-string message'
  $hd = "git commit -m @'`nbody -a`n'@"
  Chk 'here-string staged .env' 2 $r $hd
  G reset -q
  Write-File (Join-Path $r 'deploy.key') "k`n"; G add deploy.key; G commit -q -m key
  Write-File (Join-Path $r 'deploy.key') "k2`n"
  Chk 'here-string -a in body, nothing staged' 0 $r $hd

  Write-Host 'commit -a and pathspecs'
  Chk 'modified key, plain commit' 0 $r 'git commit -m x'
  Chk '-am' 2 $r 'git commit -am x'
  Chk '-qam' 2 $r 'git commit -qam x'
  Chk '--all' 2 $r 'git commit --all -m x'
  Chk '-a after -m' 2 $r 'git commit -m x -a'
  Chk '-a inside message' 0 $r 'git commit -m "note -a"'
  Chk '-a inside message (single quotes)' 0 $r "git commit -m 'note -a'"
  Chk 'pathspec' 2 $r 'git commit deploy.key -m x'
  Chk '-- pathspec' 2 $r 'git commit -m x -- deploy.key'
  Chk '-o pathspec' 2 $r 'git commit -o deploy.key -m x'
  Chk 'sl + -am' 2 $out "sl $r; git commit -am x"
  Chk '-C on another repo with -a' 2 $out "git -C '$r' commit -am x"

  Write-Host 'deleted files never block'
  G rm -q --cached deploy.key
  Chk 'staged deletion' 0 $r 'git commit -m x'
  Chk 'staged deletion -a' 0 $r 'git commit -am x'
  G commit -q -m 'rm key'
  Remove-Item -LiteralPath (Join-Path $r 'deploy.key') -Force -ErrorAction SilentlyContinue

  Write-Host 'new patterns'
  foreach ($f in @('.envrc', 'k.p8', 'prod.tfvars', 'prod.tfvars.json', 'vault.kdbx', '.netrc', '.npmrc', '.pypirc')) {
    Write-File (Join-Path $r $f) "x`n"; G add -f $f
    Chk "staged $f" 2 $r 'git commit -m x'
    G reset -q; Remove-Item -LiteralPath (Join-Path $r $f) -Force
  }
  Write-File (Join-Path $r 'notes.txt') "x`n"; G add notes.txt
  Chk 'ordinary file' 0 $r 'git commit -m x'
  G reset -q; Remove-Item -LiteralPath (Join-Path $r 'notes.txt') -Force

  Write-Host 'fallback'
  G add .env
  Expect-Eq 'empty stdin, staged .env' (Run-Guard $r '')[0] 2
  Expect-Eq 'bad json' (Run-Guard $r '{bad commit')[0] 2
  Expect-Eq 'empty stdin outside a repo' (Run-Guard $out '')[0] 0
  Chk 'unknown dir falls back to cwd (not a repo)' 0 $out 'cd $env:NOPE; git commit -m x'
  Chk 'unknown dir falls back to cwd (repo)' 2 $r 'cd $env:NOPE; git commit -m x'
  Chk 'missing cwd dir' 0 (Join-Path $tmp 'no-such-dir') 'git commit -m x'
  $m = Run-Guard $out (Hook-Json $out "git -C '$r' commit -m x")
  Expect-Eq 'message names the repo' ($m[1].Contains('would be committed (')) $true
} finally {
  Set-Location -LiteralPath $root
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "secrets: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
