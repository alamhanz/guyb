# guyb launcher for PowerShell 7+ (Windows Terminal aware).
# Dot-source from your $PROFILE:   . "<repo>\scripts\launch.ps1"
#
#   guyb               -> pick a project from $env:GUYB_ROOT (or the current folder) and open it
#   guyb myapp         -> open <root>\myapp in a new tab
#   guyb D:\code\x     -> open an absolute path in a new tab
#   guyb myapp -Here   -> run in the current terminal instead of a new tab
#   guyb -List         -> print the projects (tab-separated, most recent first) and return; never prompts
#   Every launched claude gets CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 so the tab keeps the project title.

# Tabs: the project name locks the tab title and tints it from a fixed palette.
#   $env:GUYB_DRYRUN=1 prints the launch command line (wt: / here:) and launches nothing.

# Strip control chars (C0, DEL, C1 U+0080-U+009F) from a name before it reaches a title.
function _guyb_clean([string]$Name) { -join ($Name.ToCharArray() | Where-Object { [int]$_ -gt 31 -and [int]$_ -ne 127 -and ([int]$_ -lt 128 -or [int]$_ -gt 159) }) }

# Tab colour: djb2 (32-bit) over the UTF-8 bytes of the name, mod 8, fixed palette. Same result in launch.sh.
function _guyb_color([string]$Name) {
    $palette = '#E06C75', '#E5A445', '#98C379', '#56B6C2', '#61AFEF', '#C678DD', '#D19A66', '#4DB6AC'
    [long]$h = 5381
    foreach ($b in [Text.Encoding]::UTF8.GetBytes($Name)) { $h = ($h * 33 + $b) % 4294967296 }
    $palette[[int]($h % 8)]
}

# Arguments for `wt.exe new-tab`, as an array (wt splits commands on a bare ';', so ';' in the title, dir and command is escaped).
function _guyb_wt_args([string]$Name, [string]$Target, [string]$Shell, [string]$WtProfile) {
    $title = (_guyb_clean $Name).Replace(';', '\;')
    $dir = $Target.Replace(';', '\;')
    $run = "`$env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE='1'; claude /guyb:start"
    @('-w', '0', 'new-tab', '-p', $WtProfile, '--title', $title, '--suppressApplicationTitle', '--tabColor', (_guyb_color $Name),
      '--startingDirectory', $dir, $Shell, '-NoExit', '-Command', $run.Replace(';', '\;'))
}

function guyb {
    param(
        [string]$Path,
        [switch]$Here,
        [switch]$List
    )

    $root = if ($env:GUYB_ROOT) { $env:GUYB_ROOT } else { (Get-Location).Path }

    if ($List) {
        # Non-interactive: one tab-separated line per project, most recent activity first:
        # name, abs path, last activity (ISO 8601 UTC), is git (y/n), dirty count, has .claude/guyb/STATE.md or legacy .claude/STATE.md (y/n)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { Write-Error "Root not found: $root"; return }
        $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
        Get-ChildItem -LiteralPath $root -Directory | Where-Object { -not $_.Name.StartsWith('.') } | ForEach-Object {
            $when = $_.LastWriteTimeUtc
            $isGit = $hasGit -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git'))
            $dirty = 0
            if ($isGit) {
                $ct = git -C $_.FullName log -1 --format=%ct 2>$null
                if ($ct -as [long]) {
                    $commit = [DateTimeOffset]::FromUnixTimeSeconds([long]$ct).UtcDateTime
                    if ($commit -gt $when) { $when = $commit }
                }
                $dirty = @(git -C $_.FullName status --porcelain 2>$null).Count
            }
            [pscustomobject]@{
                When = $when
                Line = (@($_.Name, $_.FullName, $when.ToString('yyyy-MM-ddTHH:mm:ssZ'), $(if ($isGit) { 'y' } else { 'n' }), $dirty,
                    $(if ((Test-Path -LiteralPath (Join-Path $_.FullName '.claude\guyb\STATE.md')) -or (Test-Path -LiteralPath (Join-Path $_.FullName '.claude\STATE.md'))) { 'y' } else { 'n' })) -join "`t")
            }
        } | Sort-Object When -Descending | ForEach-Object { $_.Line }
        return
    }

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

    $clean = _guyb_clean $name
    $run = "`$env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE='1'; claude /guyb:start"

    if ($Here) {
        if ($env:GUYB_DRYRUN) { "here: osc0 $clean"; "here: cd '$target'; $run"; return }
        [Console]::Write("$([char]27)]0;$clean$([char]7)")
        $prevTitle = $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE
        $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'
        Push-Location -LiteralPath $target
        try { claude /guyb:start } finally {
            Pop-Location
            if ($null -eq $prevTitle) { Remove-Item env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE -ErrorAction SilentlyContinue } else { $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = $prevTitle }
        }
        return
    }

    # The new tab inherits this process's environment. When called from inside a Claude Code
    # session (an agent running the launcher), drop the session's variables (NO_COLOR, CLAUDECODE,
    # CLAUDE_CODE_*) so the new claude starts as a normal, colored top-level session.
    if ($env:CLAUDECODE -and -not $env:GUYB_DRYRUN) {
        Get-ChildItem env: | Where-Object { $_.Name -in 'NO_COLOR', 'CLAUDECODE', 'CLAUDE_PID' -or $_.Name -like 'CLAUDE_CODE_*' } |
            ForEach-Object { Remove-Item -LiteralPath "env:$($_.Name)" }
    }

    $shell = (Get-Process -Id $PID).Path
    $prevTitle = $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        # -w 0 = open the tab in the current Windows Terminal window.
        # -p picks the Terminal profile (icon, colors, background). Default: the profile of the
        # tab you launch from (WT_PROFILE_ID). Override with $env:GUYB_WT_PROFILE (name or GUID).
        $wtProfile = if ($env:GUYB_WT_PROFILE) { $env:GUYB_WT_PROFILE }
                     elseif ($env:WT_PROFILE_ID) { $env:WT_PROFILE_ID }
                     elseif ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' }
                     else { 'Windows PowerShell' }
        $wtArgs = _guyb_wt_args $name $target $shell $wtProfile
        if ($env:GUYB_DRYRUN) {
            'wt: ' + ((@($wtArgs) | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')
            return
        }
        $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'
        try { wt.exe @wtArgs } finally {
            if ($null -eq $prevTitle) { Remove-Item env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE -ErrorAction SilentlyContinue } else { $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = $prevTitle }
        }
    }
    else {
        $osc = "[Console]::Write(([string][char]27 + ']0;' + '$($clean.Replace("'", "''"))' + [char]7)); "
        $spawn = $osc + $run
        if ($env:GUYB_DRYRUN) { "spawn: $spawn"; return }
        $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'
        try { Start-Process -FilePath $shell -WorkingDirectory $target -ArgumentList '-NoExit', '-Command', $spawn } finally {
            if ($null -eq $prevTitle) { Remove-Item env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE -ErrorAction SilentlyContinue } else { $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = $prevTitle }
        }
    }
    Write-Host "Opened '$clean' -> $target"
}
