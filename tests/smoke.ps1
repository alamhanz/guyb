# Smoke tests for the PowerShell helper scripts (brief.ps1, check.ps1, guard-secrets.ps1, guard-readonly.ps1).
# Works on Windows PowerShell 5.1 and PowerShell 7:   pwsh -File tests/smoke.ps1
# Builds throwaway git repos and a fake HOME in a temp dir (removed on exit); writes nothing in the repo,
# needs no network or secrets, and stubs gh. Each script runs in a child process of the same PowerShell edition.
# The independent groups of cases run as child processes of this script (-Group <name>, at most GUYB_TEST_JOBS at once,
# default 8), each with its own temp dir, fixtures and HOME; their output is replayed in order.
# Bash twin: smoke.sh (keep the cases in sync).
param([string]$Group = '')
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$isWin = ($env:OS -eq 'Windows_NT')
$ps = (Get-Process -Id $PID).Path
$jobsMax = if ($env:GUYB_TEST_JOBS) { [int]$env:GUYB_TEST_JOBS } else { 8 }

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
function Start-Proc([string]$exe, [string]$procArgs, [string]$stdin) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = $procArgs
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($stdin) # raw bytes: no BOM, whatever the console code page
  $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.Close()
  return [pscustomobject]@{ P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}
function Finish-Proc($h) { # exit code, then combined stdout+stderr text
  $h.P.WaitForExit()
  return [pscustomobject]@{ Code = $h.P.ExitCode; Text = ($h.Out.Result + $h.Err.Result) }
}

