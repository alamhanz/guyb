# Tests that skills/setup/check.ps1 expands ~, $HOME, ${HOME}, $env:USERPROFILE and $env:HOME in the profile
# lines it reads, and falls back to known_marketplaces.json when the profile path has no launcher (issue #19).
# Works on Windows PowerShell 5.1 and PowerShell 7:   pwsh -File tests/setup-paths.ps1
# Expand-Rc is unit-tested by extracting it from check.ps1. The end-to-end cases run check.ps1 with a fake HOME in
# parallel children; profile lines can only be injected where $PROFILE follows HOME (Linux, macOS), so on Windows
# only the marketplace fallback runs, and only when the real profile has no launcher line. GUYB_HOME and multi-entry
# GUYB_ROOT cases set the variables in the child process env (they win over the real profile and user env), so they
# always run. Temp dir removed on exit.
# Bash twin: setup-paths.sh (keep the cases in sync).
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$check = Join-Path $root 'plugins/guyb/skills/setup/check.ps1'
$ps = (Get-Process -Id $PID).Path
$script:pass = 0; $script:fail = 0
function Ok { $script:pass++ }
function No($msg) { $script:fail++; Write-Host "FAIL: $msg" }
function Expect-Eq($label, $got, $want) { if ("$got" -eq "$want") { Ok } else { No "${label}: got '$got', want '$want'" } }
function Write-File($path, $text) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# unit: Expand-Rc from check.ps1
$ast = [System.Management.Automation.Language.Parser]::ParseFile($check, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Expand-Rc' }, $true)
if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)) } else { No 'Expand-Rc not found in check.ps1' }
if ($fn) {
  foreach ($c in @(
      @('~', $HOME), @('~\r\scripts', "$HOME\r\scripts"), @('~/r', "$HOME/r"),
      @('$HOME\r', "$HOME\r"), @('${HOME}/r', "$HOME/r"), @('$env:USERPROFILE\r', "$HOME\r"), @('$env:HOME/r', "$HOME/r"),
      @('$HOMEX\r', '$HOMEX\r'), @('D:\x\~\r', 'D:\x\~\r'), @('D:/abs/r', 'D:/abs/r'), @('', ''))) {
    Expect-Eq "Expand-Rc '$($c[0])'" (Expand-Rc $c[0]) $c[1]
  }
}

