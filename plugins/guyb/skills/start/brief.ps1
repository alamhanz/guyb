# Read-only session briefing for /guyb:start. No prompts, no cd, no secrets. Usage: brief.ps1 [-Dir <project folder>]
param([string]$Dir = (Get-Location).Path)
$ErrorActionPreference = 'SilentlyContinue'
$env:GIT_TERMINAL_PROMPT = '0'
$Dir = $Dir.TrimEnd('\', '/')
$out = New-Object System.Collections.Generic.List[string]
function Add-Line($s) { $out.Add([string]$s) }

Add-Line "project: $(Split-Path -Leaf $Dir)"

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
  if (-not ((Test-Path $gi) -and (Select-String -Path $gi -Pattern '^/?\.claude/?(pipeline/?)?\s*$' -Quiet))) {
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
if (Test-Path $state) {
  $lines = Get-Content -Encoding UTF8 $state
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
} else {
  Add-Line 'STATE.md: missing'
}

$runs = Join-Path $Dir '.claude/pipeline/runs.md'
if (Test-Path $runs) {
  $unf = @(Get-Content -Encoding UTF8 $runs | Where-Object { $_ -match '^\|' -and $_ -match '\|\s*(running|queued)\s*\|' })
  if ($unf.Count -gt 0) {
    Add-Line "unfinished runs ($($unf.Count)):"
    $unf | Select-Object -First 5 | ForEach-Object { Add-Line "  $(($_ -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' | ')" }
  }
}

$qs = Join-Path $Dir '.claude/pipeline/questions.md'
if (Test-Path $qs) {
  $open = @(Get-Content -Encoding UTF8 $qs | Where-Object { $_ -match '^\|\s*Q\d+' -and $_ -match '\|\s*open\s*\|' })
  if ($open.Count -gt 0) {
    Add-Line "open questions ($($open.Count)):"
    $open | Select-Object -First 5 | ForEach-Object { Add-Line "  $(($_ -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 4) -join ' | ')" }
  }
}

$out | ForEach-Object { Write-Output $_ }