if (-not $Group) {
  # Orchestrator: one child process per group, slowest first (hung probes and the 5 s gh budget), at most $jobsMax at a time.
  # The timed groups (hung probes, 5 s gh budget) run first and alone: on a 2-core CI runner a full pool slows brief past their limits.
  $timed = 'docker', 'ghsleep'
  $groups = 'matrix', 'readonly', 'migration', 'env', 'check', 'cleanup_over', 'cleanup_under', 'overdue', 'formats', 'drift', 'guard', 'plugin', 'gitignore', 'emptysec', 'wrapper', 'connections'
  $running = New-Object System.Collections.ArrayList
  foreach ($g in $timed) { [void]$running.Add([pscustomobject]@{ Name = $g; H = (Start-Proc $ps ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Group ' + $g) '') }) }
  while (@($running | Where-Object { -not $_.H.P.HasExited }).Count -gt 0) { Start-Sleep -Milliseconds 200 }
  foreach ($g in $groups) {
    while (@($running | Where-Object { -not $_.H.P.HasExited }).Count -ge $jobsMax) { Start-Sleep -Milliseconds 200 }
    $h = Start-Proc $ps ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Group ' + $g) ''
    [void]$running.Add([pscustomobject]@{ Name = $g; H = $h })
  }
  foreach ($r in $running) {
    $res = Finish-Proc $r.H
    $seen = $false
    foreach ($line in @($res.Text -split "`r?`n")) {
      if ($line -match '^@@ (\d+) (\d+)$') { $seen = $true; $script:pass += [int]$Matches[1]; $script:fail += [int]$Matches[2] }
      elseif ($line) { Write-Host $line }
    }
    if (-not $seen) { No "group $($r.Name): no result (crashed?)" }
  }
  Write-Host "smoke: $($script:pass) passed, $($script:fail) failed"
  if ($script:fail -gt 0) { exit 1 }
  exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('guyb-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
  # Fake HOME: no real profile, config, or git identity is read by the child scripts.
  $home2 = Join-Path $tmp 'home'
  New-Item -ItemType Directory -Force -Path (Join-Path $home2 '.claude') | Out-Null
  $env:HOME = $home2; $env:USERPROFILE = $home2
  Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
  $env:GIT_TERMINAL_PROMPT = '0'

  # Stub gh. `pr list` prints the file named by GH_STUB_LISTFILE (tab-separated number, state, title, branch lines; exit 1 with GH_STUB_LISTFAIL);
  # GH_STUB_LISTRC makes `pr list` exit with that code (4 = not logged in); `pr view N` prints $GH_STUB_STATE (default OPEN); anything else fails quietly. GH_STUB_SLEEP (seconds) delays every call, GH_STUB_LOG records the arguments.
  $stub = Join-Path $tmp 'stub'
  New-Item -ItemType Directory -Force -Path $stub | Out-Null
  if ($isWin) {
    $cmdLines = @(
      '@echo off',
      'if not "%GH_STUB_LOG%"=="" echo %*>>"%GH_STUB_LOG%"',
      'if "%GH_STUB_SLEEP%"=="" goto go',
      'set /a gs=%GH_STUB_SLEEP%+1',
      'ping -n %gs% 127.0.0.1 >nul',
      ':go',
      'if "%1"=="pr" if "%2"=="list" goto list',
      'if "%1"=="pr" if "%2"=="view" goto view',
      'exit /b 1',
      ':list',
      'if not "%GH_STUB_LISTFAIL%"=="" exit /b 1',
      'if not "%GH_STUB_LISTRC%"=="" exit /b %GH_STUB_LISTRC%',
      'if not "%GH_STUB_LISTFILE%"=="" type "%GH_STUB_LISTFILE%"',
      'exit /b 0',
      ':view',
      'if "%GH_STUB_STATE%"=="" (echo OPEN) else (echo %GH_STUB_STATE%)',
      'exit /b 0')
    Write-File (Join-Path $stub 'gh.cmd') (($cmdLines -join "`r`n") + "`r`n")
  } else {
    $shLines = @(
      '#!/bin/sh',
      '[ -n "$GH_STUB_LOG" ] && echo "$*" >> "$GH_STUB_LOG"',
      '[ -n "$GH_STUB_SLEEP" ] && sleep "$GH_STUB_SLEEP"',
      'if [ "$1" = pr ] && [ "$2" = list ]; then',
      '  [ -n "$GH_STUB_LISTFAIL" ] && exit 1',
      '  [ -n "$GH_STUB_LISTRC" ] && exit "$GH_STUB_LISTRC"',
      '  [ -n "$GH_STUB_LISTFILE" ] && cat "$GH_STUB_LISTFILE"',
      '  exit 0',
      'fi',
      'if [ "$1" = pr ] && [ "$2" = view ]; then echo "${GH_STUB_STATE:-OPEN}"; exit 0; fi',
      'exit 1')
    Write-File (Join-Path $stub 'gh') (($shLines -join "`n") + "`n")
    & chmod +x (Join-Path $stub 'gh')
  }
  $env:PATH = $stub + [System.IO.Path]::PathSeparator + $env:PATH

  function Make-Fixture($dir) {
    New-Item -ItemType Directory -Force -Path (Join-Path $dir '.claude/guyb') | Out-Null
    Git-Quiet -C $dir init -q
    Git-Quiet -C $dir config user.name smoke
    Git-Quiet -C $dir config user.email smoke@example.invalid
    Git-Quiet -C $dir config commit.gpgsign false
    Write-File (Join-Path $dir 'README.md') "# fixture`n"
    Write-File (Join-Path $dir '.claude/CLAUDE.md') "# fixture`r`n`r`nmax_parallel: 3`r`n"
    Write-File (Join-Path $dir '.claude/guyb/STATE.md') "# State`r`n`r`n## Next up`r`n- ship the thing`r`n`r`n## Open issues`r`n- PR #7 awaiting review`r`n- flaky test`r`n"
    Git-Quiet -C $dir add -A
    Git-Quiet -C $dir commit -q -m init
  }

  $brief = Join-Path $root 'plugins/guyb/skills/start/brief.ps1'
  $check = Join-Path $root 'plugins/guyb/skills/setup/check.ps1'
  $runsHead = "| ID | Agent | Model | Task | Wave | After | Status | Started | Tokens |`r`n|---|---|---|---|---|---|---|---|---|`r`n"
  $today = (Get-Date).ToString('yyyy-MM-dd')
  $guybOld = "# State`r`n`r`n## Next up`r`n- legacy next`r`n`r`n## Open issues`r`n- legacy issue`r`n`r`n## Decisions`r`n- d`r`n`r`n## Recent changes`r`n- c`r`n"
  $guybNew = "<!-- guyb:state -->`r`n# State`r`n`r`n## Next up`r`n- new next`r`n"
  $foreign = "# Notes from another tool`r`n`r`nnothing to do with guyb`r`n"
  function Lines($n, $prefix) { (@(1..$n | ForEach-Object { "$prefix $_" }) -join "`n") + "`n" }
  function Age($path) { (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-30) }
  function Make-Big($dir, $over) {
    $d = if ($over) { 1 } else { 0 }
    Write-File (Join-Path $dir '.claude/CLAUDE.md') (Lines (200 + $d) 'line')
    Write-File (Join-Path $dir '.claude/guyb/STATE.md') ("## Next up`n" + (Lines (299 + $d) 'line'))
    $rr = $runsHead; for ($i = 1; $i -le 200 + $d; $i++) { $st = 'done'; if ($i -eq 2) { $st = 'running' }; $rr += "| x-$i | implementer | sonnet | t | 1 | - | $st | $today | - |`r`n" }
    Write-File (Join-Path $dir '.claude/guyb/pipeline/runs.md') $rr
    $qq = "| ID | Run | Question | Blocking | Assumed | Status |`r`n|---|---|---|---|---|---|`r`n"; for ($i = 1; $i -le 200 + $d; $i++) { $qq += "| Q$i | x-1 | q | no | a | answered |`r`n" }
    Write-File (Join-Path $dir '.claude/guyb/pipeline/questions.md') $qq
  }
  function Snapshot($dir) { (@(Get-ChildItem -LiteralPath $dir -Recurse -Force | Where-Object { -not $_.PSIsContainer -and $_.FullName -notmatch '[\\/]\.git([\\/]|$)' } | ForEach-Object { "$($_.FullName) $($_.Length) $($_.LastWriteTime.Ticks)" } | Sort-Object) -join "`n") + "`n" + $(if (Test-Path -LiteralPath (Join-Path $dir '.git')) { (& git -C $dir status --short) -join "`n" }) }
  $sep = [System.IO.Path]::PathSeparator
  function Make-Docker-Stub($name, $body) {
    # stub docker that runs $body (sh on Unix, batch on Windows); returns the stub dir
    $dd = Join-Path $tmp $name
    New-Item -ItemType Directory -Force -Path $dd | Out-Null
    if ($isWin) { Write-File (Join-Path $dd 'docker.cmd') ("@echo off`r`n" + $body.Win + "`r`n") }
    else { Write-File (Join-Path $dd 'docker') ("#!/bin/sh`n" + $body.Sh + "`n"); & chmod +x (Join-Path $dd 'docker') }
    return $dd
  }
  function Gh-Calls($log, $pattern) { @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Where-Object { $_ -match $pattern }).Count }

  switch ($Group) {
    'matrix' {
      Write-Host 'brief.ps1 and check.ps1 on fixtures'
      $a = Join-Path $tmp 'proj'; $b = Join-Path $tmp 'my proj [v2]'
      Make-Fixture $a; Make-Fixture $b
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
    }

    'plugin' {
      Write-Host 'brief.ps1 outdated plugin flag'
      $a = Join-Path $tmp 'f-plug'; Make-Fixture $a
      $cfg = Join-Path $home2 '.claude/plugins'; $mk = Join-Path $tmp 'marketplace'
      Write-File (Join-Path $mk 'plugins/guyb/.claude-plugin/plugin.json') "{`"name`":`"guyb`",`"version`":`"0.7.0`"}`n"
      Write-File (Join-Path $cfg 'known_marketplaces.json') ("{`"guyb`":{`"source`":{`"source`":`"directory`",`"path`":`"" + $mk.Replace('\', '/') + "`"}}}`n")
      $want = 'plugin: 0.6.0 installed, 0.7.0 available - run: claude plugin marketplace update guyb; claude plugin update guyb@guyb'
      foreach ($v in @('0.6.0', '0.7.0', '0.8.0')) {
        Write-File (Join-Path $cfg 'installed_plugins.json') ("{`"version`":2,`"plugins`":{`"guyb@guyb`":[{`"scope`":`"user`",`"version`":`"$v`"}]}}`n")
        $r = Run-Child $brief @('-Dir', $a) $null
        if ($v -eq '0.6.0') { Expect-Has "plugin flag $v" $r[1] $want } else { Expect-Lacks "plugin flag $v" $r[1] 'plugin: ' }
      }
    }

    'drift' {
      Write-Host 'brief.ps1 STATE.md drift (stub gh)'
      $a = Join-Path $tmp 'f-drift'; Make-Fixture $a
      $drift7 = 'STATE.md drift: PR #7 is MERGED - update STATE.md'
      $env:GH_STUB_STATE = 'MERGED'
      $r = Run-Child $brief @('-Dir', $a) $null
      Expect-Has 'drift MERGED' $r[1] $drift7
      $env:GH_STUB_STATE = 'OPEN'
      $r = Run-Child $brief @('-Dir', $a) $null
      Expect-Lacks 'drift OPEN' $r[1] 'STATE.md drift'
      # state from the PR list: no `gh pr view` call, only open PRs printed (first 5, shape "number | title | branch")
      $lf = Join-Path $tmp 'list.tsv'; $lg = Join-Path $tmp 'gh.log'
      Write-File $lf ("9`tOPEN`tadd widget`tfeat/widget`n7`tMERGED`tship it`tfix/ship`n3`tCLOSED`told`told`n2`tOPEN`tsecond`tfeat/second`n")
      Write-File $lg ''
      $env:GH_STUB_LISTFILE = $lf; $env:GH_STUB_LOG = $lg; $env:GH_STUB_STATE = 'OPEN'
      $r = Run-Child $brief @('-Dir', $a) $null
      Expect-Has 'drift from list' $r[1] $drift7
      Expect-Eq 'drift from list: no pr view' (Gh-Calls $lg 'pr view') 0
      Expect-Eq 'list call made once' (Gh-Calls $lg 'pr list') 1
      Expect-Has 'open PRs header' $r[1] 'open PRs:'
      Expect-Has 'open PR line' $r[1] '  9 | add widget | feat/widget'
      Expect-Has 'open PR line' $r[1] '  2 | second | feat/second'
      Expect-Lacks 'merged PR not listed as open' $r[1] 'ship it'
      Expect-Lacks 'closed PR not listed as open' $r[1] '| old'
      # PR named in STATE.md but not among the listed ones: one `pr view`
      Write-File $lf ("9`tOPEN`tadd widget`tfeat/widget`n")
      Write-File $lg ''
      $env:GH_STUB_STATE = 'MERGED'
      $r = Run-Child $brief @('-Dir', $a) $null
      Expect-Has 'drift view fallback' $r[1] $drift7
      Expect-Eq 'drift view fallback: one pr view' (Gh-Calls $lg 'pr view 7') 1
      # list call failing (not logged in): no PR lines, drift falls back to pr view
      Remove-Item Env:GH_STUB_LISTFILE, Env:GH_STUB_LOG
      $env:GH_STUB_LISTFAIL = '1'
      $r = Run-Child $brief @('-Dir', $a) $null
      Expect-Has 'drift after failed list' $r[1] $drift7
      Expect-Lacks 'failed list prints no PRs' $r[1] 'open PRs:'
    }

    'ghsleep' {
      Write-Host 'brief.ps1 hung gh'
      $a = Join-Path $tmp 'f-sleep'; Make-Fixture $a
      $lf = Join-Path $tmp 'list.tsv'; $lg = Join-Path $tmp 'gh.log'
      Write-File $lf ("7`tMERGED`tship it`tfix/ship`n9`tOPEN`tadd widget`tfeat/widget`n")
      Write-File $lg ''
      $env:GH_STUB_LISTFILE = $lf; $env:GH_STUB_LOG = $lg; $env:GH_STUB_SLEEP = '8'
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $r = Run-Child $brief @('-Dir', $a) $null
      $sw.Stop()
      if ($sw.Elapsed.TotalSeconds -lt 10) { Ok } else { No "hung gh: brief took $([int]$sw.Elapsed.TotalSeconds)s" }
      Expect-Lacks 'hung gh no PR lines' $r[1] 'open PRs:'
      Expect-Lacks 'hung gh no drift' $r[1] 'STATE.md drift'
      Expect-Has 'hung gh rest of the brief' $r[1] 'STATE.md Next up:'
      Expect-Eq 'hung gh: only the list call' (Gh-Calls $lg 'pr view') 0
    }

    'migration' {
      Write-Host 'brief.ps1 migration (legacy, new, both, foreign STATE.md)'
      $m1 = Join-Path $tmp 'mig-legacy'; New-Item -ItemType Directory -Force -Path $m1 | Out-Null
      Write-File (Join-Path $m1 '.claude/STATE.md') $guybOld
      Write-File (Join-Path $m1 '.claude/pipeline/runs.md') ($runsHead + "| old-1 | implementer | sonnet | legacy task | 1 | - | running | $today | - |`r`n")
      $r = Run-Child $brief @('-Dir', $m1) $null
      Expect-Has 'migrate legacy' $r[1] 'migrate: move .claude/STATE.md, .claude/pipeline/ to .claude/guyb/'
      Expect-Has 'migrate legacy' $r[1] '- legacy next'
      Expect-Has 'migrate legacy' $r[1] 'unfinished runs (1):'
      $m2 = Join-Path $tmp 'mig-new'; New-Item -ItemType Directory -Force -Path $m2 | Out-Null
      Write-File (Join-Path $m2 '.claude/guyb/STATE.md') $guybNew
      Write-File (Join-Path $m2 '.claude/guyb/pipeline/runs.md') $runsHead
      $r = Run-Child $brief @('-Dir', $m2) $null
      Expect-Lacks 'migrate new' $r[1] 'migrate:'
      Expect-Has 'migrate new' $r[1] '- new next'
      $m3 = Join-Path $tmp 'mig-both'; New-Item -ItemType Directory -Force -Path $m3 | Out-Null
      Write-File (Join-Path $m3 '.claude/STATE.md') $guybOld
      Write-File (Join-Path $m3 '.claude/guyb/STATE.md') $guybNew
      Write-File (Join-Path $m3 '.claude/pipeline/runs.md') $runsHead
      Write-File (Join-Path $m3 '.claude/guyb/pipeline/runs.md') $runsHead
      $r = Run-Child $brief @('-Dir', $m3) $null
      Expect-Has 'migrate both' $r[1] 'migrate: conflict: .claude/STATE.md and .claude/guyb/STATE.md both exist; conflict: .claude/pipeline/ and .claude/guyb/pipeline/ both exist'
      Expect-Has 'migrate both' $r[1] '- new next'
      Expect-Lacks 'migrate both' $r[1] '- legacy next'
      $m4 = Join-Path $tmp 'mig-marker'; New-Item -ItemType Directory -Force -Path $m4 | Out-Null
      Write-File (Join-Path $m4 '.claude/STATE.md') $guybNew
      $r = Run-Child $brief @('-Dir', $m4) $null
      Expect-Has 'migrate marker' $r[1] 'migrate: move .claude/STATE.md to .claude/guyb/'
      Expect-Has 'migrate marker' $r[1] '- new next'
      $shapes = @{
        'mig-titlecase' = "# State`r`n`r`n## Next Up`r`n- tc next`r`n`r`n## Open Issues`r`n- i`r`n`r`n### Decisions`r`n- d`r`n`r`n## Recent Changes`r`n- c`r`n## Last Updated`r`n2026-01-01`r`n";
        'mig-bom' = ([string][char]0xFEFF) + "<!-- guyb:state -->`r`n# State`r`n- bom next`r`n";
        'mig-three' = "# Notes`r`n## Next up`r`n- x`r`n## Open issues`r`n- y`r`n## Decisions`r`n- z`r`n" }
      foreach ($k in $shapes.Keys) { Write-File (Join-Path $tmp "$k/.claude/STATE.md") $shapes[$k] }
      $r = Run-Child $brief @('-Dir', (Join-Path $tmp 'mig-titlecase')) $null
      Expect-Has 'migrate title case' $r[1] 'migrate: move .claude/STATE.md to .claude/guyb/'
      $r = Run-Child $brief @('-Dir', (Join-Path $tmp 'mig-bom')) $null
      Expect-Has 'migrate BOM marker' $r[1] 'migrate: move .claude/STATE.md to .claude/guyb/'
      $r = Run-Child $brief @('-Dir', (Join-Path $tmp 'mig-three')) $null
      Expect-Lacks 'migrate three headings' $r[1] 'migrate:'
      Expect-Has 'migrate three headings' $r[1] 'STATE.md: missing'
      $m5 = Join-Path $tmp 'mig-foreign'; New-Item -ItemType Directory -Force -Path $m5 | Out-Null
      Write-File (Join-Path $m5 '.claude/STATE.md') $foreign
      $r = Run-Child $brief @('-Dir', $m5) $null
      Expect-Lacks 'migrate foreign' $r[1] 'migrate:'
      Expect-Has 'migrate foreign' $r[1] 'STATE.md: missing'
      Write-File (Join-Path $m5 '.claude/guyb/STATE.md') $guybNew
      $r = Run-Child $brief @('-Dir', $m5) $null
      Expect-Lacks 'migrate foreign + new' $r[1] 'migrate:'
      Expect-Has 'migrate foreign + new' $r[1] '- new next'
      Write-Host 'brief.ps1 leaves the fixture unchanged (legacy migration)'
      $before = Snapshot $m1
      $null = Run-Child $brief @('-Dir', $m1) $null
      Expect-Eq "read-only $(Split-Path -Leaf $m1)" (Snapshot $m1) $before
    }

    'emptysec' {
      Write-Host 'brief.ps1 empty section, question rows'
      $ep = Join-Path $tmp 'empty-sec'; New-Item -ItemType Directory -Force -Path (Join-Path $ep '.claude/guyb/pipeline') | Out-Null
      Write-File (Join-Path $ep '.claude/guyb/STATE.md') "# Next up`r`n`r`n# Open issues`r`n- one`r`n"
      Write-File (Join-Path $ep '.claude/guyb/pipeline/questions.md') "| Q | Question | Run | Status |`r`n|---|---|---|---|`r`n| Q1 | what | me | open |`r`n| Q2 | a |  | open |`r`n"
      $r = Run-Child $brief @('-Dir', $ep) $null
      Expect-Lacks 'empty section heading' $r[1] 'STATE.md Next up:'
      Expect-Has 'empty section heading' $r[1] 'STATE.md Open issues:'
      Expect-Has 'question row' $r[1] '  Q1 | what | me | open'
    }

    'gitignore' {
      Write-Host 'brief.ps1 gitignore check'
      $gi = Join-Path $tmp 'gi'; Make-Fixture $gi
      $r = Run-Child $brief @('-Dir', $gi) $null
      Expect-Has 'gitignore absent' $r[1] 'gitignore: .claude/guyb/pipeline/ not ignored'
      Write-File (Join-Path $gi '.gitignore') ".claude/guyb/pipeline/`n"
      $r = Run-Child $brief @('-Dir', $gi) $null
      Expect-Lacks 'gitignore new path' $r[1] 'gitignore:'
      Expect-Lacks 'gitignore new path' $r[1] 'warn:'
      Write-File (Join-Path $gi '.gitignore') ".claude/pipeline/`n"
      $r = Run-Child $brief @('-Dir', $gi) $null
      Expect-Has 'gitignore legacy line, no legacy pipeline dir' $r[1] 'gitignore: .claude/guyb/pipeline/ not ignored'
      Write-File (Join-Path $gi '.claude/pipeline/runs.md') $runsHead
      $r = Run-Child $brief @('-Dir', $gi) $null
      Expect-Lacks 'gitignore legacy line, legacy pipeline' $r[1] 'gitignore:'
      Write-File (Join-Path $gi '.gitignore') ".claude/`n"
      $r = Run-Child $brief @('-Dir', $gi) $null
      Expect-Lacks 'gitignore whole .claude' $r[1] 'gitignore:'
      Expect-Has 'gitignore whole .claude' $r[1] 'warn: .gitignore ignores .claude/ - guyb STATE.md will not be committed'
      Write-File (Join-Path $gi '.gitignore') ".Claude/pipeline/`n"
      $r = Run-Child $brief @('-Dir', $gi) $null
      Expect-Has 'gitignore is case-sensitive' $r[1] 'gitignore: .claude/guyb/pipeline/ not ignored'
      Write-Host 'brief.ps1 leaves the fixture unchanged (gitignore)'
      $before = Snapshot $gi
      $null = Run-Child $brief @('-Dir', $gi) $null
      Expect-Eq "read-only $(Split-Path -Leaf $gi)" (Snapshot $gi) $before
    }

    'cleanup_over' {
      Write-Host 'brief.ps1 cleanup: over limits'
      $c1 = Join-Path $tmp 'clean-over'; Make-Fixture $c1; Make-Big $c1 $true
      Write-File (Join-Path $c1 '.claude/guyb/pipeline/progress/x-1.md') "p`n"
      Write-File (Join-Path $c1 '.claude/guyb/pipeline/progress/x-2.md') "p`n"
      Write-File (Join-Path $c1 '.claude/guyb/pipeline/progress/x-3.md') "p`n"
      Write-File (Join-Path $c1 '.claude/guyb/pipeline/brand/x-1/a.svg') "<svg/>`n"
      foreach ($f in 'progress/x-1.md', 'progress/x-2.md', 'brand/x-1/a.svg') { Age (Join-Path $c1 (".claude/guyb/pipeline/" + $f)) }
      $r = Run-Child $brief @('-Dir', $c1) $null
      Expect-Has 'cleanup over' $r[1] 'cleanup: CLAUDE.md 201 lines (>200); STATE.md 301 lines (>300); runs.md 201 rows (>200); questions.md 201 rows (>200); 2 pipeline files older than 14 days'
      Write-Host 'brief.ps1 leaves the fixture unchanged (cleanup)'
      $before = Snapshot $c1
      $null = Run-Child $brief @('-Dir', $c1) $null
      Expect-Eq "read-only $(Split-Path -Leaf $c1)" (Snapshot $c1) $before
    }

    'cleanup_under' {
      Write-Host 'brief.ps1 cleanup: under limits and overrides'
      $c2 = Join-Path $tmp 'clean-under'; Make-Fixture $c2; Make-Big $c2 $false
      Write-File (Join-Path $c2 '.claude/guyb/pipeline/progress/x-3.md') "p`n"
      $r = Run-Child $brief @('-Dir', $c2) $null
      Expect-Lacks 'cleanup under' $r[1] 'cleanup:'
      Expect-Lacks 'cleanup under' $r[1] 'overdue:'
      Write-File (Join-Path $c2 '.claude/CLAUDE.md') ("cleanup_rows: 5`ncleanup_days: 0`ncleanup_state_lines: abc`n" + (Lines 3 'line'))
      $r = Run-Child $brief @('-Dir', $c2) $null
      Expect-Has 'cleanup limit overrides' $r[1] 'cleanup: runs.md 200 rows (>5); questions.md 200 rows (>5)'
    }

    'overdue' {
      Write-Host 'brief.ps1 overdue items'
      $c3 = Join-Path $tmp 'clean-overdue'; Make-Fixture $c3
      $rr = $runsHead; for ($i = 1; $i -le 7; $i++) { $rr += "| od-$i | implementer | sonnet | t | 1 | - | queued | 2020-01-0$i 10:00 | - |`r`n" }
      $rr += "| od-8 | implementer | sonnet | t | 1 | - | done | 2020-01-01 | - |`r`n| od-9 | implementer | sonnet | t | 1 | - | running | $today | - |`r`n"
      Write-File (Join-Path $c3 '.claude/guyb/pipeline/runs.md') $rr
      Write-File (Join-Path $c3 '.claude/guyb/pipeline/questions.md') ("| ID | Run | Question | Blocking | Assumed | Status |`r`n|---|---|---|---|---|---|`r`n| Q1 | od-1 | q | no | a | open |`r`n| Q2 | od-9 | q | no | a | open |`r`n")
      $r = Run-Child $brief @('-Dir', $c3) $null
      Expect-Has 'overdue' $r[1] 'overdue: od-1, od-2, od-3, od-4, od-5, +3 more'
      Remove-Item -LiteralPath (Join-Path $c3 '.claude/guyb/pipeline/runs.md')
      Write-File (Join-Path $c3 '.claude/guyb/pipeline/runs.md') ($runsHead + "| od-1 | implementer | sonnet | t | 1 | - | blocked | 2020-01-01 | - |`r`n")
      $r = Run-Child $brief @('-Dir', $c3) $null
      Expect-Has 'overdue run and question' $r[1] 'overdue: od-1, Q1'
    }

    'formats' {
      Write-Host 'brief.ps1 registry formats and run ids'
      $c4 = Join-Path $tmp 'clean-formats'; Make-Fixture $c4
      $r6 = $runsHead + "| mien-dev-3 | i | s | t | 1 | - | running | 2020-01-01 | - |`r`n| r-6b | i | s | t | 1 | - | running | $today | - |`r`n| bad id | i | s | t | 1 | - | running | 2020-01-01 | - |`r`n| r-9 | i | s | t | 1 | - | running | $today | |`r`n"
      Write-File (Join-Path $c4 '.claude/guyb/pipeline/runs.md') $r6
      Write-File (Join-Path $c4 '.claude/guyb/pipeline/questions.md') ("| Q | Run | Agent | Question | Blocking | Assumed | Status | Answer |`r`n|---|---|---|---|---|---|---|---|`r`n| Q7 | mien-dev-3 | a | q | no | x | open | |`r`n")
      Write-File (Join-Path $c4 '.claude/guyb/pipeline/progress/r-6b.md') "p`n"
      Write-File (Join-Path $c4 '.claude/guyb/pipeline/progress/r-6c.md') "p`n"
      Write-File (Join-Path $c4 '.claude/guyb/pipeline/plans/mien-dev-3-logos.html') "p`n"
      foreach ($f in 'progress/r-6b.md', 'progress/r-6c.md', 'plans/mien-dev-3-logos.html') { Age (Join-Path $c4 ('.claude/guyb/pipeline/' + $f)) }
      $r = Run-Child $brief @('-Dir', $c4) $null
      Expect-Has 'formats Q/Run/Agent header' $r[1] 'overdue: mien-dev-3, Q7'
      Expect-Has 'formats empty last cell' $r[1] "  r-9 | i | s | t | 1 | - | running | $today | "
      Expect-Has 'formats stale' $r[1] 'cleanup: 1 pipeline files older than 14 days'
      Write-File (Join-Path $c4 '.claude/guyb/pipeline/questions.md') ("| ID | Run | Question | Blocking | Assumed | Status |`r`n|---|---|---|---|---|---|`r`n| Q7 | mien-dev-3 | q | no | x | open |`r`n")
      $r = Run-Child $brief @('-Dir', $c4) $null
      Expect-Has 'formats ID header' $r[1] 'overdue: mien-dev-3, Q7'
    }

    'env' {
      Write-Host 'brief.ps1 env: lines'
      $e1 = Join-Path $tmp 'env-py'; Write-File (Join-Path $e1 '.python-version') "99.1`r`n"
      $r = Run-Child $brief @('-Dir', $e1) $null
      Expect-Has 'env python' $r[1] 'env: python wants 99.1 (.python-version), '
      Expect-Has 'env python' $r[1] 'python .venv missing'
      $e2 = Join-Path $tmp 'env-node'
      Write-File (Join-Path $e2 'package.json') "{`"name`":`"x`"}`n"; Write-File (Join-Path $e2 'pnpm-lock.yaml') "lockfileVersion: 9`n"
      $r = Run-Child $brief @('-Dir', $e2) $null
      Expect-Has 'env node' $r[1] 'node_modules missing (pnpm)'
      $e0 = Join-Path $tmp 'env-empty'; New-Item -ItemType Directory -Force -Path $e0 | Out-Null
      $r = Run-Child $brief @('-Dir', $e0) $null
      Expect-Lacks 'env empty' $r[1] 'env:'
    }

    'docker' {
      Write-Host 'brief.ps1 env: docker probes'
      $e3 = Join-Path $tmp 'env-docker'; Write-File (Join-Path $e3 'compose.yaml') "services: {}`n"
      $oldPath = $env:PATH
      try {
        $env:PATH = (Make-Docker-Stub 'stub-docker-sleep' @{ Win = 'ping -n 16 127.0.0.1 >nul'; Sh = 'sleep 15' }) + $sep + $oldPath
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Run-Child $brief @('-Dir', $e3) $null
        $sw.Stop()
        Expect-Has 'env docker sleeping stub' $r[1] 'env: docker daemon not responding (compose.yaml)'
        if ($sw.Elapsed.TotalSeconds -lt 10) { Ok } else { No "env docker sleeping stub: brief took $([int]$sw.Elapsed.TotalSeconds)s" }
        $env:PATH = (Make-Docker-Stub 'stub-docker-fail' @{ Win = 'exit /b 1'; Sh = 'exit 1' }) + $sep + $oldPath
        $r = Run-Child $brief @('-Dir', $e3) $null
        Expect-Has 'env docker failing stub' $r[1] 'env: docker daemon not running (compose.yaml)'
      } finally { $env:PATH = $oldPath }
    }

    'check' {
      Write-Host 'check.ps1 toolchain ids'
      $e0 = Join-Path $tmp 'env-empty'; New-Item -ItemType Directory -Force -Path $e0 | Out-Null
      $oldPath = $env:PATH
      $r = Run-Child $check @('-StartDir', $e0) $null
      $obj = $null
      try { $obj = $r[1] | ConvertFrom-Json } catch { }
      foreach ($id in 'container', 'python', 'node', 'uv') {
        $c = $null
        if ($obj) { $c = @($obj.checks | Where-Object { $_.id -eq $id })[0] }
        if ($c -and $c.blocking -eq $false -and $c.fixBy -ne $null) { Ok } else { No "check toolchain: missing or blocking id '$id'" }
      }
      $cr = Join-Path $tmp 'ctr-root'; Write-File (Join-Path $cr 'app/Dockerfile') "FROM scratch`n"
      $noDocker = @($oldPath -split [regex]::Escape([string]$sep) | Where-Object { $_ -and -not (Test-Path -path (Join-Path $_ 'docker*')) -and -not (Test-Path -path (Join-Path $_ 'podman*')) }) -join $sep
      $oldRoot = $env:GUYB_ROOT
      try {
        $env:PATH = $noDocker; $env:GUYB_ROOT = $cr
        $r = Run-Child $check @('-StartDir', $cr) $null
      } finally { $env:PATH = $oldPath; if ($null -eq $oldRoot) { Remove-Item Env:GUYB_ROOT -ErrorAction SilentlyContinue } else { $env:GUYB_ROOT = $oldRoot } }
      $obj = $null
      try { $obj = $r[1] | ConvertFrom-Json } catch { }
      $c = $null
      if ($obj) { $c = @($obj.checks | Where-Object { $_.id -eq 'container' })[0] }
      if ($c -and $c.status -eq 'warn' -and $c.fix -match 'install|brew|winget') { Ok } else { No "check container without docker: want warn with install hint, got '$($c.status) $($c.fix)'" }
    }

    'guard' {
      Write-Host 'guard-secrets.ps1'
      $g = Join-Path $tmp 'guarded'; Make-Fixture $g
      $guard = Join-Path $root 'plugins/guyb/hooks/guard-secrets.ps1'
      Write-File (Join-Path $g '.env') "KEY=value`n"
      Write-File (Join-Path $g '.env.example') "KEY=`n"
      Git-Quiet -C $g add .env
      Push-Location -LiteralPath $g
      try {
        $r = Run-Child $guard @() ''
        Expect-Eq 'guard staged .env exit' $r[0] 2
        Expect-Has 'guard staged .env' $r[1] '.env'
        Git-Quiet reset -q
        Git-Quiet add .env.example
        $r = Run-Child $guard @() ''
        Expect-Eq 'guard staged .env.example exit' $r[0] 0
      } finally { Pop-Location }
      Push-Location -LiteralPath $tmp
      try { $r = Run-Child $guard @() ''; Expect-Eq 'guard outside a repo exit' $r[0] 0 } finally { Pop-Location }
      function SG($cmd) { (Run-Child $guard @() (@{ cwd = $g; tool_input = @{ command = $cmd } } | ConvertTo-Json -Compress))[0] }
      Git-Quiet -C $g reset -q
      Expect-Eq 'guard untracked .env, plain commit' (SG 'git commit -m x') 0
      Expect-Eq 'guard add -A ; commit, untracked .env' (SG 'git add -A ; git commit -m x') 2
      Expect-Eq 'guard git stage then commit, untracked .env' (SG 'git stage .env; git commit -m x') 2
      Git-Quiet -C $g add .env
      Expect-Eq 'guard assignment git commit, staged .env' (SG '$out = git commit -m x') 2
      Expect-Eq 'guard if block git commit, staged .env' (SG 'if ($?) { git commit -m x }') 2
      Expect-Eq 'guard call operator, staged .env' (SG '& git commit -m x') 2
      Expect-Eq 'guard uppercase GIT commit, staged .env' (SG 'GIT commit -m x') 2
      Expect-Eq 'guard subshell cd then commit, staged .env' (SG "(cd '$tmp'); git commit -m x") 2
      Expect-Eq 'guard --git-dir missing falls back to cwd' (SG "git --git-dir='$tmp/nogit' commit -m x") 2
      Git-Quiet -C $g reset -q
      Expect-Eq 'guard assignment git commit, nothing staged' (SG '$out = git commit -m x') 0
    }

    'readonly' {
      Write-Host 'guard-readonly.ps1 (tests/readonly-cases.tsv)'
      $ro = Join-Path $root 'plugins/guyb/hooks/guard-readonly.ps1'
      function Run-Batch($jobs) { # jobs: objects with Exe, Args, Stdin; returns results in order, $jobsMax at a time
        # .NET Framework (PS 5.1) wraps child stdin in a writer using Console.InputEncoding with AutoFlush on,
        # which writes a UTF-8 BOM at Process.Start; a BOM-less input encoding keeps child stdin clean.
        $ie = [Console]::InputEncoding
        try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
        try {
          $res = @()
          for ($i = 0; $i -lt $jobs.Count; $i += $jobsMax) {
            $hs = @()
            for ($j = $i; $j -lt [Math]::Min($i + $jobsMax, $jobs.Count); $j++) { $hs += , (Start-Proc $jobs[$j].Exe $jobs[$j].Args $jobs[$j].Stdin) }
            foreach ($h in $hs) { $res += , (Finish-Proc $h) }
          }
          return $res
        } finally { try { [Console]::InputEncoding = $ie } catch { } }
      }
      $ar = Join-Path $tmp 'aliasrepo'
      New-Item -ItemType Directory -Force -Path $ar | Out-Null
      Git-Quiet -C $ar init -q
      Git-Quiet -C $ar config alias.st status
      Git-Quiet -C $ar config alias.ci commit
      Git-Quiet -C $ar config alias.c2 ci
      Git-Quiet -C $ar config alias.sh '!echo hi'
      Git-Quiet -C $ar config alias.la lb
      Git-Quiet -C $ar config alias.lb la
      $nr = Join-Path $tmp 'norepo'
      New-Item -ItemType Directory -Force -Path $nr | Out-Null
      $arJson = $ar.Replace('\', '\\')
      $nrJson = $nr.Replace('\', '\\')

      $lines = [System.IO.File]::ReadAllText((Join-Path $root 'tests/readonly-cases.tsv')).Replace("`r", '').Split("`n")
      $rows = @()
      for ($i = 1; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i]) { continue }
        $f = $lines[$i].Split("`t")
        if ($f[1] -ne 'both' -and $f[1] -ne 'ps') { continue }
        $fields = ''
        if ($f[2] -ne '-') { $fields += '"agent_type":"' + $f[2] + '",' }
        if ($f[3] -eq 'norepo') { $fields += '"cwd":"' + $nrJson + '",' }
        elseif ($f[3] -ne '-') { $fields += '"cwd":"' + $arJson + '",' }
        $rows += [pscustomobject]@{
          Expect = $f[0]; Cmd = $f[4]; Label = $f[5] + ': ' + $f[4]
          Job = [pscustomobject]@{ Exe = $ps; Args = ('-NoProfile -ExecutionPolicy Bypass -File "' + $ro + '"'); Stdin = ('{' + $fields + '"tool_name":"PowerShell","tool_input":{"command":"' + $f[4] + '"}}') }
        }
      }
      $res = Run-Batch @($rows | ForEach-Object { $_.Job })
      for ($i = 0; $i -lt $rows.Count; $i++) { Expect-Eq ('readonly ' + $rows[$i].Label) $res[$i].Code $rows[$i].Expect }
      $bad = Run-Batch @([pscustomobject]@{ Exe = $ps; Args = ('-NoProfile -ExecutionPolicy Bypass -File "' + $ro + '"'); Stdin = 'not json' })
      Expect-Eq 'readonly bad json' $bad[0].Code 0
      $emp = Run-Batch @([pscustomobject]@{ Exe = $ps; Args = ('-NoProfile -ExecutionPolicy Bypass -File "' + $ro + '"'); Stdin = '{"agent_type":"code-reviewer","tool_input":{"command":""}}' })
      Expect-Eq 'readonly empty command' $emp[0].Code 0
      $bomJson = '{"agent_type":"code-reviewer","tool_name":"PowerShell","tool_input":{"command":"git add ."}}'
      $bom = Run-Batch @(
        [pscustomobject]@{ Exe = $ps; Args = ('-NoProfile -ExecutionPolicy Bypass -File "' + $ro + '"'); Stdin = ([string][char]0xFEFF) + $bomJson },
        [pscustomobject]@{ Exe = $ps; Args = ('-NoProfile -ExecutionPolicy Bypass -File "' + $ro + '"'); Stdin = ([string][char]0x2229) + [char]0x2557 + [char]0x2510 + $bomJson })
      Expect-Eq 'readonly BOM before JSON still blocks' $bom[0].Code 2
      Expect-Eq 'readonly OEM-decoded BOM before JSON still blocks' $bom[1].Code 2
      # Filter contract: the `if` globs of the guard-readonly PowerShell entries in hooks.json (case-sensitive, `*` only,
      # like Claude Code) must match every block row, so no write command skips the guard. Case variants of "git" are
      # separate entries because the globs have no character classes.
      $hj = Get-Content -Raw -LiteralPath (Join-Path $root 'plugins/guyb/hooks/hooks.json')
      $globs = @((($hj | ConvertFrom-Json).hooks.PreToolUse | ForEach-Object { $_.hooks }) | Where-Object { $_.shell -eq 'powershell' -and $_.command -like '*guard-readonly*' } | ForEach-Object { $_.if })
      Expect-Eq 'hooks.json readonly PowerShell filter entries' $globs.Count 8
      foreach ($v in 'git', 'giT', 'gIt', 'gIT', 'Git', 'GiT', 'GIt', 'GIT') {
        Expect-Eq "hooks.json readonly filter *$v*" ($globs -ccontains "PowerShell(*$v*)") $true
      }
      foreach ($r in $rows) {
        if ($r.Expect -ne 2) { continue }
        $hit = $false
        foreach ($g in $globs) { if ($r.Cmd -clike ($g -replace '^PowerShell\((.*)\)$', '$1')) { $hit = $true } }
        Expect-Eq ('hooks.json readonly filter covers: ' + $r.Cmd) $hit $true
      }
    }

    'wrapper' {
      Write-Host 'hooks.json guard-readonly PowerShell entry, end to end'
      $hj = Get-Content -Raw -LiteralPath (Join-Path $root 'plugins/guyb/hooks/hooks.json')
      $entries = @((($hj | ConvertFrom-Json).hooks.PreToolUse | ForEach-Object { $_.hooks }) | Where-Object { $_.shell -eq 'powershell' -and $_.command -like '*guard-readonly*' })
      # one entry per casing of "git" (the `if` globs are case-sensitive), all with the same command
      Expect-Eq 'hooks.json readonly PowerShell entry count' $entries.Count 8
      Expect-Eq 'hooks.json readonly PowerShell entries share one command' @($entries | ForEach-Object { $_.command } | Select-Object -Unique).Count 1
      $hcmd = $entries[0].command.Replace('${CLAUDE_PLUGIN_ROOT}', (Join-Path $root 'plugins/guyb'))
      $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($hcmd))
      $hosts = @()
      foreach ($hn in 'powershell', 'pwsh') {
        $hc = Get-Command $hn -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hc) { $hosts += , @($hn, $hc.Source) }
      }
      $wraps = @(
        @('reviewer git add', '{"agent_type":"guyb:code-reviewer","tool_name":"PowerShell","tool_input":{"command":"git add ."}}', 2),
        @('reviewer git status', '{"agent_type":"guyb:code-reviewer","tool_name":"PowerShell","tool_input":{"command":"git status"}}', 0),
        @('implementer git add', '{"agent_type":"guyb:implementer","tool_name":"PowerShell","tool_input":{"command":"git add ."}}', 0),
        @('main session git add', '{"tool_name":"PowerShell","tool_input":{"command":"git add ."}}', 0),
        @('bad json', 'not json', 0)
      )
      $ie = [Console]::InputEncoding
      try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
      try {
        foreach ($hh in $hosts) {
          try {
            $hs = @($wraps | ForEach-Object { Start-Proc $hh[1] "-NoProfile -EncodedCommand $enc" $_[1] })
          } catch { Write-Host "  skip: cannot start $($hh[0]) ($($hh[1]))"; continue }
          $wr = @($hs | ForEach-Object { Finish-Proc $_ })
          for ($i = 0; $i -lt $wraps.Count; $i++) { Expect-Eq ("wrapper $($hh[0]) $($wraps[$i][0])") $wr[$i].Code $wraps[$i][2] }
          Expect-Has "wrapper $($hh[0]) reviewer git add" $wr[0].Text 'guyb: blocked - read-only agent'
        }
      } finally { try { [Console]::InputEncoding = $ie } catch { } }
    }

    'connections' {
      Write-Host 'connections: lines, warnings (fixture config dirs, stub CLIs)'
      $cx = Join-Path $tmp 'cx'
      $cxHome = Join-Path $cx 'home'
      foreach ($d in 'stub', 'claude', 'gh cfg', 'gcloud/configurations', 'az', 'xdg', 'appdata', 'home/.aws/login/cache', 'home/.claude/guyb') { New-Item -ItemType Directory -Force -Path (Join-Path $cx $d) | Out-Null }
      $clog = Join-Path $cx 'cli.log'; $glog = Join-Path $cx 'gh.log'
      Write-File $clog ''; Write-File $glog ''
      foreach ($t in 'aws', 'gcloud', 'az', 'wrangler', 'glab', 'guyb-stub-cli') {
        if ($isWin) { Write-File (Join-Path $cx "stub/$t.cmd") ("@echo off`r`necho $t %*>>`"$clog`"`r`nexit /b 1`r`n") }
        else { Write-File (Join-Path $cx "stub/$t") ("#!/bin/sh`necho `"$t `$*`" >> `"$clog`"`nexit 1`n"); & chmod +x (Join-Path $cx "stub/$t") }
      }
      $env:PATH = (Join-Path $cx 'stub') + $sep + $env:PATH
      $env:CLAUDE_CONFIG_DIR = Join-Path $cx 'claude'; $env:GH_CONFIG_DIR = Join-Path $cx 'gh cfg'; $env:AZURE_CONFIG_DIR = Join-Path $cx 'az'
      $env:XDG_CONFIG_HOME = Join-Path $cx 'xdg'; $env:APPDATA = Join-Path $cx 'appdata'; $env:CLOUDSDK_CONFIG = Join-Path $cx 'gcloud'
      $env:GH_STUB_LOG = $glog
      foreach ($v in 'AWS_CONFIG_FILE', 'AWS_SHARED_CREDENTIALS_FILE', 'AWS_ACCESS_KEY_ID', 'AWS_PROFILE', 'GH_TOKEN', 'GITHUB_TOKEN', 'CLOUDFLARE_API_TOKEN', 'BITBUCKET_EMAIL', 'BITBUCKET_API_TOKEN') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
      $env:HOME = $cxHome; $env:USERPROFILE = $cxHome
      Set-Variable -Name HOME -Value $cxHome -Force -Scope Global # $HOME is read at startup; the scripts under test read the variable
      . (Join-Path $root 'plugins/guyb/skills/setup/connections.ps1')
      $secretA = 'SENTINEL-SECRET-1'; $secretB = 'SENTINEL-AWS-CACHE-2'
      $prof = Join-Path $cxHome '.claude/guyb/profile.md'
      $allOut = ''
      function Cn($dir) { $script:cnOut = (Get-GuybConnLines (Get-GuybConnections -Mode brief -Dir $dir)) -join "`n"; $script:allOut += $script:cnOut }
      $fresh = [datetime]::UtcNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
      $awsCache = Join-Path $cxHome '.aws/login/cache/a.json'
      Write-File $awsCache ('{"accessToken":{"secretAccessKey":"' + $secretB + '","expiresAt":"' + $fresh + '"},"refreshToken":"x"}')
      Write-File (Join-Path $cxHome '.aws/config') "[default]`nregion = ap-northeast-1`n"
      $hosts = Join-Path $env:GH_CONFIG_DIR 'hosts.yml'
      Write-File $hosts "github.com:`n    users:`n        alamhanz:`n    user: alamhanz`n"
      Write-File (Join-Path $cx 'gcloud/configurations/config_default') 'x'; Write-File (Join-Path $cx 'gcloud/credentials.db') ''
      [System.IO.File]::WriteAllText((Join-Path $cx 'az/azureProfile.json'), '{"subscriptions":[{"id":"SUB-123"}]}', (New-Object System.Text.UTF8Encoding($true)))
      $cj = Join-Path $cx 'claude/.claude.json'
      Write-File $cj "{`n  `"numStartups`": 1,`n  `"mcpServers`": {`n    `"cloudflare`": {`n      `"type`": `"http`"`n    },`n    `"Neon`": {`n      `"type`": `"http`"`n    }`n  },`n  `"projects`": {`n    `"x`": {`n      `"mcpServers`": {`n        `"zzz`": {}`n      }`n    }`n  }`n}`n"
      $env:CLOUDFLARE_API_TOKEN = $secretA
      $full = "# Profile`r`n`r`n## Git`r`n- github thing`r`n`r`n## Connections`r`n<!-- guyb:connections - `"- <type> <name>: key=value ...`", no secrets -->`r`n- github alamhanz: cli=gh default=yes`r`n- aws default: region=ap-northeast-1 account=1 login=aws-login`r`n- cloudflare main: auth=env`r`n- mcp cloudflare: url=https://mcp.cloudflare.com/mcp scope=user auth=oauth`r`n- mcp Neon: url=x scope=user`r`n- gcp default: project=p`r`n- azure sub: subscription=SUB-123`r`n- gitlab gl: cli=glab`r`n- foo bar: x=y`r`n`r`n## Other`r`n- aws nothing: region=x`r`n"
      Write-File $prof $full
      $noproj = Join-Path $tmp 'conn-root'; New-Item -ItemType Directory -Force -Path $noproj | Out-Null
      Cn $noproj
      $want = 'connections: github alamhanz, aws default (ap-northeast-1), cloudflare main, mcp cloudflare (user), mcp Neon (user), gcp default (p), azure sub, gitlab gl, foo bar'
      Expect-Eq 'connections all ok (CRLF profile, spaces in config paths)' $cnOut $want
      # AWS
      Write-File (Join-Path $cxHome '.aws/config') "[profile other]`nregion = x`n"; Cn $noproj
      Expect-Has 'aws profile missing' $cnOut 'warn: connection aws default: profile default missing from ~/.aws/config'
      Write-File (Join-Path $cxHome '.aws/config') "[default]`nregion = ap-northeast-1`n"
      $old = [datetime]::UtcNow.AddDays(-3)
      Write-File $awsCache ('{"accessToken":{"secretAccessKey":"' + $secretB + '","expiresAt":"' + $old.ToString('yyyy-MM-ddTHH:mm:ssZ') + '"}}'); Cn $noproj
      Expect-Has 'aws login cache 3 days old' $cnOut ('warn: connection aws default: login session likely expired (last refresh ' + $old.ToString('yyyy-MM-dd') + ')')
      $awsCache2 = Join-Path $cxHome '.aws/login/cache/b.json'
      Write-File $awsCache2 ('{"expiresAt":"' + $fresh + '"}'); Cn $noproj
      Expect-Lacks 'aws login: any fresh cache keeps it silent' $cnOut 'login session'
      Remove-Item -LiteralPath $awsCache2
      $env:AWS_ACCESS_KEY_ID = 'x'; Cn $noproj; Remove-Item Env:AWS_ACCESS_KEY_ID
      Expect-Lacks 'aws login: static keys in env skip the expiry check' $cnOut 'login session'
      Write-File $awsCache ('{"accessToken":{"secretAccessKey":"' + $secretB + '","expiresAt":"' + $fresh + '"}}'); Cn $noproj
      Expect-Eq 'aws login cache 1 h old' $cnOut $want
      # GitHub
      Write-File $hosts "github.com:`n    users:`n        someone:`n    user: someone`n"; Cn $noproj
      Expect-Has 'gh other user' $cnOut 'warn: connection github alamhanz: gh not logged in as alamhanz'
      $env:GH_TOKEN = 'x'; Cn $noproj; Remove-Item Env:GH_TOKEN
      Expect-Lacks 'gh token in env' $cnOut 'gh not logged in'
      Write-File $hosts "github.com:`n    user: alamhanz`n"
      # MCP, Cloudflare, gcloud, az
      Write-File $cj "{`"mcpServers`": {`"cloudflare`": {}}}`n"; Cn $noproj
      Expect-Lacks 'mcp inline config: names not read, silent' $cnOut 'MCP server'
      Write-File $cj "{`n  `"mcpServers`": {`n    `"cloudflare`": {}`n  }`n}`n"; Cn $noproj
      Expect-Has 'mcp name missing' $cnOut 'warn: connection mcp Neon: MCP server not configured at user scope'
      Expect-Lacks 'mcp name present' $cnOut 'connection mcp cloudflare'
      Write-File $cj '{"mcpServers":{"cloudflare":{}}}'; Cn $noproj
      Expect-Lacks 'mcp config not pretty-printed: silent' $cnOut 'MCP server'
      Remove-Item -LiteralPath $cj; Cn $noproj
      Expect-Lacks 'mcp config missing: silent' $cnOut 'MCP server'
      Remove-Item Env:CLOUDFLARE_API_TOKEN; Cn $noproj
      Expect-Has 'cloudflare token unset' $cnOut 'warn: connection cloudflare main: CLOUDFLARE_API_TOKEN not set in this session'
      $env:CLOUDFLARE_API_TOKEN = $secretA
      Remove-Item -LiteralPath $hosts, (Join-Path $cx 'gcloud/credentials.db'), (Join-Path $cx 'az/azureProfile.json'); Cn $noproj
      Expect-Has 'gcloud not logged in' $cnOut 'warn: connection gcp default: not logged in'
      Expect-Has 'az subscription missing' $cnOut 'warn: connection azure sub: subscription SUB-123 not in az profile'
      Remove-Item -LiteralPath (Join-Path $cx 'gcloud/configurations/config_default'); Cn $noproj
      Expect-Has 'gcloud configuration missing' $cnOut 'warn: connection gcp default: configuration default missing'
      # CLI not on PATH, wrangler, bitbucket, unknown type
      Write-File $prof "# P`n`n## Connections`n- db pg: cli=guyb-no-such-cli`n- service svc: cli=guyb-stub-cli env=GUYB_SMOKE_NOPE`n- cloudflare w: auth=wrangler`n- bitbucket bb: env=BITBUCKET_EMAIL,BITBUCKET_API_TOKEN`n- zzz yy: k=v`n"; Cn $noproj
      Expect-Has 'cli missing' $cnOut 'warn: connection db pg: guyb-no-such-cli not on PATH'
      Expect-Lacks 'cli present (stub, not run)' $cnOut 'guyb-stub-cli not on PATH'
      Expect-Has 'service env var' $cnOut 'warn: connection service svc: GUYB_SMOKE_NOPE not set in this session'
      Expect-Has 'wrangler not logged in' $cnOut 'warn: connection cloudflare w: wrangler not logged in'
      Expect-Has 'bitbucket env vars' $cnOut 'warn: connection bitbucket bb: BITBUCKET_API_TOKEN not set in this session'
      Expect-Has 'unknown type is listed' $cnOut ', zzz yy'
      Expect-Lacks 'unknown type is not checked' $cnOut 'connection zzz'
      Write-File (Join-Path $env:XDG_CONFIG_HOME '.wrangler/config/default.toml') ''; Cn $noproj
      Expect-Lacks 'wrangler logged in' $cnOut 'wrangler not logged in'
      # profile without section, empty section
      Write-File $prof "# Profile`n`n## Git`n- x`n"; Cn $noproj
      Expect-Eq 'profile without Connections section' $cnOut 'connections: not recorded in ~/.claude/guyb/profile.md'
      Write-File $prof "# Profile`n`n## Connections`n<!-- comment -->`n`n## Other`n"; Cn $noproj
      Expect-Eq 'empty Connections section' $cnOut 'connections: not recorded in ~/.claude/guyb/profile.md'
      # project override and project config lines
      Write-File $prof $full
      $pj = Join-Path $tmp 'conn-proj'; Make-Fixture $pj
      Remove-Item -LiteralPath (Join-Path $pj '.claude/CLAUDE.md'); Cn $pj
      Expect-Has 'project without CLAUDE.md' $cnOut 'project config: none - follows global (~/.claude/guyb/profile.md)'
      Write-File (Join-Path $pj '.claude/CLAUDE.md') "# fixture`n`n- Cloud: none`n`n## Credentials (names only)`nNone.`n`nmax_parallel: 3`ncleanup_days: 5`n"; Cn $pj
      Expect-Has 'project cloud none, credentials none' $cnOut 'project config: cloud none; credentials none; max_parallel 3; cleanup limits'
      Write-File (Join-Path $pj '.claude/CLAUDE.md') "# fixture`n`n## Connections`n- aws prod: region=eu-west-1`n`n## Credentials`n- A: x`n- B: y`n"; Write-File (Join-Path $pj '.mcp.json') ''; Cn $pj
      Expect-Has 'project override replaces the global aws entry' $cnOut 'connections: github alamhanz, cloudflare main, mcp cloudflare (user), mcp Neon (user), gcp default (p), azure sub, gitlab gl, foo bar, aws prod (project)'
      Expect-Lacks 'project override: global aws entry gone' $cnOut 'aws default'
      Expect-Has 'project config with connections' $cnOut 'project config: connections aws prod; credentials 2 names; .mcp.json'
      Cn $noproj; Expect-Lacks 'projects root: no project line' $cnOut 'project config:'
      Remove-Item -LiteralPath $prof; Cn $pj
      Expect-Lacks 'no profile: no connections line' $cnOut 'connections:'
      Expect-Has 'no profile: project line stays' $cnOut 'project config:'
      Write-File $prof $full
      # the real scripts: brief.ps1, check.ps1
      Write-File (Join-Path $cx 'claude/.claude.json') "{`n  `"mcpServers`": {`n    `"Neon`": {}`n  }`n}`n"
      Write-File $hosts "github.com:`n    user: alamhanz`n"
      $env:GH_STUB_LISTRC = '4'
      $r = Run-Child $brief @('-Dir', $pj) $null
      Remove-Item Env:GH_STUB_LISTRC
      $bout = $r[1]
      Expect-Has 'brief.ps1 connections line' $bout 'connections: github alamhanz'
      Expect-Has 'brief.ps1 warn line' $bout 'warn: connection mcp cloudflare: MCP server not configured at user scope'
      Expect-Has 'brief.ps1 gh auth failed' $bout 'warn: connection github alamhanz: gh auth failed'
      Expect-Has 'brief.ps1 project config' $bout 'project config: connections aws prod'
      Expect-Eq 'brief.ps1 made the one gh list call' (Gh-Calls $glog 'pr list') 1
      $r = Run-Child $brief @('-Dir', $pj) $null
      $bout2 = $r[1]
      Expect-Lacks 'brief.ps1 without gh failure' $bout2 'gh auth failed'
      Add-Content -LiteralPath $prof -Value "`r`n## Connections`r`n- bitbucket bb: env=BITBUCKET_EMAIL,BITBUCKET_API_TOKEN`r`n" # a second section is read too
      $r = Run-Child $check @('-StartDir', $pj) $null
      $cjson = $null
      try { $cjson = $r[1] | ConvertFrom-Json } catch { }
      if ($cjson -and $cjson.version -eq 1) { Ok } else { No 'check.ps1 with connections: output is not valid JSON' }
      $ids = @($cjson.checks | ForEach-Object { $_.id })
      Expect-Has 'check.ps1 connections entry' (($cjson.checks | Where-Object { $_.id -eq 'connections' } | ForEach-Object { $_.detail }) -join '') 'github alamhanz'
      $mc = @($cjson.checks | Where-Object { $_.id -eq 'conn-mcp-cloudflare' })
      Expect-Eq 'check.ps1 conn warn entry' (($mc | ForEach-Object { "$($_.status)|$($_.blocking)|$($_.detail)|$($_.fix)|$($_.fixBy)" }) -join '') 'warn|False|MCP server not configured at user scope||none'
      Expect-Has 'check.ps1 project-config entry' ($ids -join ' ') 'project-config'
      Expect-Has 'check.ps1 two warnings of one connection get distinct ids' ($ids -join ' ') 'conn-bitbucket-bb-2'
      $allOut += $bout + $bout2 + $r[1]
      Expect-Lacks 'no secret value in any output (env token)' $allOut $secretA
      Expect-Lacks 'no secret value in any output (aws cache)' $allOut $secretB
      if ((Get-Item -LiteralPath $clog).Length -gt 0) { No ('a CLI was run: ' + (Get-Content -LiteralPath $clog -Raw)) } else { Ok }
    }

    default { No "unknown group '$Group'" }
  }
} finally {
  Set-Location -LiteralPath $root
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "@@ $($script:pass) $($script:fail)"
