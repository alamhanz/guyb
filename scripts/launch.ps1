# guyb launcher for PowerShell 7+ and Windows PowerShell 5.1 (Windows Terminal aware).
# Dot-source from your $PROFILE:   . "<repo>\scripts\launch.ps1"
#
#   guyb               -> pick a project from $env:GUYB_ROOT (or the current folder) and open it
#                         GUYB_ROOT may be a path list (';' on Windows, ':' elsewhere); names in several roots show as "name  [root]"
#   guyb myapp         -> open <root>\myapp in a new tab (name in several roots: error listing full paths; pass the full path)
#   guyb D:\code\x     -> open an absolute path in a new tab
#   guyb myapp -Here   -> run in the current terminal instead of a new tab
#   guyb -List         -> print the projects (tab-separated, most recent first, last column = root) and return; never prompts
#   Every launched claude gets CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 so the tab keeps the project title.

# Tabs: the project name locks the tab title and tints it from a fixed palette.
#   $env:GUYB_DRYRUN=1 prints the launch command line (wt: / here:) and launches nothing.

# Strip control chars (C0, DEL, C1 U+0080-U+009F) from a name before it reaches a title.
function _guyb_clean([string]$Name) { -join ($Name.ToCharArray() | Where-Object { [int]$_ -gt 31 -and [int]$_ -ne 127 -and ([int]$_ -lt 128 -or [int]$_ -gt 159) }) }

# Tab title at launch: "<done icon> <name>" (U+2705, "+" when GUYB_TAB_ASCII=1 or TERM is linux/dumb). plugins/guyb/hooks/tab-status.sh and
# tab-status.ps1 swap the icon as Claude works; they act only when GUYB_TAB_NAME is set, which the launch command line exports.
function _guyb_ascii { ($env:GUYB_TAB_ASCII -eq '1') -or ($env:TERM -eq 'linux') -or ($env:TERM -eq 'dumb') }
function _guyb_title([string]$Name) { $g = if (_guyb_ascii) { '+' } else { [string][char]0x2705 }; "$g $Name" }

# Command run inside the new shell: tab env, initial title (UTF-8 bytes, independent of the console code page), then claude.
function _guyb_run([string]$Clean) {
    $q = $Clean.Replace("'", "''")
    $g = if (_guyb_ascii) { "'+'" } else { '[char]0x2705' }
    "`$env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE='1'; `$env:GUYB_TAB_NAME='$q'; `$o=[Console]::OpenStandardOutput(); `$b=[Text.Encoding]::UTF8.GetBytes([string][char]27+']0;'+$g+' $q'+[char]7); `$o.Write(`$b,0,`$b.Length); claude /guyb:start"
}

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
    $run = _guyb_run (_guyb_clean $Name)
    @('-w', '0', 'new-tab', '-p', $WtProfile, '--title', $title, '--tabColor', (_guyb_color $Name),
      '--startingDirectory', $dir, $Shell, '-NoExit', '-Command', $run.Replace(';', '\;'))
}

