# Tests for the launcher tab features in scripts/launch.ps1: colour table, title sanitising, wt args, dry-run.
# Usage: pwsh -File tests/tabs.ps1 (or powershell -File). Launches nothing (GUYB_DRYRUN=1), needs no wt/claude/network;
# temp dir removed on exit. Bash twin: tabs.sh (keep the expected colour table identical).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('guyb-tabs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'proj\my app'), (Join-Path $tmp 'proj\guyb') | Out-Null
$savedRoot = $env:GUYB_ROOT; $savedDry = $env:GUYB_DRYRUN
$env:GUYB_DRYRUN = '1'; $env:GUYB_ROOT = Join-Path $tmp 'proj'
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
    ExpectHas wt-suppress $line '--suppressApplicationTitle'
    ExpectHas wt-color $line '--tabColor #61AFEF'
    ExpectHas wt-title $line '--title my app'
    ExpectHas wt-env $a[-1] 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE'
    ExpectEq wt-title-arg $a[($a.IndexOf('--title') + 1)] 'my app'
    $semi = @(_guyb_wt_args 'a;b' 'C:\x;y' 'pwsh.exe' 'PowerShell')
    ExpectEq wt-semicolon-title $semi[($semi.IndexOf('--title') + 1)] 'a\;b'
    ExpectEq wt-semicolon-dir $semi[($semi.IndexOf('--startingDirectory') + 1)] 'C:\x\;y'
    ExpectLacks wt-semicolon-cmd ($semi[-1] -replace '\;', '') '\;'
    $esc = @(_guyb_wt_args ('x' + [char]27 + 'y' + [char]7) 'C:\p' 'pwsh.exe' 'PowerShell')
    ExpectEq wt-clean-title $esc[($esc.IndexOf('--title') + 1)] 'xy'

    # Dry-run command lines.
    $out = (guyb 'my app' -Here) -join "`n"
    ExpectHas here-osc $out 'here: osc0 my app'
    ExpectHas here-env $out "CLAUDE_CODE_DISABLE_TERMINAL_TITLE='1'"
    $out = (guyb 'guyb') -join "`n"
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        ExpectHas wt-dry $out 'wt: -w 0 new-tab'
        ExpectHas wt-dry-suppress $out '--suppressApplicationTitle'
        ExpectHas wt-dry-color $out '--tabColor #61AFEF'
    }
    else {
        ExpectHas spawn-dry $out 'spawn: '
        ExpectHas spawn-osc $out '[char]27'
        ExpectHas spawn-env $out "CLAUDE_CODE_DISABLE_TERMINAL_TITLE='1'"
    }

    # -List is unaffected by the dry-run flag.
    $list = (guyb -List) -join "`n"
    ExpectHas list-guyb $list "guyb`t$(Join-Path $env:GUYB_ROOT 'guyb')"
    ExpectHas list-space $list 'my app'
    ExpectLacks list-no-dryrun $list 'here:'
}
finally {
    $env:GUYB_ROOT = $savedRoot; $env:GUYB_DRYRUN = $savedDry
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "tabs.ps1: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -ne 0) { exit 1 }
