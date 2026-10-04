# Read-only session briefing for /guyb:start. No prompts, no cd, no secrets. Usage: brief.ps1 [-Dir <project folder>]
param([string]$Dir = (Get-Location).Path)
$ErrorActionPreference = 'SilentlyContinue'
$env:GIT_TERMINAL_PROMPT = '0'
$Dir = $Dir.TrimEnd('\', '/')
$out = New-Object System.Collections.Generic.List[string]
function Add-Line($s) { $out.Add([string]$s) }

Add-Line "project: $(Split-Path -Leaf $Dir)"

$maxPar = 5; $maxSrc = 'default'
foreach ($c in @(@((Join-Path $Dir '.claude/CLAUDE.md'), 'project'), @((Join-Path $HOME '.claude/guyb/profile.md'), 'profile'))) {
  if (-not (Test-Path -LiteralPath $c[0])) { continue }
  $m = @(Get-Content -Encoding UTF8 -LiteralPath $c[0] | ForEach-Object { if ($_ -match '^\s*(?:[-*]\s+)?[`*]*max_parallel[`*]*\s*:[`*\s]*(\d{1,2})[`*\s]*$' -and [int]$Matches[1] -ge 1 -and [int]$Matches[1] -le 20) { [int]$Matches[1] } })
  if ($m.Count -gt 0) { $maxPar = $m[0]; $maxSrc = $c[1]; break }
}
Add-Line "max parallel: $maxPar ($maxSrc)"

# Per-project files live in .claude/guyb/; the legacy .claude/STATE.md and .claude/pipeline/ are read as a fallback (never moved here).
# A legacy STATE.md counts as guyb's only with our marker or our structure; anything else is someone else's file.
function Test-GuybState($p) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
  $t = @(([System.IO.File]::ReadAllText($p) -replace '^\uFEFF', '' -replace "`r", '') -split "`n")
  if (@($t | Where-Object { $_ -ceq '<!-- guyb:state -->' }).Count -gt 0) { return $true }
  foreach ($h in 'next up', 'open issues', 'decisions', 'recent changes') {
    if (@($t | Where-Object { $_ -match '^#+[ \t]+(.*)$' -and $Matches[1].Trim().ToLowerInvariant() -eq $h }).Count -eq 0) { return $false }
  }
  return $true
}
$newState = Join-Path $Dir '.claude/guyb/STATE.md'; $oldState = Join-Path $Dir '.claude/STATE.md'
$newPipe = Join-Path $Dir '.claude/guyb/pipeline'; $oldPipe = Join-Path $Dir '.claude/pipeline'
$newStateOk = Test-Path -LiteralPath $newState -PathType Leaf
$oldStateOk = Test-GuybState $oldState
$newPipeOk = Test-Path -LiteralPath $newPipe -PathType Container
$oldPipeOk = Test-Path -LiteralPath $oldPipe -PathType Container
$state = ''; if ($newStateOk) { $state = $newState } elseif ($oldStateOk) { $state = $oldState }
$pipe = ''; $pipeLegacy = $false
if ($newPipeOk) { $pipe = $newPipe } elseif ($oldPipeOk) { $pipe = $oldPipe; $pipeLegacy = $true }
$mv = @(); $mig = @()
if ($oldStateOk -and -not $newStateOk) { $mv += '.claude/STATE.md' }
if ($oldPipeOk -and -not $newPipeOk) { $mv += '.claude/pipeline/' }
if ($mv.Count -gt 0) { $mig += ('move ' + ($mv -join ', ') + ' to .claude/guyb/') }
if ($oldStateOk -and $newStateOk) { $mig += 'conflict: .claude/STATE.md and .claude/guyb/STATE.md both exist' }
if ($oldPipeOk -and $newPipeOk) { $mig += 'conflict: .claude/pipeline/ and .claude/guyb/pipeline/ both exist' }
if ($mig.Count -gt 0) { Add-Line ('migrate: ' + ($mig -join '; ')) }

