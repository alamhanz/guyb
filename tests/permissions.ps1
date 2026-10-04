# Data-driven check of settings/recommended-permissions.json against tests/permission-cases.json.
# Works on Windows PowerShell 5.1 and PowerShell 7. Read-only; writes nothing.
#
#   pwsh -File tests/permissions.ps1 [-SettingsPath <file>] [-CasesPath <file>]
#
# Exit 0 = every case and every symmetry check passed, 1 = at least one failure.
param(
  [string]$SettingsPath,
  [string]$CasesPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $SettingsPath) { $SettingsPath = Join-Path $root 'settings/recommended-permissions.json' }
if (-not $CasesPath)    { $CasesPath    = Join-Path $PSScriptRoot 'permission-cases.json' }

Write-Host '== permission rule check =='
Write-Host 'NOTE: this matcher is an approximation written from the documented permission'
Write-Host 'rules. Real Claude Code behavior can differ. A pass is evidence, not proof.'
Write-Host 'Verify surprising cases in a live session. Not modeled: env-var prefixes,'
Write-Host 'wrappers (timeout), redirections, quoting. Compound commands are split on'
Write-Host '&& || ; | without quote awareness; the most restrictive part wins.'
Write-Host ('settings: ' + $SettingsPath)
Write-Host ('cases:    ' + $CasesPath)

