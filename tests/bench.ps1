# Timing harness for the PreToolUse guard hooks (PowerShell entries). Not part of CI. Works on Windows PowerShell 5.1 and PowerShell 7.
#   pwsh -File tests/bench.ps1 [-Root <plugin dir>] [-N 10]
# Reads the guard entries from <root>/hooks/hooks.json and runs each matching entry exactly as Claude Code does
# (<host> -NoProfile -Command "<command>", ${CLAUDE_PLUGIN_ROOT} substituted) for powershell (5.1) and pwsh when present,
# with the scenario JSON on stdin. Hooks of one call run in parallel in Claude Code, so a scenario reports the
# slowest matching entry per run (median and p90, ms).
# Baseline: copy hooks.json and the guards from another revision into a temp dir (git show <rev>:<path>) and pass -Root.
# Read-only on the repo; temp dir removed on exit. Bash twin: bench.sh.
param([string]$Root = '', [int]$N = 10)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins/guyb' }
$Root = (Resolve-Path -LiteralPath $Root).Path
$hooksFile = Join-Path $Root 'hooks/hooks.json'
if (-not (Test-Path -LiteralPath $hooksFile)) { Write-Host "bench: $hooksFile not found"; exit 1 }
if ($N -lt 1) { Write-Host 'bench: -N needs a positive integer'; exit 2 }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('guyb-bench-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $env:CLAUDE_PLUGIN_ROOT = $Root
  $env:GIT_TERMINAL_PROMPT = '0'

  $entries = @()
  $cfg = Get-Content -Raw -LiteralPath $hooksFile | ConvertFrom-Json
  foreach ($e in $cfg.hooks.PreToolUse) {
    foreach ($h in $e.hooks) {
      if ($h.shell -eq 'powershell' -and $h.command -match 'guard-(secrets|readonly)') {
        $cond = ''; if ($h.PSObject.Properties['if']) { $cond = [string]$h.if }
        $entries += [pscustomobject]@{ Pattern = ($cond -replace '^PowerShell\(', '' -replace '\)$', ''); Command = ([string]$h.command).Replace('${CLAUDE_PLUGIN_ROOT}', $Root) }
      }
    }
  }
  if ($entries.Count -eq 0) { Write-Host "bench: no PowerShell guard entries in $hooksFile"; exit 1 }

  $hosts = @(@{ Name = 'powershell'; Exe = 'powershell' })
  if (Get-Command pwsh -ErrorAction SilentlyContinue) { $hosts += @{ Name = 'pwsh'; Exe = 'pwsh' } }

  $clean = Join-Path $tmp 'clean'; $alias = Join-Path $tmp 'alias'
  git init -q $clean; git -C $clean config user.email b@b; git -C $clean config user.name b
  git init -q $alias; git -C $alias config alias.ci commit
  $pad = 'x' * 50000
  $scen = @(
    @{ Label = 'S1 main session, git status'; Agent = $null; Cwd = $clean; Cmd = 'git status' },
    @{ Label = 'S2 implementer, cd x; git add .'; Agent = 'guyb:implementer'; Cwd = $clean; Cmd = 'cd x; git add .' },
    @{ Label = 'S3 code-reviewer, git log -1'; Agent = 'guyb:code-reviewer'; Cwd = $clean; Cmd = 'git log -1' },
    @{ Label = 'S4 code-reviewer, git add . (blocked)'; Agent = 'guyb:code-reviewer'; Cwd = $clean; Cmd = 'git add .' },
    @{ Label = 'S5 code-reviewer, git ci -m x (alias)'; Agent = 'guyb:code-reviewer'; Cwd = $alias; Cmd = 'git ci -m x' },
    @{ Label = 'S6 main session, git commit -m x'; Agent = $null; Cwd = $clean; Cmd = 'git commit -m x' },
    @{ Label = 'S7 implementer, 50 KB command'; Agent = 'guyb:implementer'; Cwd = $clean; Cmd = "echo $pad; git status" }
  )

  function Invoke-Hook($exe, $command, $json) { # returns @(ms, exit code)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-NoProfile -Command "' + ($command -replace '"', '\"') + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [void]$p.Start()
    $o = $p.StandardOutput.ReadToEndAsync(); $er = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write($json); $p.StandardInput.Close()
    $p.WaitForExit()
    $sw.Stop()
    return @([int]$sw.ElapsedMilliseconds, $p.ExitCode)
  }

  Write-Host "bench: root=$Root runs=$N (median / p90 ms of the slowest matching entry)"
  foreach ($hst in $hosts) {
    Write-Host ("host: " + $hst.Name)
    Write-Host ('{0,-40} {1,7} {2,7} {3,4}' -f 'scenario', 'median', 'p90', 'rc')
    foreach ($s in $scen) {
      $o = [ordered]@{ session_id = 's'; hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'; tool_input = @{ command = $s.Cmd }; cwd = $s.Cwd }
      if ($s.Agent) { $o['agent_type'] = $s.Agent }
      $json = $o | ConvertTo-Json -Compress -Depth 5
      $times = @(); $rc = '-'
      for ($r = 0; $r -lt $N; $r++) {
        $worst = 0
        foreach ($e in $entries) {
          if ($s.Cmd -notlike $e.Pattern) { continue }
          $res = Invoke-Hook $hst.Exe $e.Command $json
          if ($res[0] -gt $worst) { $worst = $res[0] }
          if ($r -eq 0 -and ($rc -eq '-' -or $res[1] -gt [int]$rc)) { $rc = [string]$res[1] }
        }
        $times += $worst
      }
      $sorted = @($times | Sort-Object)
      $med = $sorted[[int][math]::Floor(($N - 1) / 2)]
      $p90 = $sorted[[int][math]::Ceiling($N * 0.9) - 1]
      Write-Host ('{0,-40} {1,7} {2,7} {3,4}' -f $s.Label, $med, $p90, $rc)
    }
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
