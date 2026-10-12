# Fixture tests for plugins/guyb/statusline/guyb-status.ps1. Usage: pwsh -File tests/statusline.ps1
# Builds throwaway project trees in a temp dir (removed on exit); writes nothing in the repo, no network.
# Runs the script in a child of the current PowerShell host (pwsh 7 or Windows PowerShell 5.1).
# Bash twin: statusline.sh (keep the cases and expected lines in sync).
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'plugins/guyb/statusline/guyb-status.ps1'
$hostExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('guyb-statusline.' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmp = (Resolve-Path -LiteralPath $tmp).ProviderPath
$script:fail = 0
$utf8 = New-Object Text.UTF8Encoding $false
$OutputEncoding = $utf8   # PS 5.1 pipes to native programs as ASCII by default, which would turn the BOM into ?

function Check([string]$name, [string]$expected, [string]$actual) {
    if ($expected -ceq $actual) { Write-Host "ok   $name" }
    else { Write-Host "FAIL ${name}: expected [$expected] got [$actual]"; $script:fail++ }
}
function Run([string]$cwd, [string]$stdin) {
    Push-Location -LiteralPath $cwd
    try { return (($stdin | & $hostExe -NoProfile -File $script 2>&1) -join "`n") }
    finally { Pop-Location }
}
function Esc([string]$p) { return $p.Replace('\', '\\') }
function Json([string]$d) {
    $e = Esc $d
    return "{`"session_id`":`"s`",`"workspace`":{`"current_dir`":`"$e`",`"project_dir`":`"$e`"},`"cwd`":`"$e`"}"
}
function Put([string]$path, [string[]]$lines, $enc = $utf8) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $enc)
}
function Proj([string]$name, [string]$head) { Put (Join-Path $tmp "$name/.git/HEAD") @($head) }
function Runs([string]$dir) {
    Put (Join-Path $dir 'runs.md') @(
        '| ID | Agent | Model | Task | Wave | After | Status | Started | Tokens |',
        '|---|---|---|---|---|---|---|---|---|',
        '| a-1 | x | m | t | 1 | - | done | d | 1k |',
        '| a-2 | x | m | t | 1 | - | running | d | 1k |',
        '| a-3 | x | m | t | 1 | - | running | d | 1k |')
}
function Questions([string]$dir, [int]$open) {
    $l = @('| ID | Run | Question | Blocking | Assumed | Status |', '|---|---|---|---|---|---|',
        '| Q1 | a-1 | q | no | a | answered: yes |')
    for ($n = 1; $n -le $open; $n++) { $l += "| Q$($n + 1) | a-1 | q | no | a | open |" }
    Put (Join-Path $dir 'questions.md') $l
}

try {
    # new registry, 2 running, 1 open question, branch from ref
    $newReg = Join-Path $tmp 'new/.claude/guyb/pipeline'
    Proj 'new' 'ref: refs/heads/main'
    Runs $newReg; Questions $newReg 1
    Check 'new registry' 'guyb > new  main  2 running  1 question' (Run $tmp (Json (Join-Path $tmp 'new')))
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'new/a/b') | Out-Null
    Check 'subdirectory finds root' 'guyb > new  main  2 running  1 question' (Run $tmp (Json (Join-Path $tmp 'new/a/b')))
    Questions $newReg 2
    Check 'plural questions' 'guyb > new  main  2 running  2 questions' (Run $tmp (Json (Join-Path $tmp 'new')))
    Proj 'br' 'ref: refs/heads/feat/x'
    Check 'branch with slash' 'guyb > br  feat/x' (Run $tmp (Json (Join-Path $tmp 'br')))

    # only cwd; workspace.current_dir wins over cwd; current dir fallback on empty or garbled stdin
    $n = Esc (Join-Path $tmp 'new'); $b = Esc (Join-Path $tmp 'br'); $nope = Esc (Join-Path $tmp 'nope')
    Check 'only cwd' 'guyb > new  main  2 running  2 questions' (Run $tmp "{`"cwd`":`"$n`"}")
    Check 'current_dir wins' 'guyb > br  feat/x' (Run $tmp "{`"cwd`":`"$n`",`"workspace`":{`"current_dir`":`"$b`"}}")
    Check 'BOM on stdin' 'guyb > br  feat/x' (Run $tmp ([string][char]0xFEFF + "{`"cwd`":`"$b`"}"))
    Check 'empty stdin uses current dir' 'guyb > br  feat/x' (Run (Join-Path $tmp 'br') '')
    Check 'garbled stdin uses current dir' 'guyb > br  feat/x' (Run (Join-Path $tmp 'br') '{not json "cwd": ')
    Check 'missing dir uses current dir' 'guyb > br  feat/x' (Run (Join-Path $tmp 'br') "{`"cwd`":`"$nope`"}")

    # legacy registry: only when STATE.md is guyb-owned; new wins when both exist
    $legReg = Join-Path $tmp 'leg/.claude/pipeline'; $legState = Join-Path $tmp 'leg/.claude/STATE.md'
    Proj 'leg' 'ref: refs/heads/dev'
    Runs $legReg; Questions $legReg 1
    Put $legState @('# T', '## Decisions')
    Check 'legacy not owned' 'guyb > leg  dev' (Run $tmp (Json (Join-Path $tmp 'leg')))
    [IO.File]::WriteAllText($legState, "<!-- guyb:state -->`r`n# T`r`n", $utf8)
    Check 'legacy owned by marker (CRLF)' 'guyb > leg  dev  2 running  1 question' (Run $tmp (Json (Join-Path $tmp 'leg')))
    Put $legState @('# Next up', '## open issues', '### DECISIONS', '# Recent changes') (New-Object Text.UTF8Encoding $true)
    Check 'legacy owned by headings (BOM)' 'guyb > leg  dev  2 running  1 question' (Run $tmp (Json (Join-Path $tmp 'leg')))
    $legNew = Join-Path $tmp 'leg/.claude/guyb/pipeline'
    Put (Join-Path $legNew 'runs.md') @('| ID | Status |', '|---|---|', '| n-1 | running |')
    Check 'both present, new wins' 'guyb > leg  dev  1 running  1 question' (Run $tmp (Json (Join-Path $tmp 'leg')))
    Put (Join-Path $legNew 'runs.md') @('| Status | ID |', '|---|---|', '| Running | n-1 |', '| running | |')
    Check 'columns by header name, blank id skipped' 'guyb > leg  dev  1 running  1 question' (Run $tmp (Json (Join-Path $tmp 'leg')))

    # zero counts, non-git, detached HEAD, worktree gitdir file, spaces, non-ASCII
    Proj 'zero' 'ref: refs/heads/main'
    $zeroReg = Join-Path $tmp 'zero/.claude/guyb/pipeline'
    Runs $zeroReg
    [IO.File]::WriteAllText((Join-Path $zeroReg 'runs.md'), ([IO.File]::ReadAllText((Join-Path $zeroReg 'runs.md')) -replace 'running', 'done'), $utf8)
    Check 'zero counts omitted' 'guyb > zero  main' (Run $tmp (Json (Join-Path $tmp 'zero')))
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'nogit') | Out-Null
    Check 'non-git dir' 'guyb > nogit' (Run $tmp (Json (Join-Path $tmp 'nogit')))
    Proj 'det' 'abcdef0123456789abcdef0123456789abcdef01'
    Check 'detached HEAD' 'guyb > det  abcdef0' (Run $tmp (Json (Join-Path $tmp 'det')))
    Put (Join-Path $tmp 'gd/main.git/HEAD') @('ref: refs/heads/wt-branch')
    Put (Join-Path $tmp 'wt-abs/.git') @("gitdir: $(Join-Path $tmp 'gd/main.git')")
    Put (Join-Path $tmp 'wt-rel/.git') @('gitdir: ../gd/main.git')
    Check 'worktree gitdir (absolute)' 'guyb > wt-abs  wt-branch' (Run $tmp (Json (Join-Path $tmp 'wt-abs')))
    Check 'worktree gitdir (relative)' 'guyb > wt-rel  wt-branch' (Run $tmp (Json (Join-Path $tmp 'wt-rel')))
    Proj 'my app' 'ref: refs/heads/main'
    Check 'name with spaces' 'guyb > my app  main' (Run $tmp (Json (Join-Path $tmp 'my app')))
    $uni = 'caf' + [char]0xE9
    Proj $uni 'ref: refs/heads/main'
    Check 'non-ASCII name gives ASCII output' 'guyb > caf??  main' (Run (Join-Path $tmp $uni) '')

    # Windows-style paths in JSON (backslashes, forward slashes)
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        $w = Join-Path $tmp 'new'
        Check 'Windows-style path, escaped backslashes' 'guyb > new  main  2 running  2 questions' (Run $tmp "{`"workspace`":{`"current_dir`":`"$(Esc $w)`"}}")
        Check 'Windows-style path, forward slashes' 'guyb > new  main  2 running  2 questions' (Run $tmp "{`"cwd`":`"$($w.Replace('\', '/'))`"}")
    } else { Write-Host 'skip Windows-style path (not Windows)' }

    # usage guard: rate_limits -> state file + segment (GUYB_USAGE_DIR keeps it inside $tmp)
    $env:GUYB_USAGE_DIR = Join-Path $tmp 'usage'
    Proj 'uc' 'ref: refs/heads/main'
    $uc = Join-Path $tmp 'uc'
    function UJ([string]$d, $p5, $p7) { # resets_at 4102444800 = year 2100
        return "{`"cwd`":`"$(Esc $d)`",`"rate_limits`":{`"five_hour`":{`"used_percentage`":$p5,`"resets_at`":4102444800},`"seven_day`":{`"used_percentage`":$p7,`"resets_at`":4102444800}}}"
    }
    function UState { $f = Join-Path $env:GUYB_USAGE_DIR 'state'; if ([IO.File]::Exists($f)) { return ([IO.File]::ReadAllText($f)).TrimEnd("`n") } return 'none' }
    function UCheck([string]$n, [string]$want, [string]$stdin) { Check $n $want ("$(Run $tmp $stdin)|$(UState)") }
    UCheck 'usage below 50: plain, no state' 'guyb > uc  main|none' (UJ $uc 10 20)
    UCheck 'usage 50-92: no segment, no state' 'guyb > uc  main|none' (UJ $uc 60 92)
    UCheck 'warn on 5h (float pct)' 'guyb > uc  main  5h 93%|warn 5h 93 4102444800' (UJ $uc 93.4 20)
    Put (Join-Path $env:GUYB_USAGE_DIR 'state') @('warn 5h 99 4102444800')
    $null = Run $tmp (UJ $uc 94 20)
    Check 'same tier: state not rewritten' 'warn 5h 99 4102444800' (UState)
    UCheck 'stop, 7d wins the tie' 'guyb > uc  main  wk 98%|stop 7d 98 4102444800' (UJ $uc 99 98)
    UCheck 'stop on 5h alone' 'guyb > uc  main  5h 99%|stop 5h 99 4102444800' (UJ $uc 99 20)
    UCheck 'back below: state removed' 'guyb > uc  main|none' (UJ $uc 10 20)
    UCheck 'no resets_at: window ignored' 'guyb > uc  main|none' "{`"cwd`":`"$(Esc $uc)`",`"rate_limits`":{`"five_hour`":{`"used_percentage`":99}}}"
    $ucc = Join-Path $uc '.claude/CLAUDE.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ucc) | Out-Null
    [IO.File]::WriteAllText($ucc, "- usage_warn: 80`r`nusage_stop: 85`r`n", $utf8)
    UCheck 'project config thresholds (CRLF)' 'guyb > uc  main  5h 86%|stop 5h 86 4102444800' (UJ $uc 86 20)
    Put $ucc @('usage_stop: 0')
    UCheck 'usage_stop 0 = off: warn only' 'guyb > uc  main  5h 99%|warn 5h 99 4102444800' (UJ $uc 99 20)
    Put $ucc @('usage_warn: 0', 'usage_stop: 0')
    UCheck 'both off' 'guyb > uc  main|none' (UJ $uc 99 99)
    Put $ucc @('usage_warn: 99', 'usage_stop: 90')
    UCheck 'warn above stop: warn = stop' 'guyb > uc  main  5h 91%|stop 5h 91 4102444800' (UJ $uc 91 20)
    Put $ucc @('usage_warn: 30', 'usage_stop: abc')
    UCheck 'invalid values: defaults' 'guyb > uc  main|none' (UJ $uc 60 20)
    Remove-Item -Recurse -Force (Join-Path $uc '.claude')
    [IO.File]::WriteAllText((Join-Path $tmp 'ro'), '')
    $env:GUYB_USAGE_DIR = Join-Path $tmp 'ro/x'
    Check 'state dir unwritable: output unchanged' 'guyb > uc  main  5h 99%' (Run $tmp (UJ $uc 99 20))
    $env:GUYB_USAGE_DIR = $null

    # loose timing sanity (PowerShell startup dominates)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Run $tmp (Json (Join-Path $tmp 'new'))
    $sw.Stop()
    Write-Host "     one run: $($sw.ElapsedMilliseconds) ms"
    if ($sw.ElapsedMilliseconds -le 3000) { Write-Host 'ok   runtime under 3s' }
    else { Write-Host 'FAIL runtime over 3s'; $script:fail++ }
}
finally { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }

if ($script:fail -eq 0) { Write-Host 'statusline: all passed'; exit 0 }
Write-Host "statusline: $($script:fail) failed"; exit 1