# Outdated plugin flag: installed guyb@guyb vs the local marketplace source. Silent on any gap.
$cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$instF = Join-Path $cfg 'plugins/installed_plugins.json'
$mkF = Join-Path $cfg 'plugins/known_marketplaces.json'
if ((Test-Path -LiteralPath $instF) -and (Test-Path -LiteralPath $mkF)) {
  try {
    $instJ = Get-Content -Raw -Encoding UTF8 -LiteralPath $instF | ConvertFrom-Json
    $mkJ = Get-Content -Raw -Encoding UTF8 -LiteralPath $mkF | ConvertFrom-Json
    $inst = [string]@($instJ.plugins.'guyb@guyb')[0].version
    $srcDir = [string]$mkJ.guyb.source.path
    $pj = Join-Path $srcDir 'plugins/guyb/.claude-plugin/plugin.json'
    if ($inst -and $srcDir -and (Test-Path -LiteralPath $pj)) {
      $avail = [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $pj | ConvertFrom-Json).version
      $a = $inst -replace '[-+].*$', ''
      $b = $avail -replace '[-+].*$', ''
      if ($a -match '^\d+(\.\d+)*$' -and $b -match '^\d+(\.\d+)*$') {
        $x = @($a -split '\.'); $y = @($b -split '\.')
        $behind = $false
        $n = [Math]::Max($x.Count, $y.Count)
        for ($k = 0; $k -lt $n; $k++) {
          $xi = 0; $yi = 0
          if ($k -lt $x.Count) { $xi = [decimal]$x[$k] }
          if ($k -lt $y.Count) { $yi = [decimal]$y[$k] }
          if ($xi -lt $yi) { $behind = $true; break }
          if ($xi -gt $yi) { break }
        }
        if ($behind) { Add-Line "plugin: $inst installed, $avail available - run: claude plugin marketplace update guyb; claude plugin update guyb@guyb" }
      }
    }
  } catch { }
}

