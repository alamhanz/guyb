# guyb status line for Claude Code: prints one line "guyb > <project>  <branch>  N running  M question(s)".
# Read-only, no network, no gh, no git subprocess, ASCII only, never prompts, always exits 0.
# Location independent: Claude Code runs it from settings.json (setup copies it to ~/.claude/guyb/).
# Reads the session JSON on stdin (workspace.current_dir, then cwd, then the current dir); stdin read is capped and times out.
# Registry: <root>/.claude/guyb/pipeline/{runs,questions}.md, else the legacy .claude/pipeline/ copy when
# the legacy .claude/STATE.md is guyb-owned.
# Typical runtime: PowerShell startup dominates (150-400 ms on Windows, less elsewhere); acceptable because
# Claude Code debounces status line updates.
# Bash twin: guyb-status.sh (keep the rules in sync). Works on pwsh 7 and Windows PowerShell 5.1.
$ErrorActionPreference = 'SilentlyContinue'

function Read-Stdin {
    try {
        if (-not [Console]::IsInputRedirected) { return '' }
        $s = [Console]::OpenStandardInput()
        $buf = New-Object byte[] 65536
        $got = 0
        while ($got -lt $buf.Length) {
            $t = $s.ReadAsync($buf, $got, $buf.Length - $got)
            if (-not $t.Wait(2000)) { break }
            if ($t.Result -le 0) { break }
            $got += $t.Result
        }
        return [Text.Encoding]::UTF8.GetString($buf, 0, $got)
    } catch { return '' }
}

function Get-Ascii([string]$s) {
    # one ? per UTF-8 byte, same as the bash twin
    $ev = [Text.RegularExpressions.MatchEvaluator]{ param($m) '?' * [Text.Encoding]::UTF8.GetByteCount($m.Value) }
    return [regex]::Replace($s, '[^\x20-\x7E]', $ev)
}

function Test-Owned([string]$state) {
    # legacy STATE.md is guyb's: marker line, or all four headings (any level, case-insensitive)
    if (-not [IO.File]::Exists($state)) { return $false }
    $a = $false; $b = $false; $c = $false; $d = $false
    foreach ($raw in [IO.File]::ReadAllLines($state)) {
        $l = $raw.TrimEnd("`r").TrimStart([char]0xFEFF)
        if ($l -ceq '<!-- guyb:state -->') { return $true }
        if ($l -imatch '^#+[ \t]*next up[ \t]*$') { $a = $true }
        if ($l -imatch '^#+[ \t]*open issues[ \t]*$') { $b = $true }
        if ($l -imatch '^#+[ \t]*decisions[ \t]*$') { $c = $true }
        if ($l -imatch '^#+[ \t]*recent changes[ \t]*$') { $d = $true }
    }
    return ($a -and $b -and $c -and $d)
}

function Get-Count([string]$path, [int]$defCell, [string[]]$idNames, [string]$want) {
    # rows whose Status cell equals $want; columns found by header name
    if (-not $path) { return 0 }
    $n = 0; $seen = $false; $sc = 0; $ic = 0
    foreach ($raw in [IO.File]::ReadAllLines($path)) {
        $line = $raw.TrimStart([char]0xFEFF)
        if ($line.IndexOf('|') -lt 0) { continue }
        $p = $line.Split('|')
        if (-not $seen) {
            $seen = $true
            for ($i = 0; $i -lt $p.Length; $i++) {
                $t = $p[$i].Trim().ToLowerInvariant()
                if ($t -eq 'status') { $sc = $i }
                if ($t -and ($idNames -contains $t)) { $ic = $i }
            }
            if ($sc) { if (-not $ic) { $ic = 1 }; continue }
            $sc = $defCell; $ic = 1
        }
        if ($ic -ge $p.Length -or $sc -ge $p.Length) { continue }
        $id = $p[$ic].Trim()
        if ($id -eq '' -or $id -match '^[-: ]+$') { continue }
        if ($p[$sc].Trim().ToLowerInvariant() -eq $want) { $n++ }
    }
    return $n
}

function Find-Up([string]$start, [string[]]$names) {
    # first dir from $start up (max 6 parents) holding any of $names, else $null
    $d = $start
    for ($i = 0; $i -le 6 -and $d; $i++) {
        foreach ($n in $names) {
            # ~/.claude/guyb holds user-level files (the copied scripts), not a project
            if ($n -eq '.claude/guyb' -and $d -ieq $script:userHome) { continue }
            $q = Join-Path $d $n
            if ([IO.Directory]::Exists($q) -or [IO.File]::Exists($q)) { return $d }
        }
        $d = [IO.Path]::GetDirectoryName($d)
    }
    return $null
}

$out = 'guyb'
$userHome = [Environment]::GetFolderPath('UserProfile')
try {
    $dir = $null
    $raw = (Read-Stdin).TrimStart([char]0xFEFF)
    if ($raw.Trim()) {
        try {
            $j = $raw | ConvertFrom-Json
            foreach ($c in @($j.workspace.current_dir, $j.cwd)) {
                if ($c -is [string] -and $c -and [IO.Directory]::Exists($c)) { $dir = $c; break }
            }
        } catch { }
    }
    if (-not $dir) { $dir = (Get-Location).ProviderPath }
    $dir = [IO.Path]::GetFullPath($dir)

    $root = $dir
    $r = Find-Up $dir @('.claude/guyb', '.git')
    if ($r) { $root = $r }
    $project = Get-Ascii ([IO.Path]::GetFileName($root.TrimEnd('\', '/')))
    if ($project) { $out = "guyb > $project" }

    $branch = ''
    $gr = Find-Up $dir @('.git')
    if ($gr) {
        $g = Join-Path $gr '.git'
        if ([IO.File]::Exists($g)) {
            $line = ([IO.File]::ReadAllText($g) -split "`n")[0].TrimEnd("`r")
            if ($line.StartsWith('gitdir: ')) {
                $g = $line.Substring(8)
                if (-not [IO.Path]::IsPathRooted($g)) { $g = Join-Path $gr $g }
            } else { $g = $null }
        }
        if ($g) {
            $hf = Join-Path $g 'HEAD'
            if ([IO.File]::Exists($hf)) {
                $h = ([IO.File]::ReadAllText($hf) -split "`n")[0].TrimEnd("`r")
                if ($h.StartsWith('ref: refs/heads/')) { $branch = $h.Substring(16) }
                elseif ($h.StartsWith('ref: ')) { $branch = $h.Substring(5) }
                elseif ($h.Length -ge 9) { $branch = $h.Substring(0, 7) }
                $branch = Get-Ascii $branch
            }
        }
    }

    $legacy = $null
    function Get-Reg([string]$name) {
        $new = Join-Path $root ".claude/guyb/pipeline/$name"
        if ([IO.File]::Exists($new)) { return $new }
        $old = Join-Path $root ".claude/pipeline/$name"
        if ([IO.File]::Exists($old)) {
            if ($null -eq $script:legacy) { $script:legacy = Test-Owned (Join-Path $root '.claude/STATE.md') }
            if ($script:legacy) { return $old }
        }
        return $null
    }
    $running = Get-Count (Get-Reg 'runs.md') 7 @('id') 'running'
    $questions = Get-Count (Get-Reg 'questions.md') 6 @('q', 'id') 'open'

    if ($branch) { $out += "  $branch" }
    if ($running -gt 0) { $out += "  $running running" }
    if ($questions -eq 1) { $out += '  1 question' }
    elseif ($questions -gt 1) { $out += "  $questions questions" }
} catch { }
[Console]::Out.WriteLine($out)
exit 0
