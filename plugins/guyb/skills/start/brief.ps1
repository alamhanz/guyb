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
  if (-not ((Test-Path -LiteralPath $gi) -and (Select-String -LiteralPath $gi -Pattern '^/?\.claude/?(pipeline/?)?\s*$' -Quiet))) {
    Add-Line 'gitignore: .claude/pipeline/ not ignored'
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

$state = Join-Path $Dir '.claude/STATE.md'
if (Test-Path -LiteralPath $state) {
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

$runs = Join-Path $Dir '.claude/pipeline/runs.md'
if (Test-Path -LiteralPath $runs) {
  $unf = @(Get-Content -Encoding UTF8 -LiteralPath $runs | Where-Object { $_ -match '^\|' -and $_ -match '\|\s*(running|queued)\s*\|' })
  if ($unf.Count -gt 0) {
    Add-Line "unfinished runs ($($unf.Count)):"
    $unf | Select-Object -First 5 | ForEach-Object { Add-Line "  $(($_ -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' | ')" }
  }
}

$qs = Join-Path $Dir '.claude/pipeline/questions.md'
if (Test-Path -LiteralPath $qs) {
  $open = @(Get-Content -Encoding UTF8 -LiteralPath $qs | Where-Object { $_ -match '^\|\s*Q\d+' -and $_ -match '\|\s*open\s*\|' })
  if ($open.Count -gt 0) {
    Add-Line "open questions ($($open.Count)):"
    $open | Select-Object -First 5 | ForEach-Object { Add-Line "  $(($_ -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 4) -join ' | ')" }
  }
}

$out | ForEach-Object { Write-Output $_ }