$isGit = (git -C $Dir rev-parse --is-inside-work-tree 2>$null) -eq 'true'
if ($isGit) {
  $branch = git -C $Dir rev-parse --abbrev-ref HEAD 2>$null
  $ab = git -C $Dir rev-list --left-right --count '@{u}...HEAD' 2>$null
  if ($ab) { $p = $ab -split '\s+'; $sync = "ahead $($p[1]), behind $($p[0])" } else { $sync = 'no upstream' }
  Add-Line "branch: $branch ($sync)"

  $dirty = @(git -C $Dir status --short 2>$null)
  Add-Line "uncommitted: $($dirty.Count) file(s)"
  $dirty | Select-Object -First 10 | ForEach-Object { Add-Line "  $_" }
  if ($dirty.Count -gt 10) { Add-Line "  ... +$($dirty.Count - 10) more" }

  $gi = Join-Path $Dir '.gitignore'
  $giOk = $false
  if (Test-Path -LiteralPath $gi) {
    $giOk = Select-String -LiteralPath $gi -Pattern '^/?\.claude/?(guyb/pipeline/?)?\s*$' -CaseSensitive -Quiet
    if (-not $giOk -and $pipeLegacy) { $giOk = Select-String -LiteralPath $gi -Pattern '^/?\.claude/pipeline/?\s*$' -CaseSensitive -Quiet }
  }
  if (-not $giOk) { Add-Line 'gitignore: .claude/guyb/pipeline/ not ignored' }
  if ((Test-Path -LiteralPath $gi) -and (Select-String -LiteralPath $gi -Pattern '^/?\.claude/?\s*$' -CaseSensitive -Quiet)) {
    Add-Line 'warn: .gitignore ignores .claude/ - guyb STATE.md will not be committed'
  }

  Add-Line 'last commits:'
  git -C $Dir log --oneline -5 2>$null | ForEach-Object { Add-Line "  $_" }

  if (Get-Command gh -ErrorAction SilentlyContinue) {
    Push-Location -LiteralPath $Dir
    $prs = @(gh pr list --limit 5 2>$null | Where-Object { $_ })
    Pop-Location
    if ($prs.Count -gt 0) {
      Add-Line 'open PRs:'
      $prs | ForEach-Object { Add-Line "  $(($_ -split "`t")[0..2] -join ' | ')" }
    }
  }
} else {
  Add-Line 'git: not a repository'
}

if ($state) {
  $lines = Get-Content -Encoding UTF8 -LiteralPath $state
  foreach ($h in 'Next up', 'Open issues') {
    $i = 0
    for (; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "(?i)^#+\s*$h") { break } }
    if ($i -lt $lines.Count) {
      Add-Line "STATE.md ${h}:"
      $n = 0
      for ($j = $i + 1; $j -lt $lines.Count -and $n -lt 5; $j++) {
        if ($lines[$j] -match '^#') { break }
        if ($lines[$j].Trim()) { Add-Line "  $($lines[$j].Trim())"; $n++ }
      }
    }
  }
  # Drift: PRs named in live-state sections of STATE.md (Current Status, Open Issues, Next Up, In progress, Open PRs) that are already merged or closed (max 3 gh calls, silent on failure).
  if ($isGit -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $live = $false; $liveText = @(foreach ($ln in $lines) { if ($ln -match '^#') { $live = $ln -match '(?i)^#+\s*(current status|open issues|next up|in progress|open prs)' } elseif ($live) { $ln } })
    $nums = @([regex]::Matches(($liveText -join "`n"), '(?i)(?:^|[^A-Za-z0-9])(?:#|pull/|pr[ \t]+#?)(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Select-Object -First 3)
    foreach ($num in $nums) {
      Push-Location -LiteralPath $Dir
      $st = [string](gh pr view $num --json state -q .state 2>$null)
      Pop-Location
      $st = $st.Trim()
      if ($st -eq 'MERGED' -or $st -eq 'CLOSED') { Add-Line "STATE.md drift: PR #$num is $st - update STATE.md" }
    }
  }
} else {
  Add-Line 'STATE.md: missing'
}

$runs = ''; $qs = ''
if ($pipe) { $runs = Join-Path $pipe 'runs.md'; $qs = Join-Path $pipe 'questions.md' }
if ($runs -and (Test-Path -LiteralPath $runs)) {
  $unf = @(Get-Content -Encoding UTF8 -LiteralPath $runs | Where-Object { $_ -match '^\|' -and $_ -match '\|\s*(running|queued)\s*\|' })
  if ($unf.Count -gt 0) {
    Add-Line "unfinished runs ($($unf.Count)):"
    $unf | Select-Object -First 5 | ForEach-Object { Add-Line "  $((($_.Trim() -replace '^\||\|$', '') -split '\|' | ForEach-Object { $_.Trim() }) -join ' | ')" }
  }
}

if ($qs -and (Test-Path -LiteralPath $qs)) {
  $open = @(Get-Content -Encoding UTF8 -LiteralPath $qs | Where-Object { $_ -match '^\|\s*Q\d+' -and $_ -match '\|\s*open\s*\|' })
  if ($open.Count -gt 0) {
    Add-Line "open questions ($($open.Count)):"
    $open | Select-Object -First 5 | ForEach-Object { Add-Line "  $(($_ -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 4) -join ' | ')" }
  }
}

# Cleanup hints (read-only, counts only). Limits: project .claude/CLAUDE.md, then ~/.claude/guyb/profile.md, then these defaults; invalid values are ignored.
function Get-Limit([string]$key, [int]$default) {
  foreach ($f in @((Join-Path $Dir '.claude/CLAUDE.md'), (Join-Path $HOME '.claude/guyb/profile.md'))) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $v = @(Get-Content -Encoding UTF8 -LiteralPath $f | ForEach-Object { if ($_ -match ('^\s*(?:[-*]\s+)?[`*]*' + $key + '[`*]*\s*:[`*\s]*(\d{1,9})[`*\s]*$') -and [int]$Matches[1] -ge 1) { [int]$Matches[1] } })
    if ($v.Count -gt 0) { return $v[0] }
  }
  return $default
}
$limClaude = Get-Limit 'cleanup_claude_md_lines' 200
$limState = Get-Limit 'cleanup_state_lines' 300
$limRows = Get-Limit 'cleanup_rows' 200
$limDays = Get-Limit 'cleanup_days' 14
function Read-Table($path) {
  # data rows as arrays of trimmed cells; the first row is the header, separator rows are dropped
  $rows = New-Object System.Collections.ArrayList
  if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
    foreach ($l in @(Get-Content -Encoding UTF8 -LiteralPath $path)) {
      if ($l -match '^\|' -and $l -notmatch '^\|[\s|:-]+$') { [void]$rows.Add(@(($l.Trim() -replace '^\||\|$', '') -split '\|' | ForEach-Object { $_.Trim() })) }
    }
  }
  return , $rows
}
function Col-Index($header, $names) { for ($i = 0; $i -lt $header.Count; $i++) { if (@($names) -contains $header[$i]) { return $i } }; return -1 }
function Cell($row, [int]$i) { if ($i -ge 0 -and $i -lt $row.Count) { return [string]$row[$i] }; return '' }
function Age-Days($s) {
  # whole days between today and the date part (YYYY-MM-DD) of $s; -1 when there is none
  if ($s -notmatch '^(\d{4}-\d{2}-\d{2})') { return -1 }
  try { $d = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return -1 }
  return [int]((Get-Date).Date - $d).TotalDays
}
$runRows = Read-Table $runs; $qRows = Read-Table $qs
$activeIds = @{}; $allIds = @{}; $startOf = @{}; $overdue = @()
if ($runRows.Count -gt 0) {
  $hd = $runRows[0]; $iId = Col-Index $hd @('ID', 'Q'); $iSt = Col-Index $hd 'Status'; $iSd = Col-Index $hd 'Started'
  foreach ($r in $runRows | Select-Object -Skip 1) {
    $rid = Cell $r $iId; $rs = Cell $r $iSt
    if (-not $rid) { continue }
    $allIds[$rid] = $true
    if ($rs -match '^(running|queued|blocked)$') { $activeIds[$rid] = $true }
    if ($rid -notmatch '^.+-[0-9]+[A-Za-z]*$') { continue }
    $startOf[$rid] = Cell $r $iSd
    if ($rs -notmatch '^(done|failed|stopped)$' -and (Age-Days (Cell $r $iSd)) -gt $limDays) { $overdue += $rid }
  }
}
if ($qRows.Count -gt 0) {
  $hd = $qRows[0]; $iId = Col-Index $hd @('Q', 'ID'); $iRun = Col-Index $hd 'Run'; $iSt = Col-Index $hd 'Status'
  foreach ($r in $qRows | Select-Object -Skip 1) {
    if ((Cell $r $iId) -notmatch '^Q[0-9]+$' -or (Cell $r $iSt) -ne 'open') { continue }
    $when = ''; $rn = Cell $r $iRun
    if ($startOf.ContainsKey($rn)) { $when = $startOf[$rn] }
    if ((Age-Days $when) -gt $limDays) { $overdue += (Cell $r $iId) }
  }
}
if ($overdue.Count -gt 0) {
  $ov = 'overdue: ' + (($overdue | Select-Object -First 5) -join ', ')
  if ($overdue.Count -gt 5) { $ov += ", +$($overdue.Count - 5) more" }
  Add-Line $ov
}
$cl = @()
$cm = Join-Path $Dir '.claude/CLAUDE.md'
if (Test-Path -LiteralPath $cm -PathType Leaf) { $n = @(Get-Content -Encoding UTF8 -LiteralPath $cm).Count; if ($n -gt $limClaude) { $cl += "CLAUDE.md $n lines (>$limClaude)" } }
if ($state) { $n = @(Get-Content -Encoding UTF8 -LiteralPath $state).Count; if ($n -gt $limState) { $cl += "STATE.md $n lines (>$limState)" } }
$n = [Math]::Max(0, $runRows.Count - 1); if ($n -gt $limRows) { $cl += "runs.md $n rows (>$limRows)" }
$n = [Math]::Max(0, $qRows.Count - 1); if ($n -gt $limRows) { $cl += "questions.md $n rows (>$limRows)" }
$stale = 0
if ($pipe) {
  $cut = (Get-Date).AddDays(-($limDays + 1))
  foreach ($sub in 'progress', 'reports', 'plans', 'brand') {
    $sd = Join-Path $pipe $sub
    if (-not (Test-Path -LiteralPath $sd -PathType Container)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $sd -Recurse -File -Force)) {
      if ($f.LastWriteTime -ge $cut) { continue }
      if ($sub -eq 'brand') { $rel = $f.FullName.Substring($sd.TrimEnd('\', '/').Length).TrimStart('\', '/'); $fid = ($rel -split '[\\/]')[0]; if ($rel -notmatch '[\\/]') { $fid = [System.IO.Path]::GetFileNameWithoutExtension($fid) } }
      else { $fid = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) }
      if (-not $allIds.ContainsKey($fid) -and $fid -match '^(.*-[0-9]+)') { $fid = $Matches[1] }
      if ($activeIds.ContainsKey($fid)) { continue }
      $stale++
    }
  }
}
if ($stale -gt 0) { $cl += "$stale pipeline files older than $limDays days" }
if ($cl.Count -gt 0) { Add-Line ('cleanup: ' + ($cl -join '; ')) }

# Environment gaps (read-only): a tool runs only when the matching project file exists; silent when all is fine.
# Version strings come from untrusted files: strict regex before use; only known tools from PATH are run (3s cap each).
function Probe($exe, [string]$argStr, [int]$ms = 3000) {
  $r = [pscustomobject]@{ Code = -1; Out = ''; TimedOut = $false }
  $cmd = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { return $r }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.Source; $psi.Arguments = $argStr
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
    if ($p.WaitForExit($ms)) {
      $p.WaitForExit(); $r.Code = $p.ExitCode
      if ($so.Wait(1000)) { $r.Out = ([string]$so.Result).Trim() }
    } else {
      $r.TimedOut = $true
      # kill the whole tree: an orphaned grandchild would keep our stdout open (Windows)
      if ($env:OS -eq 'Windows_NT') { & taskkill /PID $p.Id /T /F *> $null }
      try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
    }
  } catch { }
  return $r
}
function First-Line($path) {
  $l = @(Get-Content -Encoding UTF8 -LiteralPath $path -TotalCount 1)
  if ($l.Count -gt 0) { return ([string]$l[0]).Trim() }
  return ''
}
function Has-Any($names) { foreach ($n in $names) { if (Test-Path -LiteralPath (Join-Path $Dir $n)) { return $true } }; return $false }
function Ver-Lt($a, $b) { ([int]$a[0] -lt [int]$b[0]) -or (([int]$a[0] -eq [int]$b[0]) -and ([int]$a[1] -lt [int]$b[1])) }

