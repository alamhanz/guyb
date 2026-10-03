# Smoke tests for the PowerShell helper scripts (brief.ps1, check.ps1, guard-secrets.ps1, guard-readonly.ps1).
# Works on Windows PowerShell 5.1 and PowerShell 7:   pwsh -File tests/smoke.ps1
# Builds throwaway git repos and a fake HOME in a temp dir (removed on exit); writes nothing in the repo,
# needs no network or secrets, and stubs gh. Each script runs in a child process of the same PowerShell edition.
# Bash twin: smoke.sh (keep the cases in sync).
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$isWin = ($env:OS -eq 'Windows_NT')
$ps = (Get-Process -Id $PID).Path
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('guyb-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$script:pass = 0; $script:fail = 0
function Ok { $script:pass++ }
function No($msg) { $script:fail++; Write-Host "FAIL: $msg" }
function Expect-Has($label, $text, $want) { if ($text.Contains($want)) { Ok } else { No "${label}: missing '$want'" } }
function Expect-Lacks($label, $text, $bad) { if ($text.Contains($bad)) { No "${label}: unexpected '$bad'" } else { Ok } }
function Expect-Eq($label, $got, $want) { if ("$got" -eq "$want") { Ok } else { No "${label}: got '$got', want '$want'" } }

function Write-File($path, $text) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Run-Child([string]$script, [string[]]$more, $stdin) {
  # returns @(exit code, combined output text); stderr lines are folded in as plain text
  $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $more
  if ($null -ne $stdin) { $raw = $stdin | & $ps @args2 2>&1 } else { $raw = & $ps @args2 2>&1 }
  $code = $LASTEXITCODE
  $text = (@($raw | ForEach-Object { "$_" }) -join "`n")
  return @($code, $text)
}
function Git-Quiet { & git @args *> $null }

try {
  # Fake HOME: no real profile, config, or git identity is read by the child scripts.
  $home2 = Join-Path $tmp 'home'
  New-Item -ItemType Directory -Force -Path (Join-Path $home2 '.claude') | Out-Null
  $env:HOME = $home2; $env:USERPROFILE = $home2
  Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
  $env:GIT_TERMINAL_PROMPT = '0'

  # Stub gh: `gh pr view N` prints $GH_STUB_STATE (default OPEN); everything else fails quietly.
  $stub = Join-Path $tmp 'stub'
  New-Item -ItemType Directory -Force -Path $stub | Out-Null
  if ($isWin) {
    Write-File (Join-Path $stub 'gh.cmd') ("@echo off`r`nif `"%1`"==`"pr`" if `"%2`"==`"view`" goto view`r`nexit /b 1`r`n:view`r`nif `"%GH_STUB_STATE%`"==`"`" (echo OPEN) else (echo %GH_STUB_STATE%)`r`nexit /b 0`r`n")
  } else {
    Write-File (Join-Path $stub 'gh') "#!/bin/sh`nif [ `"`$1`" = pr ] && [ `"`$2`" = view ]; then echo `"`${GH_STUB_STATE:-OPEN}`"; exit 0; fi`nexit 1`n"
    & chmod +x (Join-Path $stub 'gh')
  }
  $env:PATH = $stub + [System.IO.Path]::PathSeparator + $env:PATH

  function Make-Fixture($dir) {
    New-Item -ItemType Directory -Force -Path (Join-Path $dir '.claude') | Out-Null
    Git-Quiet -C $dir init -q
    Git-Quiet -C $dir config user.name smoke
    Git-Quiet -C $dir config user.email smoke@example.invalid
    Git-Quiet -C $dir config commit.gpgsign false
    Write-File (Join-Path $dir 'README.md') "# fixture`n"
    Write-File (Join-Path $dir '.claude/CLAUDE.md') "# fixture`r`n`r`nmax_parallel: 3`r`n"
    Write-File (Join-Path $dir '.claude/STATE.md') "# State`r`n`r`n## Next up`r`n- ship the thing`r`n`r`n## Open issues`r`n- PR #7 awaiting review`r`n- flaky test`r`n"
    Git-Quiet -C $dir add -A
    Git-Quiet -C $dir commit -q -m init
  }

  $a = Join-Path $tmp 'proj'; $b = Join-Path $tmp 'my proj [v2]'
  Make-Fixture $a; Make-Fixture $b

  $brief = Join-Path $root 'plugins/guyb/skills/start/brief.ps1'
  $check = Join-Path $root 'plugins/guyb/skills/setup/check.ps1'

  Write-Host 'brief.ps1 and check.ps1 on fixtures'
  foreach ($d in @($a, $b)) {
    $name = Split-Path -Leaf $d
    $r = Run-Child $brief @('-Dir', $d) $null
    Expect-Eq "brief $name exit" $r[0] 0
    Expect-Has "brief $name" $r[1] "project: $name"
    Expect-Has "brief $name" $r[1] 'branch: '
    Expect-Has "brief $name" $r[1] 'max parallel: 3 (project)'
    Expect-Has "brief $name" $r[1] 'STATE.md Next up:'
    Expect-Has "brief $name" $r[1] 'STATE.md Open issues:'
    Expect-Lacks "brief $name" $r[1] 'plugin: '
    $r = Run-Child $check @('-StartDir', $d) $null
    Expect-Eq "check $name exit" $r[0] 0
    $obj = $null
    try { $obj = $r[1] | ConvertFrom-Json } catch { }
    if ($obj -and $obj.version -eq 1) { Ok } else { No "check ${name}: output is not valid JSON with version 1" }
  }

  Write-Host 'brief.ps1 outdated plugin flag'
  $cfg = Join-Path $home2 '.claude/plugins'; $mk = Join-Path $tmp 'marketplace'
  Write-File (Join-Path $mk 'plugins/guyb/.claude-plugin/plugin.json') "{`"name`":`"guyb`",`"version`":`"0.7.0`"}`n"
  Write-File (Join-Path $cfg 'known_marketplaces.json') ("{`"guyb`":{`"source`":{`"source`":`"directory`",`"path`":`"" + $mk.Replace('\', '/') + "`"}}}`n")
  $want = 'plugin: 0.6.0 installed, 0.7.0 available - run: claude plugin marketplace update guyb; claude plugin update guyb@guyb'
  foreach ($v in @('0.6.0', '0.7.0', '0.8.0')) {
    Write-File (Join-Path $cfg 'installed_plugins.json') ("{`"version`":2,`"plugins`":{`"guyb@guyb`":[{`"scope`":`"user`",`"version`":`"$v`"}]}}`n")
    $r = Run-Child $brief @('-Dir', $a) $null
    if ($v -eq '0.6.0') { Expect-Has "plugin flag $v" $r[1] $want } else { Expect-Lacks "plugin flag $v" $r[1] 'plugin: ' }
  }
  Remove-Item -LiteralPath (Join-Path $cfg 'installed_plugins.json'), (Join-Path $cfg 'known_marketplaces.json') -Force

  Write-Host 'brief.ps1 STATE.md drift (stub gh)'
  $env:GH_STUB_STATE = 'MERGED'
  $r = Run-Child $brief @('-Dir', $a) $null
  Expect-Has 'drift MERGED' $r[1] 'STATE.md drift: PR #7 is MERGED - update STATE.md'
  $env:GH_STUB_STATE = 'OPEN'
  $r = Run-Child $brief @('-Dir', $a) $null
  Expect-Lacks 'drift OPEN' $r[1] 'STATE.md drift'
  Remove-Item Env:GH_STUB_STATE

  Write-Host 'guard-secrets.ps1'
  $g = Join-Path $tmp 'guarded'; Make-Fixture $g
  $guard = Join-Path $root 'plugins/guyb/hooks/guard-secrets.ps1'
  Write-File (Join-Path $g '.env') "KEY=value`n"
  Write-File (Join-Path $g '.env.example') "KEY=`n"
  Git-Quiet -C $g add .env
  Push-Location -LiteralPath $g
  try {
    $r = Run-Child $guard @() $null
    Expect-Eq 'guard staged .env exit' $r[0] 2
    Expect-Has 'guard staged .env' $r[1] '.env'
    Git-Quiet reset -q
    Git-Quiet add .env.example
    $r = Run-Child $guard @() $null
    Expect-Eq 'guard staged .env.example exit' $r[0] 0
  } finally { Pop-Location }
  Push-Location -LiteralPath $tmp
  try { $r = Run-Child $guard @() $null; Expect-Eq 'guard outside a repo exit' $r[0] 0 } finally { Pop-Location }

  Write-Host 'guard-readonly.ps1'
  $ro = Join-Path $root 'plugins/guyb/hooks/guard-readonly.ps1'
  function Hook($agent, $cmd) { (Run-Child $ro @() ('{"agent_type":"' + $agent + '","tool_name":"PowerShell","tool_input":{"command":"' + $cmd + '"}}'))[0] }
  Expect-Eq 'readonly reviewer git add' (Hook 'guyb:code-reviewer' 'git add .') 2
  Expect-Eq 'readonly bare architect git push' (Hook 'architect' 'git push origin main') 2
  Expect-Eq 'readonly reviewer git status' (Hook 'guyb:code-reviewer' 'git status') 0
  Expect-Eq 'readonly implementer git add' (Hook 'guyb:implementer' 'git add .') 0
  Expect-Eq 'readonly main session git add' (Run-Child $ro @() '{"tool_input":{"command":"git add ."}}')[0] 0
  Expect-Eq 'readonly bad json' (Run-Child $ro @() 'not json')[0] 0
} finally {
  Set-Location -LiteralPath $root
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "smoke: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
