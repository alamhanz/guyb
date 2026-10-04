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

  Write-Host 'brief.ps1 migration (legacy, new, both, foreign STATE.md)'
  $guybOld = "# State`r`n`r`n## Next up`r`n- legacy next`r`n`r`n## Open issues`r`n- legacy issue`r`n`r`n## Decisions`r`n- d`r`n`r`n## Recent changes`r`n- c`r`n"
  $guybNew = "<!-- guyb:state -->`r`n# State`r`n`r`n## Next up`r`n- new next`r`n"
  $foreign = "# Notes from another tool`r`n`r`nnothing to do with guyb`r`n"
  $runsHead = "| ID | Agent | Model | Task | Wave | After | Status | Started | Tokens |`r`n|---|---|---|---|---|---|---|---|---|`r`n"
  $today = (Get-Date).ToString('yyyy-MM-dd')
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

  Write-Host 'brief.ps1 empty section, question rows'
  $ep = Join-Path $tmp 'empty-sec'; New-Item -ItemType Directory -Force -Path (Join-Path $ep '.claude/guyb/pipeline') | Out-Null
  Write-File (Join-Path $ep '.claude/guyb/STATE.md') "# Next up`r`n`r`n# Open issues`r`n- one`r`n"
  Write-File (Join-Path $ep '.claude/guyb/pipeline/questions.md') "| Q | Question | Run | Status |`r`n|---|---|---|---|`r`n| Q1 | what | me | open |`r`n| Q2 | a |  | open |`r`n"
  $r = Run-Child $brief @('-Dir', $ep) $null
  Expect-Lacks 'empty section heading' $r[1] 'STATE.md Next up:'
  Expect-Has 'empty section heading' $r[1] 'STATE.md Open issues:'
  Expect-Has 'question row' $r[1] '  Q1 | what | me | open'

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

  Write-Host 'brief.ps1 cleanup: lines'
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
  $c1 = Join-Path $tmp 'clean-over'; Make-Fixture $c1; Make-Big $c1 $true
  Write-File (Join-Path $c1 '.claude/guyb/pipeline/progress/x-1.md') "p`n"
  Write-File (Join-Path $c1 '.claude/guyb/pipeline/progress/x-2.md') "p`n"
  Write-File (Join-Path $c1 '.claude/guyb/pipeline/progress/x-3.md') "p`n"
  Write-File (Join-Path $c1 '.claude/guyb/pipeline/brand/x-1/a.svg') "<svg/>`n"
  foreach ($f in 'progress/x-1.md', 'progress/x-2.md', 'brand/x-1/a.svg') { Age (Join-Path $c1 (".claude/guyb/pipeline/" + $f)) }
  $r = Run-Child $brief @('-Dir', $c1) $null
  Expect-Has 'cleanup over' $r[1] 'cleanup: CLAUDE.md 201 lines (>200); STATE.md 301 lines (>300); runs.md 201 rows (>200); questions.md 201 rows (>200); 2 pipeline files older than 14 days'
  $c2 = Join-Path $tmp 'clean-under'; Make-Fixture $c2; Make-Big $c2 $false
  Write-File (Join-Path $c2 '.claude/guyb/pipeline/progress/x-3.md') "p`n"
  $r = Run-Child $brief @('-Dir', $c2) $null
  Expect-Lacks 'cleanup under' $r[1] 'cleanup:'
  Expect-Lacks 'cleanup under' $r[1] 'overdue:'
  Write-File (Join-Path $c2 '.claude/CLAUDE.md') ("cleanup_rows: 5`ncleanup_days: 0`ncleanup_state_lines: abc`n" + (Lines 3 'line'))
  $r = Run-Child $brief @('-Dir', $c2) $null
  Expect-Has 'cleanup limit overrides' $r[1] 'cleanup: runs.md 200 rows (>5); questions.md 200 rows (>5)'
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
  Write-File (Join-Path $gi '.gitignore') ".Claude/pipeline/`n"
  $r = Run-Child $brief @('-Dir', $gi) $null
  Expect-Has 'gitignore is case-sensitive' $r[1] 'gitignore: .claude/guyb/pipeline/ not ignored'

  Write-Host 'brief.ps1 leaves the fixture unchanged'
  function Snapshot($dir) { (@(Get-ChildItem -LiteralPath $dir -Recurse -Force | Where-Object { -not $_.PSIsContainer -and $_.FullName -notmatch '[\\/]\.git([\\/]|$)' } | ForEach-Object { "$($_.FullName) $($_.Length) $($_.LastWriteTime.Ticks)" } | Sort-Object) -join "`n") + "`n" + $(if (Test-Path -LiteralPath (Join-Path $dir '.git')) { (& git -C $dir status --short) -join "`n" }) }
  foreach ($d in @($c1, $m1, $gi)) {
    $before = Snapshot $d
    $null = Run-Child $brief @('-Dir', $d) $null
    Expect-Eq "read-only $(Split-Path -Leaf $d)" (Snapshot $d) $before
  }

  Write-Host 'brief.ps1 env: lines'
  $sep = [System.IO.Path]::PathSeparator
  function Make-Docker-Stub($name, $body) {
    # stub docker that runs $body (sh on Unix, batch on Windows); returns the stub dir
    $dd = Join-Path $tmp $name
    New-Item -ItemType Directory -Force -Path $dd | Out-Null
    if ($isWin) { Write-File (Join-Path $dd 'docker.cmd') ("@echo off`r`n" + $body.Win + "`r`n") }
    else { Write-File (Join-Path $dd 'docker') ("#!/bin/sh`n" + $body.Sh + "`n"); & chmod +x (Join-Path $dd 'docker') }
    return $dd
  }
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

  Write-Host 'check.ps1 toolchain ids'
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
  Expect-Eq 'readonly chained cd && git add' (Hook 'code-reviewer' 'cd sub && git add .') 2
  Expect-Eq 'readonly chained pushd; git commit' (Hook 'code-reviewer' 'pushd sub; git commit -m x') 2
  Expect-Eq 'readonly piped echo | git apply' (Hook 'code-reviewer' 'echo hi | git apply') 2
  Expect-Eq 'readonly chained true; git push' (Hook 'code-reviewer' 'true; git push') 2
  Expect-Eq 'readonly chained newline git rm' (Hook 'code-reviewer' 'ls\ngit rm x') 2
  Expect-Eq 'readonly chained git -C dir reset' (Hook 'code-reviewer' 'cd a && git -C b reset --hard') 2
  Expect-Eq 'readonly git revert' (Hook 'code-reviewer' 'git revert HEAD') 2
  Expect-Eq 'readonly git am' (Hook 'code-reviewer' 'git am p.patch') 2
  Expect-Eq 'readonly chained read-only git' (Hook 'code-reviewer' 'cd sub && git log -1 | head') 0
  Expect-Eq 'readonly chained no git' (Hook 'code-reviewer' 'cd sub && ls') 0
  $hj = Get-Content -Raw -LiteralPath (Join-Path $root 'plugins/guyb/hooks/hooks.json')
  foreach ($sel in 'Bash(*git*)', 'PowerShell(*git*)') {
    Expect-Eq "hooks.json readonly filter $sel" ($hj.Contains('"if": "' + $sel + '"')) $true
  }
} finally {
  Set-Location -LiteralPath $root
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "smoke: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