$settings = [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
$parsed = [System.IO.File]::ReadAllText($CasesPath) | ConvertFrom-Json
$cases = @($parsed | ForEach-Object { $_ })

$lists = @{
  allow = @($settings.permissions.allow | ForEach-Object { $_ })
  ask   = @($settings.permissions.ask   | ForEach-Object { $_ })
  deny  = @($settings.permissions.deny  | ForEach-Object { $_ })
}
$obsolete = @($settings.obsolete | ForEach-Object { $_ })

# Rules for one tool, with the Tool( ) wrapper stripped.
function Get-ToolRules([string[]]$rules, [string]$tool) {
  $prefix = $tool + '('
  $out = @()
  foreach ($r in $rules) {
    if ($r.StartsWith($prefix) -and $r.EndsWith(')')) {
      $out += $r.Substring($prefix.Length, $r.Length - $prefix.Length - 1)
    }
  }
  return $out
}

# Glob to regex. A trailing " *" matches the bare prefix too; "*" elsewhere is any chars.
function ConvertTo-RuleRegex([string]$rule, [bool]$ignoreCase) {
  $optional = $false
  if ($rule.EndsWith(' *')) {
    $optional = $true
    $rule = $rule.Substring(0, $rule.Length - 2)
  }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('^')
  foreach ($ch in $rule.ToCharArray()) {
    if ($ch -eq '*') { [void]$sb.Append('.*') }
    else { [void]$sb.Append([regex]::Escape([string]$ch)) }
  }
  if ($optional) { [void]$sb.Append('(?: .*)?') }
  [void]$sb.Append('$')
  $opts = [System.Text.RegularExpressions.RegexOptions]::Singleline
  if ($ignoreCase) { $opts = $opts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
  return New-Object System.Text.RegularExpressions.Regex($sb.ToString(), $opts)
}

function Test-AnyMatch($regexes, [string]$cmd) {
  foreach ($re in $regexes) { if ($re.IsMatch($cmd)) { return $true } }
  return $false
}

$severity = @{ allow = 0; none = 1; ask = 2; deny = 3 }

function Get-Decision([string]$cmd, [string]$tool) {
  $ic = ($tool -eq 'PowerShell')
  $rx = @{}
  foreach ($k in @('allow', 'ask', 'deny')) {
    $rx[$k] = @(Get-ToolRules $lists[$k] $tool | ForEach-Object { ConvertTo-RuleRegex $_ $ic })
  }
  $worst = $null
  foreach ($part in [regex]::Split($cmd, '&&|\|\||;|\|')) {
    $p = $part.Trim()
    if ($p -eq '') { continue }
    if (Test-AnyMatch $rx['deny'] $p) { $d = 'deny' }
    elseif (Test-AnyMatch $rx['ask'] $p) { $d = 'ask' }
    elseif (Test-AnyMatch $rx['allow'] $p) { $d = 'allow' }
    else { $d = 'none' }
    if ($null -eq $worst -or $severity[$d] -gt $severity[$worst]) { $worst = $d }
  }
  if ($null -eq $worst) { $worst = 'none' }
  return $worst
}

$failures = New-Object System.Collections.ArrayList
$checked = 0

foreach ($c in $cases) {
  $tools = @('Bash', 'PowerShell')
  if ($c.tool -eq 'Bash') { $tools = @('Bash') }
  elseif ($c.tool -eq 'PowerShell') { $tools = @('PowerShell') }
  foreach ($t in $tools) {
    $checked++
    $got = Get-Decision ([string]$c.cmd) $t
    $ok = $false
    if ($c.expect -eq 'not-deny') { $ok = ($got -ne 'deny') }
    else { $ok = ($got -eq $c.expect) }
    if (-not $ok) {
      [void]$failures.Add(('case [{0}] {1} : expected {2}, got {3}' -f $t, $c.cmd, $c.expect, $got))
    }
  }
}
Write-Host ('cases checked: ' + $checked)

# Symmetry: Bash(x) <-> PowerShell(x) within each list.
foreach ($k in @('allow', 'ask', 'deny')) {
  $b = @(Get-ToolRules $lists[$k] 'Bash')
  $p = @(Get-ToolRules $lists[$k] 'PowerShell')
  foreach ($x in $b) { if ($p -cnotcontains $x) { [void]$failures.Add(('asymmetry [{0}]: Bash({1}) has no PowerShell twin' -f $k, $x)) } }
  foreach ($x in $p) { if ($b -cnotcontains $x) { [void]$failures.Add(('asymmetry [{0}]: PowerShell({1}) has no Bash twin' -f $k, $x)) } }
  $seen = @{}
  foreach ($r in $lists[$k]) {
    if ($seen.ContainsKey($r)) { [void]$failures.Add(('duplicate in {0}: {1}' -f $k, $r)) }
    $seen[$r] = $true
  }
}

# No rule in two lists, none of the obsolete rules still present.
$where = @{}
foreach ($k in @('allow', 'ask', 'deny')) {
  foreach ($r in $lists[$k]) {
    if ($where.ContainsKey($r) -and $where[$r] -ne $k) {
      [void]$failures.Add(('rule in two lists ({0} and {1}): {2}' -f $where[$r], $k, $r))
    }
    $where[$r] = $k
  }
}
foreach ($o in $obsolete) {
  if ($where.ContainsKey($o)) { [void]$failures.Add(('obsolete rule still in {0}: {1}' -f $where[$o], $o)) }
}

# Read() deny entries (path rules, not command-matched).
$readDeny = @($lists['deny'] | Where-Object { $_.StartsWith('Read(') })
$required = @(
  @('.env', '**/.env)'),
  @('.pem', '**/*.pem)'),
  @('.key', '**/*.key)'),
  @('id_rsa', '**/id_rsa)'),
  @('aws credentials', '.aws/credentials)'),
  @('azure', '.azure/')
)
foreach ($req in $required) {
  $hit = $false
  foreach ($r in $readDeny) { if ($r.Contains($req[1])) { $hit = $true } }
  if (-not $hit) { [void]$failures.Add(('Read deny list is missing the ' + $req[0] + ' entry')) }
}

if ($failures.Count -gt 0) {
  Write-Host ''
  Write-Host ('FAIL: {0} problem(s)' -f $failures.Count)
  foreach ($f in $failures) { Write-Host ('  - ' + $f) }
  exit 1
}
Write-Host 'PASS: all permission cases and symmetry checks (approximate matcher)'
exit 0