# python
$pyReq = @(Get-ChildItem -LiteralPath $Dir -Filter 'requirements*.txt' -File -ErrorAction SilentlyContinue)
if ((Has-Any @('pyproject.toml', '.python-version', 'uv.lock')) -or $pyReq.Count -gt 0) {
  $wantV = ''; $wantSrc = ''; $wantMin = $false
  $pvf = Join-Path $Dir '.python-version'
  if (Test-Path -LiteralPath $pvf) {
    if ((First-Line $pvf) -match '^v?(\d+\.\d+)') { $wantV = $Matches[1]; $wantSrc = '.python-version' }
  }
  $pyp = Join-Path $Dir 'pyproject.toml'
  if (-not $wantV -and (Test-Path -LiteralPath $pyp)) {
    $txt = (Get-Content -Encoding UTF8 -LiteralPath $pyp) -join "`n"
    if ($txt -match '(?m)^\s*requires-python\s*=\s*["'']\s*(>=|==|~=)?\s*(\d+\.\d+)') {
      if ($Matches[1]) { $wantV = $Matches[2]; $wantSrc = 'pyproject.toml'; $wantMin = ($Matches[1] -eq '>=') }
    }
  }
  $found = ''
  foreach ($cand in @(@('python3', '--version'), @('python', '--version'), @('py', '-3 --version'))) {
    $pr = Probe $cand[0] $cand[1]
    if ($pr.Code -eq 0 -and $pr.Out -match '^Python (\d+\.\d+)') { $found = $Matches[1]; break }
  }
  $parts = @()
  if (-not $found) {
    if ($wantV) { $parts += "python wants $wantV ($wantSrc), not installed" } else { $parts += 'python not installed' }
  } elseif ($wantV) {
    $w = @($wantV -split '\.'); $f = @($found -split '\.')
    $bad = $false
    if ($wantMin) { $bad = Ver-Lt $f $w } else { $bad = (([int]$w[0] -ne [int]$f[0]) -or ([int]$w[1] -ne [int]$f[1])) }
    if ($bad) { $parts += "python wants $wantV ($wantSrc), found $found" }
  }
  if (-not ((Test-Path -LiteralPath (Join-Path $Dir '.venv') -PathType Container) -or (Test-Path -LiteralPath (Join-Path $Dir 'venv') -PathType Container))) { $parts += 'python .venv missing' }
  if ($parts.Count -gt 0) { Add-Line ('env: ' + ($parts -join '; ')) }
}

