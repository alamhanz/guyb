# Static checks for the guyb repo. Read-only; writes nothing. Works on Windows PowerShell 5.1 and PowerShell 7.
#   pwsh -File tests/lint.ps1
# Checks: every ps1 parses, JSON/SVG are well-formed, ASCII only, sh files LF, ps1 files CRLF.
# Bash twin: lint.sh (runs bash -n; keep the file rules in sync).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$script:fail = 0
function Bad($msg) { Write-Host "FAIL: $msg"; $script:fail++ }

function Get-Files($dirs, $pattern) {
  foreach ($d in $dirs) {
    if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Recurse -File -Filter $pattern }
  }
}
function Rel($f) { $f.FullName.Substring($root.Length + 1).Replace('\', '/') }

$code = @('plugins', 'scripts', 'tests')
$ps1 = @(Get-Files $code '*.ps1')
$sh = @(Get-Files $code '*.sh')
$json = @(Get-Files @('plugins', 'scripts', 'tests', 'settings', '.claude-plugin') '*.json')
$svg = @(Get-Files @('docs') '*.svg')
$text = @($ps1) + @($sh) + @($json) + @($svg) + @(Get-Files @('.github') '*.yml')
if (Test-Path -LiteralPath '.gitattributes') { $text += Get-Item -LiteralPath '.gitattributes' }

Write-Host 'parse ps1'
foreach ($f in $ps1) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
  foreach ($e in $errors) { Bad ("{0}:{1}: {2}" -f (Rel $f), $e.Extent.StartLineNumber, $e.Message) }
}
$inst = Join-Path $root 'scripts/install.ps1'
if (Test-Path -LiteralPath $inst) {
  if (-not (Select-String -LiteralPath $inst -Pattern '^#Requires -Version 7' -Quiet)) { Bad 'scripts/install.ps1: missing #Requires -Version 7' }
}

Write-Host 'json'
foreach ($f in $json) {
  try { [void](Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json) } catch { Bad ("{0}: invalid JSON" -f (Rel $f)) }
}

Write-Host 'svg'
foreach ($f in $svg) {
  try { $x = New-Object System.Xml.XmlDocument; $x.Load($f.FullName) } catch { Bad ("{0}: not well-formed XML" -f (Rel $f)) }
}

Write-Host 'ascii (scripts, JSON, SVG, YAML; Markdown may carry the severity emoji)'
foreach ($f in $text) {
  $n = 0
  foreach ($b in [System.IO.File]::ReadAllBytes($f.FullName)) { if ($b -gt 126 -or ($b -lt 32 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13)) { $n++ } }
  if ($n -gt 0) { Bad ("{0}: {1} non-ASCII or control byte(s)" -f (Rel $f), $n) }
}

Write-Host 'line endings (sh = LF, ps1 = CRLF)'
function Count-Eol($path) {
  $lf = 0; $cr = 0; $crlf = 0; $prev = 0
  foreach ($b in [System.IO.File]::ReadAllBytes($path)) {
    if ($b -eq 10) { $lf++; if ($prev -eq 13) { $crlf++ } } elseif ($b -eq 13) { $cr++ }
    $prev = $b
  }
  return @($lf, $cr, $crlf)
}
foreach ($f in $sh) {
  $c = Count-Eol $f.FullName
  if ($c[1] -gt 0) { Bad ("{0}: sh file contains CR (must be LF)" -f (Rel $f)) }
}
foreach ($f in $ps1) {
  $c = Count-Eol $f.FullName
  if ($c[0] -ne $c[2] -or $c[1] -ne $c[2]) { Bad ("{0}: ps1 file is not CRLF ({1} LF, {2} CR, {3} CRLF)" -f (Rel $f), $c[0], $c[1], $c[2]) }
}

if ($script:fail -gt 0) { Write-Host "lint: $($script:fail) problem(s)"; exit 1 }
Write-Host 'lint: ok'
