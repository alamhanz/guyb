# Tests for the launcher tab features in scripts/launch.ps1: colour table, title sanitising, wt args, dry-run.
# Usage: pwsh -File tests/tabs.ps1 (or powershell -File). Launches nothing (GUYB_DRYRUN=1), needs no wt/claude/network;
# temp dir removed on exit. Bash twin: tabs.sh (keep the expected colour table identical).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('guyb-tabs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'proj\my app'), (Join-Path $tmp 'proj\guyb') | Out-Null
$savedRoot = $env:GUYB_ROOT; $savedDry = $env:GUYB_DRYRUN; $savedTerm = $env:TERM; $savedAscii = $env:GUYB_TAB_ASCII; $savedName = $env:GUYB_TAB_NAME
$savedHome = $env:GUYB_HOME; $env:GUYB_HOME = $null
$env:GUYB_DRYRUN = '1'; $env:GUYB_ROOT = Join-Path $tmp 'proj'; $env:TERM = 'xterm'; $env:GUYB_TAB_ASCII = $null; $env:GUYB_TAB_NAME = $null
# Tab icons by code point (same in tabs.sh): running U+23F3, done U+2705, waiting U+2753.
$RUN = [string][char]0x23F3; $DONE = [string][char]0x2705; $WAIT = [string][char]0x2753
. (Join-Path $root 'scripts\launch.ps1')

$script:pass = 0; $script:fail = 0
function Ok { $script:pass++ }
function No([string]$m) { $script:fail++; Write-Host "FAIL: $m" }
function ExpectEq([string]$n, $got, $want) { if ("$got" -ceq "$want") { Ok } else { No "${n}: got '$got', want '$want'" } }
function ExpectHas([string]$n, [string]$s, [string]$sub) { if ($s.Contains($sub)) { Ok } else { No "${n}: missing '$sub' in: $s" } }
function ExpectLacks([string]$n, [string]$s, [string]$sub) { if ($s.Contains($sub)) { No "${n}: unexpected '$sub' in: $s" } else { Ok } }