# node
$pkgF = Join-Path $Dir 'package.json'
if (Test-Path -LiteralPath $pkgF) {
  $pkgJ = $null
  try { $pkgJ = Get-Content -Raw -Encoding UTF8 -LiteralPath $pkgF | ConvertFrom-Json } catch { }
  $wantV = ''; $wantSrc = ''; $wantMin = $false
  foreach ($nf in '.nvmrc', '.node-version') {
    $nfp = Join-Path $Dir $nf
    if (-not $wantV -and (Test-Path -LiteralPath $nfp)) {
      if ((First-Line $nfp) -match '^v?(\d+)') { $wantV = $Matches[1]; $wantSrc = $nf }
    }
  }
  if (-not $wantV -and $pkgJ -and $pkgJ.engines -and $pkgJ.engines.node) {
    if (([string]$pkgJ.engines.node) -match '^\s*(>=|\^|~)?\s*v?(\d+)') { $wantV = $Matches[2]; $wantSrc = 'package.json'; $wantMin = ($Matches[1] -eq '>=') }
  }
  $mgr = 'npm'
  if ($pkgJ -and ([string]$pkgJ.packageManager) -match '^(npm|pnpm|yarn|bun)@') { $mgr = $Matches[1] }
  elseif (Test-Path -LiteralPath (Join-Path $Dir 'pnpm-lock.yaml')) { $mgr = 'pnpm' }
  elseif (Test-Path -LiteralPath (Join-Path $Dir 'yarn.lock')) { $mgr = 'yarn' }
  elseif (Has-Any @('bun.lockb', 'bun.lock')) { $mgr = 'bun' }
  $nv = Probe 'node' '--version'
  $parts = @()
  if ($nv.Code -ne 0 -or $nv.Out -notmatch '^v?(\d+)') {
    if ($wantV) { $parts += "node wants $wantV ($wantSrc), not installed" } else { $parts += 'node not installed' }
    $nodeOk = $false
  } else {
    $nodeOk = $true
    $fm = $Matches[1]
    if ($wantV) {
      if ($wantMin) { $bad = ([int]$fm -lt [int]$wantV) } else { $bad = ([int]$fm -ne [int]$wantV) }
      if ($bad) { $parts += "node wants $wantV ($wantSrc), found $fm" }
    }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $Dir 'node_modules') -PathType Container)) { $parts += "node_modules missing ($mgr)" }
  if (-not (($mgr -eq 'npm') -and -not $nodeOk) -and -not (Get-Command $mgr -CommandType Application -ErrorAction SilentlyContinue)) { $parts += "$mgr not installed" }
  if ($parts.Count -gt 0) { Add-Line ('env: ' + ($parts -join '; ')) }
}

# docker: only when the project root has container files
$cfile = ''
foreach ($cf in 'compose.yaml', 'compose.yml', 'docker-compose.yml', 'docker-compose.yaml', 'Dockerfile') {
  if (-not $cfile -and (Test-Path -LiteralPath (Join-Path $Dir $cf) -PathType Leaf)) { $cfile = $cf }
}
if ($cfile) {
  $ctr = ''
  if (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue) { $ctr = 'docker' }
  elseif (Get-Command podman -CommandType Application -ErrorAction SilentlyContinue) { $ctr = 'podman' }
  if (-not $ctr) { Add-Line "env: docker not installed ($cfile)" }
  else {
    if ($ctr -eq 'docker') { $d = Probe 'docker' 'info --format "{{.ServerVersion}}"' } else { $d = Probe 'podman' 'info --format "{{.Version.Version}}"' }
    if ($d.TimedOut) { Add-Line "env: $ctr daemon not responding ($cfile)" }
    elseif ($d.Code -ne 0 -or -not $d.Out) { Add-Line "env: $ctr daemon not running ($cfile)" }
  }
}

$out | ForEach-Object { Write-Output $_ }
