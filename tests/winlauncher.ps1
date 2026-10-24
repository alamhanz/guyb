# Tests for the Windows launcher pieces: scripts/winlauncher.ps1 (user PATH and Git Bash rc helpers) and the
# scripts/guyb.cmd + guyb.ps1 shim (dry run). Windows only (prints "skip" elsewhere).
# Works on Windows PowerShell 5.1 and PowerShell 7:   pwsh -File tests/winlauncher.ps1
# Never touches the real user PATH, GUYB_ROOT, ~/.bashrc or $PROFILE: the PATH helper runs against scratch registry keys
# (HKCU:\Software\guyb-test-*), the rc helper against temp files, and the shim with GUYB_DRYRUN=1 in a temp projects folder.
$ErrorActionPreference = 'Continue'
if ($env:OS -ne 'Windows_NT') { Write-Host 'skip: Windows only'; exit 0 }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function Ok { $script:pass++ }
function No($msg) { $script:fail++; Write-Host "FAIL: $msg" }
function Expect-Eq($label, $got, $want) { if ("$got" -eq "$want") { Ok } else { No "${label}: got '$got', want '$want'" } }
function Expect-Has($label, $text, $want) { if ("$text".Contains($want)) { Ok } else { No "${label}: missing '$want' in '$text'" } }

. (Join-Path $root 'scripts\winlauncher.ps1')

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('guyb-winlauncher-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$keys = @()
$savedRoot = $env:GUYB_ROOT; $savedDry = $env:GUYB_DRYRUN
try {
  # --- Add-GuybUserPath on scratch keys ---
  function New-ScratchKey($name, $path) {
    $sub = "Software\guyb-test-$PID-$name"
    $script:keys += $sub
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($sub)
    if ($null -ne $path) { $k.SetValue('Path', $path, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    $k.Dispose()
    return $sub
  }
  function Read-Raw($sub) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub)
    $v = [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = $k.GetValueKind('Path'); $k.Dispose()
    return @($v, "$kind")
  }
  $dir = Join-Path $tmp 'repo\scripts'

  $sub = New-ScratchKey 'a' ('%SystemRoot%\x;' + $dir + '\')
  Expect-Eq 'trailing-slash variant is present' (Add-GuybUserPath -Dir $dir -SubKey $sub) 'present'
  Expect-Eq 'present leaves the value alone' (Read-Raw $sub)[0] ('%SystemRoot%\x;' + $dir + '\')

  $sub = New-ScratchKey 'b' '%SystemRoot%\x'
  Expect-Eq 'first call adds' (Add-GuybUserPath -Dir $dir -SubKey $sub) 'added'
  Expect-Eq 'previous value reported' $script:GuybPathPrevious '%SystemRoot%\x'
  Expect-Eq 'second call is present' (Add-GuybUserPath -Dir $dir -SubKey $sub) 'present'
  $raw = Read-Raw $sub
  Expect-Eq 'value keeps %VAR% entry and appends once' $raw[0] ('%SystemRoot%\x;' + $dir)
  Expect-Eq 'value kind stays ExpandString' $raw[1] 'ExpandString'

  $sub = New-ScratchKey 'c' $null
  Expect-Eq 'empty Path: added' (Add-GuybUserPath -Dir $dir -SubKey $sub) 'added'
  Expect-Eq 'empty Path: value is just the dir' (Read-Raw $sub)[0] $dir

  $sub = New-ScratchKey 'd' ('"' + $dir.ToUpper() + '";C:\other')
  Expect-Eq 'quoted, other-case entry is present' (Add-GuybUserPath -Dir $dir -SubKey $sub) 'present'

  # --- Add-GuybBashrc on temp files ---
  $rc = Join-Path $tmp 'bashrc1'
  [IO.File]::WriteAllText($rc, 'export A=1', (New-Object Text.UTF8Encoding($false)))
  $repoDir = 'D:\some dir\guyb'
  Expect-Eq 'bashrc first call adds' (Add-GuybBashrc -Path $rc -Repo $repoDir) 'added'
  $bytes = [IO.File]::ReadAllBytes($rc)
  Expect-Eq 'bashrc has no CR' (@($bytes | Where-Object { $_ -eq 13 }).Count) 0
  $text = [IO.File]::ReadAllText($rc)
  Expect-Eq 'bashrc content' $text "export A=1`n`n# guyb`nsource `"D:/some dir/guyb/scripts/launch.sh`"`n"
  Expect-Eq 'bashrc second call is present' (Add-GuybBashrc -Path $rc -Repo $repoDir) 'present'
  Expect-Eq 'bashrc unchanged by second call' ([IO.File]::ReadAllText($rc)) $text

  $rc2 = Join-Path $tmp 'bashrc2'
  Expect-Eq 'new bashrc: added' (Add-GuybBashrc -Path $rc2 -Repo $repoDir -Root 'D:\projects') 'added'
  $bytes = [IO.File]::ReadAllBytes($rc2)
  Expect-Eq 'new bashrc has no BOM' (($bytes[0] -ne 0xEF)) $true
  Expect-Eq 'new bashrc content' ([IO.File]::ReadAllText($rc2)) "`n# guyb`nsource `"D:/some dir/guyb/scripts/launch.sh`"`nexport GUYB_ROOT=`"D:/projects`"`n"

  # --- shim, dry run ---
  $proj = Join-Path $tmp 'projects'
  New-Item -ItemType Directory -Force -Path (Join-Path $proj 'p1') | Out-Null
  $env:GUYB_ROOT = $proj; $env:GUYB_DRYRUN = '1'
  $cmd = Join-Path $root 'scripts\guyb.cmd'
  $out = (& cmd.exe /c "`"$cmd`" p1 -Here" 2>&1 | ForEach-Object { "$_" }) -join "`n"
  Expect-Has 'guyb.cmd p1 -Here prints a here: line' $out 'here:'
  Expect-Has 'guyb.cmd p1 -Here names the project' $out 'p1'
  $out = (& cmd.exe /c "`"$cmd`" -List" 2>&1 | ForEach-Object { "$_" }) -join "`n"
  Expect-Has 'guyb.cmd -List has the project line' $out "p1`t$(Join-Path $proj 'p1')"
  if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\guyb.ps1') -List 2>&1 | ForEach-Object { "$_" }) -join "`n"
    Expect-Has 'powershell guyb.ps1 -List has the project line' $out "p1`t$(Join-Path $proj 'p1')"
  }
} finally {
  foreach ($s in $keys) { try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($s, $false) } catch { } }
  $env:GUYB_ROOT = $savedRoot; $env:GUYB_DRYRUN = $savedDry
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "winlauncher: $($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