# Roots: $env:GUYB_ROOT is a path list (';' on Windows, ':' elsewhere), else the current folder. Entries: trimmed, one pair of
# quotes removed, empties dropped, trailing separators stripped (not on a drive root), duplicates dropped. Missing entries warn
# ("guyb: root not found: <entry>") and are skipped. Returns the existing roots in order.
function _guyb_norm([string]$Path) {
    $full = (Get-Item -LiteralPath $Path).FullName
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd('\', '/') }
    $full
}
function _guyb_key([string]$Path) { if ([IO.Path]::DirectorySeparatorChar -eq '\') { $Path.ToLowerInvariant() } else { $Path } }
function _guyb_roots {
    $raw = if ($env:GUYB_ROOT) { $env:GUYB_ROOT } else { (Get-Location).Path }
    $seen = @{}
    $roots = New-Object System.Collections.ArrayList
    foreach ($e in $raw.Split([IO.Path]::PathSeparator)) {
        $e = $e.Trim()
        if ($e.Length -ge 2 -and (($e[0] -eq '"' -and $e[-1] -eq '"') -or ($e[0] -eq "'" -and $e[-1] -eq "'"))) { $e = $e.Substring(1, $e.Length - 2) }
        if (-not $e) { continue }
        if (-not (Test-Path -LiteralPath $e -PathType Container)) { [Console]::Error.WriteLine("guyb: root not found: $e"); continue }
        $n = _guyb_norm $e
        if ($seen.ContainsKey((_guyb_key $n))) { continue }
        $seen[(_guyb_key $n)] = 1
        [void]$roots.Add($n)
    }
    $roots.ToArray()
}

# Project folders of the roots (Dir, Root, Idx). A folder that is itself a root or $env:GUYB_HOME is not a project.
function _guyb_projects($Roots) {
    $skip = @{}
    foreach ($r in $Roots) { $skip[(_guyb_key $r)] = 1 }
    if ($env:GUYB_HOME -and (Test-Path -LiteralPath $env:GUYB_HOME -PathType Container)) { $skip[(_guyb_key (_guyb_norm $env:GUYB_HOME))] = 1 }
    $i = 0
    foreach ($r in $Roots) {
        foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory | Where-Object { -not $_.Name.StartsWith('.') })) {
            if (-not $skip.ContainsKey((_guyb_key $d.FullName))) { [pscustomobject]@{ Dir = $d; Root = $r; Idx = $i } }
        }
        $i++
    }
}

function guyb {
    param(
        [string]$Path,
        [switch]$Here,
        [switch]$List
    )

    $rootsRaw = if ($env:GUYB_ROOT) { $env:GUYB_ROOT } else { (Get-Location).Path }
    $roots = @(_guyb_roots)
    if ($roots.Count -eq 0 -and ($List -or -not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container))) { Write-Error "Root not found: $rootsRaw"; return }

    if ($List) {
        # Non-interactive: one tab-separated line per project, most recent activity first:
        # name, abs path, last activity (ISO 8601 UTC), is git (y/n), dirty count, has .claude/guyb/STATE.md or legacy .claude/STATE.md (y/n), root
        # PS 5.1 decodes native git output with the OEM code page; read it as UTF-8.
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
        $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
        _guyb_projects $roots | ForEach-Object {
            $proj = $_.Dir; $rootOf = $_.Root
            $when = $proj.LastWriteTimeUtc
            $isGit = $hasGit -and (Test-Path -LiteralPath (Join-Path $proj.FullName '.git'))
            $dirty = 0
            if ($isGit) {
                $ct = git -C $proj.FullName log -1 --format=%ct 2>$null
                if ($ct -as [long]) {
                    $commit = [DateTimeOffset]::FromUnixTimeSeconds([long]$ct).UtcDateTime
                    if ($commit -gt $when) { $when = $commit }
                }
                $dirty = @(git -C $proj.FullName status --porcelain 2>$null).Count
            }
            [pscustomobject]@{
                When = $when
                Line = (@($proj.Name, $proj.FullName, $when.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture), $(if ($isGit) { 'y' } else { 'n' }), $dirty,
                    $(if ((Test-Path -LiteralPath (Join-Path $proj.FullName '.claude\guyb\STATE.md')) -or (Test-Path -LiteralPath (Join-Path $proj.FullName '.claude\STATE.md'))) { 'y' } else { 'n' }), $rootOf) -join "`t")
            }
        } | Sort-Object When -Descending | ForEach-Object { $_.Line }
        return
    }

    if (-not $Path) {
        $projects = @(_guyb_projects $roots | Sort-Object { $_.Dir.Name }, Idx)
        if ($projects.Count -eq 0) { Write-Error "No project folders in $($roots -join '; ')"; return }
        $count = @{}
        foreach ($p in $projects) { $count[$p.Dir.Name] = 1 + [int]$count[$p.Dir.Name] }
        for ($i = 0; $i -lt $projects.Count; $i++) {
            $label = $projects[$i].Dir.Name
            if ($count[$label] -gt 1) { $label = "$label  [$($projects[$i].Root)]" }
            '{0,3}) {1}' -f ($i + 1), $label
        }
        $choice = Read-Host 'Project number'
        if (-not ($choice -as [int]) -or [int]$choice -lt 1 -or [int]$choice -gt $projects.Count) { Write-Error 'Invalid choice'; return }
        $target = $projects[[int]$choice - 1].Dir.FullName
    }
    elseif (Test-Path -LiteralPath $Path -PathType Container) {
        $target = (Resolve-Path -LiteralPath $Path).Path
    }
    else {
        $found = @()
        $seenPaths = @{}
        foreach ($r in $roots) {
            $cand = Join-Path $r $Path
            if (Test-Path -LiteralPath $cand -PathType Container) {
                $full = (Resolve-Path -LiteralPath $cand).Path
                if (-not $seenPaths.ContainsKey((_guyb_key $full))) { $seenPaths[(_guyb_key $full)] = 1; $found += $full }
            }
        }
        if ($found.Count -eq 0) {
            $where = if ($roots.Count -eq 1) { "root: $($roots[0])" } else { "roots: $($roots -join '; ')" }
            Write-Error "Project not found: $Path ($where)"; return
        }
        if ($found.Count -gt 1) {
            Write-Error ("Ambiguous project: $Path is in $($found.Count) roots:`n" + ($found -join "`n") + "`nRun: guyb '$($found[0].Replace("'", "''"))'"); return
        }
        $target = $found[0]
    }

    $name = Split-Path $target -Leaf

    $clean = _guyb_clean $name
    $run = _guyb_run $clean

    if ($Here) {
        if ($env:GUYB_DRYRUN) { "here: osc0 $(_guyb_title $clean)"; "here: cd '$target'; $run"; return }
        $ob = [Text.Encoding]::UTF8.GetBytes("$([char]27)]0;$(_guyb_title $clean)$([char]7)")
        $so = [Console]::OpenStandardOutput(); $so.Write($ob, 0, $ob.Length)
        $prevTitle = $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE; $prevTab = $env:GUYB_TAB_NAME
        $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'; $env:GUYB_TAB_NAME = $clean
        Push-Location -LiteralPath $target
        try { claude /guyb:start } finally {
            Pop-Location
            if ($null -eq $prevTitle) { Remove-Item env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE -ErrorAction SilentlyContinue } else { $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = $prevTitle }
            if ($null -eq $prevTab) { Remove-Item env:GUYB_TAB_NAME -ErrorAction SilentlyContinue } else { $env:GUYB_TAB_NAME = $prevTab }
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
        $spawn = $run
        if ($env:GUYB_DRYRUN) { "spawn: $spawn"; return }
        $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'
        try { Start-Process -FilePath $shell -WorkingDirectory $target -ArgumentList '-NoExit', '-Command', $spawn } finally {
            if ($null -eq $prevTitle) { Remove-Item env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE -ErrorAction SilentlyContinue } else { $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = $prevTitle }
        }
    }
    Write-Host "Opened '$clean' -> $target"
}