# end to end
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('guyb-setuppaths-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  $sep = [string][IO.Path]::PathSeparator
  function New-Case($name, $profileLines, [bool]$market, $envVars = $null) {
    $h = Join-Path $tmp $name
    New-Item -ItemType Directory -Force -Path (Join-Path $h 'r\scripts'), (Join-Path $h 'p'), (Join-Path $h '.claude\plugins') | Out-Null
    Write-File (Join-Path $h 'r\scripts\launch.ps1') ''
    if ($market) { Write-File (Join-Path $h '.claude\plugins\known_marketplaces.json') ('{"guyb":{"source":{"source":"directory","path":"' + ((Join-Path $h 'r').Replace('\', '\\')) + '"}}}') }
    return [pscustomobject]@{ Name = $name; Home = $h; Lines = $profileLines; Env = $envVars }
  }
  function Start-Case($c) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ps; $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $check + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['HOME'] = $c.Home; $psi.EnvironmentVariables['USERPROFILE'] = $c.Home
    foreach ($v in 'GUYB_ROOT', 'GUYB_HOME', 'CLAUDE_CONFIG_DIR') { [void]$psi.EnvironmentVariables.Remove($v) }
    if ($c.Env) { foreach ($k in $c.Env.Keys) { $psi.EnvironmentVariables[$k] = $c.Env[$k] } }
    $p = [System.Diagnostics.Process]::Start($psi)
    return [pscustomobject]@{ P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Case = $c }
  }

  # is $PROFILE under HOME for a child with a fake HOME?
  $probe = New-Case 'probe' '' $false
  $pi = New-Object System.Diagnostics.ProcessStartInfo
  $pi.FileName = $ps; $pi.Arguments = '-NoProfile -Command "$PROFILE.CurrentUserCurrentHost"'
  $pi.UseShellExecute = $false; $pi.RedirectStandardOutput = $true
  $pi.EnvironmentVariables['HOME'] = $probe.Home; $pi.EnvironmentVariables['USERPROFILE'] = $probe.Home
  $pp = [System.Diagnostics.Process]::Start($pi); $profPath = $pp.StandardOutput.ReadToEnd().Trim(); $pp.WaitForExit()
  $isolated = $profPath.StartsWith($probe.Home, [StringComparison]::OrdinalIgnoreCase)

  $cases = @()
  if ($isolated) {
    $cases += New-Case 'home' '. "$HOME\r\scripts\launch.ps1"' $false
    $cases += New-Case 'userprofile' '. "$env:USERPROFILE\r\scripts\launch.ps1"' $false
    $cases += New-Case 'tilde' ". '~\r\scripts\launch.ps1'`n`$env:GUYB_ROOT = '~\p'" $false
    $cases += New-Case 'mline' ". '~\r\scripts\launch.ps1'`n`$env:GUYB_ROOT = '~/p$sep~/gone'`n`$env:GUYB_HOME = '~/p'" $false
    $cases += New-Case 'brace''. "${HOME}/r/scripts/launch.ps1"' $false
    $cases += New-Case 'fall' '. "$HOME\nope\scripts\launch.ps1"' $true
  } else {
    $real = @($profPath, (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'),
      (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $has = $false
    foreach ($f in $real) { if ((Get-Content -LiteralPath $f -Raw) -match 'scripts[\\/]launch\.ps1') { $has = $true } }
    if ($has) { Write-Host 'skip: real profile has a launcher line; end-to-end cases need an isolated $PROFILE' }
    else { $cases += New-Case 'fall' '' $true }
  }
  # process-env cases: GUYB_ROOT / GUYB_HOME in the child env (empty entry, duplicate, trailing slash, missing entry)
  $hm = Join-Path $tmp 'penv'
  $cases += New-Case 'penv' '' $true @{ GUYB_ROOT = (Join-Path $hm 'p') + "$sep$sep" + (Join-Path $hm 'q') + "\$sep" + (Join-Path $hm 'p') + "$sep" + (Join-Path $hm 'gone') }
  New-Item -ItemType Directory -Force -Path (Join-Path $hm 'q') | Out-Null
  $hh = Join-Path $tmp 'phome'
  $cases += New-Case 'phome' '' $true @{ GUYB_HOME = (Join-Path $hh 'h'); GUYB_ROOT = (Join-Path $hh 'p') }
  New-Item -ItemType Directory -Force -Path (Join-Path $hh 'h') | Out-Null
  $hg = Join-Path $tmp 'phomegone'
  $cases += New-Case 'phomegone' '' $true @{ GUYB_HOME = (Join-Path $hg 'gone'); GUYB_ROOT = (Join-Path $hg 'gone') }
  foreach ($c in $cases) { if ($c.Lines) { Write-File (Join-Path $c.Home ($profPath.Substring($probe.Home.Length).TrimStart('\', '/'))) ($c.Lines + "`n") } }
  $runs = @($cases | ForEach-Object { Start-Case $_ })
  foreach ($r in $runs) {
    $r.P.WaitForExit()
    $obj = $null
    try { $obj = $r.Out.Result | ConvertFrom-Json } catch { }
    $n = $r.Case.Name
    if (-not $obj) { No "${n}: check.ps1 output is not JSON"; continue }
    $l = $obj.checks | Where-Object { $_.id -eq 'launcher' }
    Expect-Eq "$n launcher status" $l.status 'ok'
    if ($r.Case.Env) { } # env cases run with the real profile and user env: the launcher source may vary
    elseif ($n -eq 'fall') { Expect-Eq "$n launcher source" $l.detail 'launcher found (marketplace)' } else { Expect-Eq "$n launcher source" $l.detail 'launcher found (profile line)' }
    if ($n -eq 'tilde') {
      $rt = $obj.checks | Where-Object { $_.id -eq 'root' }
      Expect-Eq "$n root" $rt.detail ('GUYB_ROOT=' + $r.Case.Home + '\p (profile line)')
    }
    $h = $r.Case.Home
    $rt = $obj.checks | Where-Object { $_.id -eq 'root' }
    $hc = $obj.checks | Where-Object { $_.id -eq 'home' }
    if ($n -eq 'mline') {
      Expect-Eq "$n roots" ($obj.roots -join '|') ((Join-Path $h 'p') + '|' + (Join-Path $h 'gone'))
      Expect-Eq "$n root detail" $rt.detail ('GUYB_ROOT entry not found: ' + (Join-Path $h 'gone') + ' (profile line)')
      Expect-Eq "$n home detail" $hc.detail ('GUYB_HOME=' + (Join-Path $h 'p') + ' (profile line)')
    }
    if ($n -eq 'penv') {
      Expect-Eq "$n roots" ($obj.roots -join '|') ((Join-Path $h 'p') + '|' + (Join-Path $h 'q') + '|' + (Join-Path $h 'gone'))
      Expect-Eq "$n root status" $rt.status 'warn'
      Expect-Eq "$n root detail" $rt.detail ('GUYB_ROOT entry not found: ' + (Join-Path $h 'gone') + ' (process env)')
      Expect-Eq "$n root fix" $rt.fix '/guyb:setup layout'
      Expect-Eq "$n home json" $obj.home ''
      Expect-Eq "$n home check" $hc.detail ('GUYB_HOME not set; home = ' + (Join-Path $h 'p'))
    }
    if ($n -eq 'phome') {
      Expect-Eq "$n home json" $obj.home (Join-Path $h 'h')
      Expect-Eq "$n home detail" $hc.detail ('GUYB_HOME=' + (Join-Path $h 'h') + ' (process env)')
      Expect-Eq "$n home status" $hc.status 'ok'
    }
    if ($n -eq 'phomegone') {
      Expect-Eq "$n home status" $hc.status 'warn'
      Expect-Eq "$n home detail" $hc.detail ('GUYB_HOME not found: ' + (Join-Path $h 'gone') + ' (process env)')
      Expect-Eq "$n root status" $rt.status 'warn'
      Expect-Eq "$n roots" ($obj.roots -join '|') (Join-Path $h 'gone')
    }
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "setup-paths: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
