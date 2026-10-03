#Requires -Version 7
<#
.SYNOPSIS
  Installs the guyb plugin, merges recommended permissions, and adds the `guyb` launcher to your PowerShell profile.
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
claude plugin marketplace add $repo
claude plugin install guyb@guyb

if (-not $SkipPermissions) {
    Write-Host '2/3 Merging recommended permissions into ~/.claude/settings.json...' -ForegroundColor Cyan
    $settingsPath = Join-Path $HOME '.claude/settings.json'
    $settings = if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    if (Test-Path $settingsPath) { Copy-Item $settingsPath "$settingsPath.bak-$(Get-Date -Format yyyyMMddHHmmss)" }
    $recommended = Get-Content (Join-Path $repo 'settings/recommended-permissions.json') -Raw | ConvertFrom-Json -AsHashtable
    if (-not $settings.ContainsKey('permissions')) { $settings['permissions'] = @{} }
    foreach ($key in 'allow', 'ask', 'deny') {
        if ($recommended.permissions.ContainsKey($key)) {
            $existing = @($settings.permissions[$key] | Where-Object { $_ })
            $settings.permissions[$key] = @($existing + $recommended.permissions[$key] | Select-Object -Unique)
        }
    }
    New-Item -ItemType Directory -Force (Split-Path $settingsPath) | Out-Null
    $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding utf8
    Write-Host "   merged (backup kept next to settings.json)"
}
else { Write-Host '2/3 Skipped permissions.' }

if (-not $SkipLauncher) {
    Write-Host '3/3 Adding `guyb` launcher to your PowerShell profile...' -ForegroundColor Cyan
    if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Force $PROFILE | Out-Null }
    $profileText = Get-Content $PROFILE -Raw
    $lines = @()
    $sourceLine = ". '$(Join-Path $repo 'scripts/launch.ps1')'"
    if ($profileText -notmatch [regex]::Escape($sourceLine)) { $lines += $sourceLine }
    if ($ProjectsRoot -and $profileText -notmatch 'GUYB_ROOT') { $lines += "`$env:GUYB_ROOT = '$ProjectsRoot'" }
    if ($lines) { Add-Content -Path $PROFILE -Value ("`n# guyb`n" + ($lines -join "`n")) }
    Write-Host "   updated $PROFILE"
}
else { Write-Host '3/3 Skipped launcher.' }

Write-Host "`nDone. Open a new terminal, then run:  guyb" -ForegroundColor Green