try {
    # Colour table (same values in tabs.sh). The unicode name is "cafe" with e-acute (U+00E9).
    ExpectEq color-guyb (_guyb_color 'guyb') '#61AFEF'
    ExpectEq color-shuto (_guyb_color 'shuto') '#E06C75'
    ExpectEq color-space (_guyb_color 'my app') '#61AFEF'
    ExpectEq color-a (_guyb_color 'a') '#D19A66'
    ExpectEq color-unicode (_guyb_color ('caf' + [char]0xE9)) '#56B6C2'
    ExpectEq color-empty (_guyb_color '') '#C678DD'

    # Control characters never reach a title.
    $dirty = 'a' + [char]27 + ']0;x' + [char]7 + 'b' + [char]10 + 'c' + [char]127 + 'd'
    ExpectEq clean (_guyb_clean $dirty) 'a]0;xbcd'
    ExpectEq clean-c1 (_guyb_clean ('a' + [char]0x9B + 'b' + [char]0x80 + 'c' + [char]0xE9)) ('abc' + [char]0xE9)

    # wt argument builder.
    $a = @(_guyb_wt_args 'my app' 'C:\p\my app' 'pwsh.exe' 'PowerShell')
    $line = $a -join ' '
    ExpectLacks wt-suppress $line '--suppressApplicationTitle'
    ExpectHas wt-color $line '--tabColor #61AFEF'
    ExpectHas wt-title $line '--title my app'
    ExpectHas wt-env $a[-1] 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE'
    ExpectHas wt-tab-name $a[-1] "$env:GUYB_TAB_NAME='my app'"
    ExpectHas wt-initial-title $a[-1] '[char]0x2705'
    ExpectEq wt-tab-name-quote (@(_guyb_wt_args "o'k" 'C:\p' 'pwsh.exe' 'PowerShell')[-1].Contains("='o''k'")) $true
    ExpectEq wt-title-arg $a[($a.IndexOf('--title') + 1)] 'my app'
    $semi = @(_guyb_wt_args 'a;b' 'C:\x;y' 'pwsh.exe' 'PowerShell')
    ExpectEq wt-semicolon-title $semi[($semi.IndexOf('--title') + 1)] 'a\;b'
    ExpectEq wt-semicolon-dir $semi[($semi.IndexOf('--startingDirectory') + 1)] 'C:\x\;y'
    ExpectLacks wt-semicolon-cmd ($semi[-1] -replace '\;', '') '\;'
    $esc = @(_guyb_wt_args ('x' + [char]27 + 'y' + [char]7) 'C:\p' 'pwsh.exe' 'PowerShell')
    ExpectEq wt-clean-title $esc[($esc.IndexOf('--title') + 1)] 'xy'

    # Dry-run command lines.
    $out = (guyb 'my app' -Here) -join "`n"
    ExpectHas here-osc $out "here: osc0 $DONE my app"
    $env:GUYB_TAB_ASCII = '1'
    ExpectHas here-osc-ascii ((guyb 'my app' -Here) -join "`n") 'here: osc0 + my app'
    $env:GUYB_TAB_ASCII = $null
    ExpectHas here-env $out "CLAUDE_CODE_DISABLE_TERMINAL_TITLE='1'"
    $out = (guyb 'guyb') -join "`n"
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        ExpectHas wt-dry $out 'wt: -w 0 new-tab'
        ExpectLacks wt-dry-suppress $out '--suppressApplicationTitle'
        ExpectHas wt-dry-color $out '--tabColor #61AFEF'
    }
    else {
        ExpectHas spawn-dry $out 'spawn: '
        ExpectHas spawn-osc $out '[char]27'
        ExpectHas spawn-env $out "CLAUDE_CODE_DISABLE_TERMINAL_TITLE='1'"
    }

    # tab-status.ps1 (Windows half of the status hook): GUYB_DRYRUN=1 prints the title it would write.
    $hook = Join-Path $root 'plugins\guyb\hooks\tab-status.ps1'
    $env:GUYB_TAB_NAME = 'my app'
    ExpectEq hook-running ((& $hook running) -join '') "tab: conout $RUN my app"
    ExpectEq hook-done ((& $hook done) -join '') "tab: conout $DONE my app"
    ExpectEq hook-waiting ((& $hook waiting) -join '') "tab: conout $WAIT my app"
    ExpectEq hook-end ((& $hook end) -join '') 'tab: conout my app'
    $env:GUYB_TAB_ASCII = '1'
    ExpectEq hook-ascii-running ((& $hook running) -join '') 'tab: conout * my app'
    ExpectEq hook-ascii-done ((& $hook done) -join '') 'tab: conout + my app'
    ExpectEq hook-ascii-waiting ((& $hook waiting) -join '') 'tab: conout ? my app'
    $env:GUYB_TAB_ASCII = $null
    ExpectEq hook-bad-state ((& $hook bogus) -join '') ''
    $env:GUYB_TAB_NAME = 'a' + [char]27 + ']0;x' + [char]7 + 'b' + [char]0x9B + 'c' + [char]127
    ExpectEq hook-clean ((& $hook done) -join '') "tab: conout $DONE a]0;xbc"
    $env:GUYB_TAB_NAME = $null
    ExpectEq hook-unset-name ((& $hook running) -join '') ''
    # -List is unaffected by the dry-run flag.
    $list = (guyb -List) -join "`n"
    ExpectHas list-guyb $list "guyb`t$(Join-Path $env:GUYB_ROOT 'guyb')"
    ExpectHas list-space $list 'my app'
    ExpectLacks list-no-dryrun $list 'here:'
    ExpectEq list-root-col (($list -split "`n" | Where-Object { $_ -like "guyb`t*" } | ForEach-Object { ($_ -split "`t")[6] }) -join ',') $env:GUYB_ROOT

    # Multi-root: r1/{a,dup}, r2/{b,dup}; value has an empty, a duplicate and a missing entry.
    $ml = Join-Path $tmp 'ml'
    $r1 = Join-Path $ml 'r1'; $r2 = Join-Path $ml 'r2'
    New-Item -ItemType Directory -Force -Path (Join-Path $r1 'a'), (Join-Path $r1 'dup'), (Join-Path $r2 'b'), (Join-Path $r2 'dup') | Out-Null
    $sep = [string][IO.Path]::PathSeparator
    $gone = Join-Path $ml 'gone'
    $env:GUYB_ROOT = (@($r1, '', $r2, "$r1/", $gone) -join $sep)
    $mlist = (guyb -List) -join "`n"
    # The warning goes to the real stderr (stdout stays parseable); read it from a child shell.
    $ErrorActionPreference = 'Continue'
    $warn = (& (Get-Process -Id $PID).Path -NoProfile -Command ". '$(Join-Path $root 'scripts\launch.ps1')'; guyb -List" 2>&1) -join "`n"
    $ErrorActionPreference = 'Stop'
    $rows = @($mlist -split "`n" | Where-Object { $_ -match "`t" } | ForEach-Object { , ($_ -split "`t") })
    ExpectEq ml-rows $rows.Count 4
    ExpectEq ml-cols $rows[0].Count 7
    ExpectEq ml-dup-count @($rows | Where-Object { $_[0] -eq 'dup' }).Count 2
    ExpectEq ml-root-a (@($rows | Where-Object { $_[0] -eq 'a' })[0][6]) $r1
    ExpectEq ml-root-b (@($rows | Where-Object { $_[0] -eq 'b' })[0][6]) $r2
    ExpectHas ml-warn $warn 'root not found'
    ExpectHas ml-warn-entry $warn $gone
    $out = (guyb 'a' -Here) -join "`n"
    ExpectHas ml-open-a $out "cd '$(Join-Path $r1 'a')'"
    ExpectHas ml-open-b ((guyb 'b' -Here) -join "`n") "cd '$(Join-Path $r2 'b')'"
    $out = ''
    try { $out = (guyb 'dup' -Here) -join "`n" } catch { $out = "ERR: $($_.Exception.Message)" }
    ExpectHas ml-ambiguous $out 'Ambiguous project'
    ExpectHas ml-ambiguous-r1 $out (Join-Path $r1 'dup')
    ExpectHas ml-ambiguous-r2 $out (Join-Path $r2 'dup')
    ExpectLacks ml-ambiguous-launch $out 'here:'
    $out = ''
    try { $out = (guyb 'nosuch') -join "`n" } catch { $out = "ERR: $($_.Exception.Message)" }
    ExpectHas ml-nosuch $out 'Project not found: nosuch'
    ExpectHas ml-nosuch-roots $out 'roots:'
    $env:GUYB_ROOT = $gone
    $out = ''
    try { $out = (guyb -List) -join "`n" } catch { $out = "ERR: $($_.Exception.Message)" }
    ExpectHas ml-all-missing $out 'Root not found'

    # A folder that is itself a root, or GUYB_HOME, is not listed as a project.
    $env:GUYB_ROOT = (@($ml, $r1) -join $sep)
    $names = @((guyb -List) | ForEach-Object { ($_ -split "`t")[1] })
    ExpectEq ml-root-not-project ($names -contains $r1) $false
    ExpectEq ml-other-root-listed ($names -contains $r2) $true
    $env:GUYB_ROOT = $ml; $env:GUYB_HOME = $r2
    $names = @((guyb -List) | ForEach-Object { ($_ -split "`t")[1] })
    ExpectEq ml-home-not-project ($names -contains $r2) $false
    ExpectEq ml-home-sibling-listed ($names -contains $r1) $true
}
finally {
    $env:GUYB_HOME = $savedHome
    $env:GUYB_ROOT = $savedRoot; $env:GUYB_DRYRUN = $savedDry; $env:TERM = $savedTerm; $env:GUYB_TAB_ASCII = $savedAscii; $env:GUYB_TAB_NAME = $savedName
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "tabs.ps1: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -ne 0) { exit 1 }
