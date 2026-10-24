#Requires -Version 7
<#
.SYNOPSIS
  Installs the guyb plugin, merges recommended permissions, and adds the `guyb` launcher (PowerShell profile, user PATH shim for cmd/PowerShell, Git Bash ~/.bashrc).
.EXAMPLE
  ./scripts/install.ps1 -ProjectsRoot D:\projects
.EXAMPLE
  ./scripts/install.ps1 -SkipPermissions
#>
param(
    [string]$ProjectsRoot,
    [switch]$SkipPermissions,
    [switch]$SkipLauncher
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { throw 'Claude Code (`claude`) is not on PATH. Install it first: https://code.claude.com/docs' }

Write-Host '1/3 Installing plugin...' -ForegroundColor Cyan
# tolerate non-zero exits that only mean "already added/installed" so re-running the installer works
$o = claude plugin marketplace add $repo 2>&1 | Out-String
Write-Host $o.TrimEnd()
if ($LASTEXITCODE -ne 0 -and $o -notmatch 'already') { throw 'claude plugin marketplace add failed' }
$o = claude plugin install guyb@guyb 2>&1 | Out-String
Write-Host $o.TrimEnd()
if ($LASTEXITCODE -ne 0 -and $o -notmatch 'already') { throw 'claude plugin install guyb@guyb failed' }

if (-not $SkipPermissions) {
    Write-Host '2/3 Merging recommended permissions into ~/.claude/settings.json...' -ForegroundColor Cyan
    $settingsPath = Join-Path $HOME '.claude/settings.json'
    $settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    if (Test-Path -LiteralPath $settingsPath) { Copy-Item -LiteralPath $settingsPath "$settingsPath.bak-$(Get-Date -Format yyyyMMddHHmmss)" }
    if (-not $settings) { $settings = @{} }
    $recommended = Get-Content (Join-Path $repo 'settings/recommended-permissions.json') -Raw | ConvertFrom-Json -AsHashtable
    if (-not $settings.ContainsKey('permissions')) { $settings['permissions'] = @{} }
    $obsolete = @($recommended['obsolete'])
    foreach ($key in 'allow', 'ask', 'deny') {
        if ($recommended.permissions.ContainsKey($key)) {
            # drop rules that older guyb versions added but no longer recommends, then add the current ones
            $existing = @($settings.permissions[$key] | Where-Object { $_ -and $_ -notin $obsolete })
            $settings.permissions[$key] = @($existing + $recommended.permissions[$key] | Select-Object -Unique)
        }
    }
    New-Item -ItemType Directory -Force (Split-Path $settingsPath) | Out-Null
    $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding utf8
    Write-Host "   merged (backup kept next to settings.json)"
}
else { Write-Host '2/3 Skipped permissions.' }

if (-not $SkipLauncher) {
    Write-Host '3/3 Adding `guyb` launcher (PowerShell profile, user PATH, Git Bash)...' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $PROFILE)) { New-Item -ItemType File -Force $PROFILE | Out-Null }
    # An empty profile reads as $null, which breaks string checks below
    $profileText = Get-Content -LiteralPath $PROFILE -Raw
    if ($null -eq $profileText) { $profileText = '' }
    $lines = @()
    $sourceLine = ". '$((Join-Path $repo 'scripts/launch.ps1') -replace "'", "''")'"
    if (-not $profileText.Contains($sourceLine)) { $lines += $sourceLine }
    if ($ProjectsRoot -and -not $profileText.Contains('GUYB_ROOT')) { $lines += "`$env:GUYB_ROOT = '$($ProjectsRoot -replace "'", "''")'" }
    if ($lines) { Add-Content -Path $PROFILE -Value ("`n# guyb`n" + ($lines -join "`n")) }
    Write-Host ("   PowerShell profile {0}: {1}" -f $PROFILE, $(if ($lines) { 'added' } else { 'already present' }))

    # guyb.cmd / guyb.ps1 in <repo>\scripts on the user PATH: cmd, Win+R, Windows PowerShell and pwsh. The shim runs -NoProfile, so GUYB_ROOT goes in the user environment too.
    . (Join-Path $PSScriptRoot 'winlauncher.ps1')
    $scriptsDir = Join-Path $repo 'scripts'
    $r = Add-GuybUserPath -Dir $scriptsDir
    Write-Host "   user PATH $scriptsDir`: $(if ($r -eq 'added') { 'added' } else { 'already present' })"
    if ($r -eq 'added') { Write-Host "   previous user PATH was: $script:GuybPathPrevious" }
    if ($ProjectsRoot) {
        $r = Set-GuybUserRoot -Root $ProjectsRoot
        Write-Host "   user GUYB_ROOT: $(if ($r -eq 'added') { "set to $ProjectsRoot" } else { 'already set, left as is' })"
    }
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        $bashrc = Join-Path $HOME '.bashrc'
        $r = Add-GuybBashrc -Path $bashrc -Repo $repo
        Write-Host "   Git Bash $bashrc`: $(if ($r -eq 'added') { 'added' } else { 'already present' })"
        $bashProfile = Join-Path $HOME '.bash_profile'
        if ((Test-Path -LiteralPath $bashProfile) -and ((Get-Content -LiteralPath $bashProfile -Raw) -notmatch '\.bashrc')) {
            Write-Host "   hint: $bashProfile does not mention .bashrc; Git Bash login shells may skip the guyb line. Add: [ -f ~/.bashrc ] && . ~/.bashrc"
        }
    }
}
else { Write-Host '3/3 Skipped launcher.' }

Write-Host "`nDone. Open a NEW terminal (running shells do not see the PATH change), then run:  guyb" -ForegroundColor Green
