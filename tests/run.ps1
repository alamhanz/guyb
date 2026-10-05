# Runs the PowerShell test files concurrently and prints each log in a fixed order. Works on Windows PowerShell 5.1 and PowerShell 7.
#   pwsh -File tests/run.ps1        powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1
# Children use the current host, so PS 5.1 tests 5.1. Each file uses its own temp dir. Writes nothing in the repo.
# Exit 1 if any file failed. Bash twin: run.sh.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$hostExe = (Get-Process -Id $PID).Path
$names = @('lint', 'smoke', 'secrets', 'tabs', 'statusline', 'permissions')
$jobs = @()
foreach ($n in $names) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $hostExe
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root "tests/$n.ps1") + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $p.StandardInput.Close()
  # read both streams asynchronously so a full pipe never blocks the child
  $jobs += [pscustomobject]@{ Name = $n; Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}
$failed = 0
foreach ($j in $jobs) {
  $j.Proc.WaitForExit()
  $rc = $j.Proc.ExitCode
  Write-Host ("=== {0}.ps1: exit {1}, {2} s" -f $j.Name, $rc, [int][math]::Round(($j.Proc.ExitTime - $j.Proc.StartTime).TotalSeconds))
  Write-Host (($j.Out.Result + $j.Err.Result).TrimEnd())
  if ($rc -ne 0) { $failed++ }
}
if ($failed -gt 0) { Write-Host "run: $failed file(s) failed"; exit 1 }
Write-Host 'run: all ok'
