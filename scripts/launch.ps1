# guyb launcher for PowerShell 7+ (Windows Terminal aware).
# Dot-source from your $PROFILE:   . "<repo>\scripts\launch.ps1"
#
#   guyb               -> pick a project from $env:GUYB_ROOT (or the current folder) and open it
#   guyb myapp         -> open <root>\myapp in a new tab
#   guyb D:\code\x     -> open an absolute path in a new tab
#   guyb myapp -Here   -> run in the current terminal instead of a new tab

function guyb {
    param(
        [string]$Path,
        [switch]$Here
    )

    $root = if ($env:GUYB_ROOT) { $env:GUYB_ROOT } else { (Get-Location).Path }

    if (-not $Path) {
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name)
        if ($dirs.Count -eq 0) { Write-Error "No project folders in $root"; return }
        for ($i = 0; $i -lt $dirs.Count; $i++) { '{0,3}) {1}' -f ($i + 1), $dirs[$i].Name }
        $choice = Read-Host 'Project number'
        if (-not ($choice -as [int]) -or [int]$choice -lt 1 -or [int]$choice -gt $dirs.Count) { Write-Error 'Invalid choice'; return }
        $target = $dirs[[int]$choice - 1].FullName
    }
    elseif (Test-Path -LiteralPath $Path -PathType Container) {
        $target = (Resolve-Path -LiteralPath $Path).Path
    }
    elseif (Test-Path -LiteralPath (Join-Path $root $Path) -PathType Container) {
        $target = (Resolve-Path -LiteralPath (Join-Path $root $Path)).Path
    }
    else {
        Write-Error "Project not found: $Path (root: $root)"; return
    }

    $name = Split-Path $target -Leaf

    if ($Here) {
        Push-Location -LiteralPath $target
        try { claude /guyb:start } finally { Pop-Location }
        return
    }

    # The new tab inherits this process's environment. When called from inside a Claude Code
    # session (an agent running the launcher), drop the session's variables (NO_COLOR, CLAUDECODE,
    # CLAUDE_CODE_*) so the new claude starts as a normal, colored top-level session.
    if ($env:CLAUDECODE) {
        Get-ChildItem env: | Where-Object { $_.Name -in 'NO_COLOR', 'CLAUDECODE', 'CLAUDE_PID' -or $_.Name -like 'CLAUDE_CODE_*' } |
            ForEach-Object { Remove-Item -LiteralPath "env:$($_.Name)" }
    }

    $shell = (Get-Process -Id $PID).Path
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        # -w 0 = open the tab in the current Windows Terminal window.
        # -p picks the Terminal profile (icon, colors, background). Default: the profile of the
        # tab you launch from (WT_PROFILE_ID). Override with $env:GUYB_WT_PROFILE (name or GUID).
        $wtProfile = if ($env:GUYB_WT_PROFILE) { $env:GUYB_WT_PROFILE }
                     elseif ($env:WT_PROFILE_ID) { $env:WT_PROFILE_ID }
                     elseif ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' }
                     else { 'Windows PowerShell' }
        wt.exe -w 0 new-tab -p $wtProfile --title $name --startingDirectory $target $shell -NoExit -Command claude /guyb:start
    }
    else {
        Start-Process -FilePath $shell -WorkingDirectory $target -ArgumentList '-NoExit', '-Command', 'claude /guyb:start'
    }
    Write-Host "Opened '$name' -> $target"
}
