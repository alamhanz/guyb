# guyb PreToolUse guard: block `git commit` when secret-looking files would be committed.
# PowerShell twin of guard-secrets.sh: keep the patterns and the commit-argument rules in both files in sync.
# Exit 2 blocks the tool call and feeds stderr back to Claude; any other exit lets it run.
# Reads the hook JSON on stdin (.tool_input.command, .cwd), finds every `git commit` in the command
# (git -C/-c options, chained commands, Set-Location/cd), works out the repo being committed, and checks
# the index; when the commit stages tracked files itself (-a, -i, -o, pathspecs) it also checks modified
# tracked files. Deleted files never block. The parse is an approximation (no variable expansion);
# trouble of any kind falls back to the index of the process cwd, or allows.
# Works on Windows PowerShell 5.1 and PowerShell 7.

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { exit 0 }

$raw = ''
try { if ([Console]::IsInputRedirected) { $raw = [Console]::In.ReadToEnd() } } catch { $raw = '' }
if ($null -eq $raw) { $raw = '' }
$hasInput = ($raw.Trim() -ne '')
if ($hasInput -and $raw.IndexOf('commit') -lt 0) { exit 0 }

$secret = '(^|/)(\.env(\.[^/]*)?|\.envrc|\.netrc|\.npmrc|\.pypirc|[^/]*\.(pem|key|p12|p8|pfx|jks|keystore|kdbx|tfvars|tfvars\.json)|id_(rsa|ed25519|ecdsa)[^/]*|credentials(\.[^/]*)?|[^/]*service[-_]?account[^/]*\.json)$'
$safe = '\.(example|sample|template|pub)$'

# Returns secret-looking paths for the repo selected by $ga (git global args); $null when git fails.
function Get-Bad($ga, [bool]$all) {
    $files = @(& git @ga -c core.quotepath=off diff --cached --name-only --diff-filter=ACMRT 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($all) {
        $wt = @(& git @ga -c core.quotepath=off diff --name-only --diff-filter=ACMRT 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        $files = $files + $wt
    }
    return @($files | Where-Object { $_ -and $_ -match $secret -and $_ -notmatch $safe } | Sort-Object -Unique)
}

function Block($where, $bad) {
    [Console]::Error.WriteLine("guyb: blocked git commit - secret-looking files would be committed${where}:")
    foreach ($f in $bad) { [Console]::Error.WriteLine("  $f") }
    [Console]::Error.WriteLine('Unstage them (git restore --staged <file>), add them to .gitignore, and commit again.')
    [Console]::Error.WriteLine('If a file is definitely not a secret, ask the user to confirm, then commit it manually.')
    exit 2
}

function Invoke-Fallback {
    $bad = Get-Bad @() $false
    if ($null -ne $bad -and $bad.Count -gt 0) { Block '' $bad }
    exit 0
}

if (-not $hasInput) { Invoke-Fallback }

$cmd = $null; $cwd = $null
try {
    $j = $raw | ConvertFrom-Json
    $cmd = $j.tool_input.command
    $cwd = $j.cwd
} catch { Invoke-Fallback }
if (-not $cmd -or $cmd -isnot [string]) { Invoke-Fallback }

$base = '.'
if ($cwd -is [string] -and $cwd -ne '' -and (Test-Path -LiteralPath $cwd -PathType Container)) { $base = $cwd }

function Test-DirUnknown([string]$s) { return ($s.Contains('$') -or $s.Contains('(')) }
function Test-GitWord([string]$s) { return ($s -match '^(.*[\\/])?git(\.exe)?$') }

# Split the command into segments (arrays of words): quotes joined into words, separators end a segment.
function Split-Segments([string]$text) {
    $segs = New-Object System.Collections.ArrayList
    $words = New-Object System.Collections.ArrayList
    $cur = New-Object System.Text.StringBuilder
    $inw = $false; $skipnext = $false; $state = 0
    $n = $text.Length
    for ($p = 0; $p -lt $n; $p++) {
        $c = $text[$p]
        if ($state -eq 1) {
            if ($c -eq "'") {
                if ($p + 1 -lt $n -and $text[$p + 1] -eq "'") { [void]$cur.Append("'"); $p++ } else { $state = 0 }
            } elseif ($c -eq "`n" -or $c -eq "`r") { [void]$cur.Append(' ') } else { [void]$cur.Append($c) }
            continue
        }
        if ($state -eq 2) {
            if ($c -eq '"') {
                if ($p + 1 -lt $n -and $text[$p + 1] -eq '"') { [void]$cur.Append('"'); $p++ } else { $state = 0 }
            } elseif ($c -eq '`') {
                if ($p + 1 -lt $n) { [void]$cur.Append($text[$p + 1]); $p++ }
            } elseif ($c -eq "`n" -or $c -eq "`r") { [void]$cur.Append(' ') } else { [void]$cur.Append($c) }
            continue
        }
        $sep = $false; $ws = $false
        if ($c -eq "'") { $state = 1; $inw = $true }
        elseif ($c -eq '"') { $state = 2; $inw = $true }
        elseif ($c -eq '`') {
            if ($p + 1 -lt $n) { $x = $text[$p + 1]; $p++; if ($x -ne "`n" -and $x -ne "`r") { [void]$cur.Append($x); $inw = $true } }
        }
        elseif ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`r") { $ws = $true }
        elseif ($c -eq "`n" -or $c -eq ';' -or $c -eq '|' -or $c -eq '&') { $sep = $true }
        elseif (($c -eq '(' -or $c -eq ')') -and -not $inw -and $words.Count -eq 0) { $ws = $true }
        else { [void]$cur.Append($c); $inw = $true }
        if ($ws -or $sep) {
            if ($inw) {
                $w = $cur.ToString(); [void]$cur.Clear(); $inw = $false
                if ($skipnext) { $skipnext = $false }
                elseif ($w -match '^[0-9]*[<>]') { if ($w -match '^[0-9]*>>?$') { $skipnext = $true } }
                else { [void]$words.Add($w) }
            }
            if ($sep -and $words.Count -gt 0) { [void]$segs.Add($words.ToArray()); $words = New-Object System.Collections.ArrayList }
        }
    }
    if ($inw) {
        $w = $cur.ToString()
        if ($skipnext) { $skipnext = $false } elseif ($w -notmatch '^[0-9]*[<>]') { [void]$words.Add($w) }
    }
    if ($words.Count -gt 0) { [void]$segs.Add($words.ToArray()) }
    return ,$segs
}

# Find git commit invocations: objects with All, Unknown, Dirs.
function Find-Commits([string]$text) {
    $found = New-Object System.Collections.ArrayList
    $dirs = New-Object System.Collections.ArrayList
    $gunk = $false
    $segs = Split-Segments $text
    $dirCmds = @('cd', 'chdir', 'sl', 'set-location', 'pushd', 'push-location')
    foreach ($w in $segs) {
        $nw = $w.Count
        $i = 0
        while ($i -lt $nw -and $w[$i] -match '^[A-Za-z_][A-Za-z0-9_]*=') { $i++ }
        if ($i -ge $nw) { continue }
        $f = $w[$i]
        if ($dirCmds -contains $f.ToLowerInvariant()) {
            $d = ''
            for ($k = $i + 1; $k -lt $nw; $k++) {
                if ($w[$k] -match '^-(Path|LiteralPath)$') { continue }
                if (-not $w[$k].StartsWith('-') -or $w[$k] -eq '-') { $d = $w[$k]; break }
            }
            if ($d -eq '' -or $d -eq '~') { $d = $HOME }
            elseif ($d.StartsWith('~/') -or $d.StartsWith('~\')) { $d = $HOME + $d.Substring(1) }
            if ($d -eq '' -or $d -eq '-' -or (Test-DirUnknown $d)) { $gunk = $true } else { [void]$dirs.Add($d) }
        } elseif (Test-GitWord $f) {
            $gd = New-Object System.Collections.ArrayList
            foreach ($x in $dirs) { [void]$gd.Add($x) }
            $u = $gunk
            $k = $i + 1
            while ($k -lt $nw) {
                $a = $w[$k]
                if ($a -ceq '-C') {
                    $k++
                    if ($k -lt $nw) { if (Test-DirUnknown $w[$k]) { $u = $true } else { [void]$gd.Add($w[$k]) } }
                    $k++
                } elseif ($a -ceq '-c' -or $a -eq '--git-dir' -or $a -eq '--work-tree' -or $a -eq '--namespace' -or $a -eq '--super-prefix' -or $a -eq '--config-env') { $k += 2 }
                elseif ($a.StartsWith('-')) { $k++ }
                else { break }
            }
            if ($k -lt $nw -and $w[$k] -ceq 'commit') {
                $all = $false; $afterdd = $false
                for ($j = $k + 1; $j -lt $nw; $j++) {
                    $a = $w[$j]
                    if ($afterdd) { $all = $true; continue }
                    if ($a -eq '--') { $afterdd = $true; continue }
                    if ($a.StartsWith('--')) {
                        if ($a -ceq '--all' -or $a -ceq '--include' -or $a -ceq '--only') { $all = $true }
                        elseif ($a.IndexOf('=') -lt 0 -and @('--message', '--file', '--reuse-message', '--reedit-message', '--template', '--author', '--date', '--fixup', '--squash', '--cleanup', '--trailer', '--pathspec-from-file') -ccontains $a) { $j++ }
                    } elseif ($a.StartsWith('-') -and $a.Length -gt 1) {
                        $L = $a.Length
                        for ($q = 1; $q -lt $L; $q++) {
                            $ch = $a[$q]
                            if ($ch -ceq 'a' -or $ch -ceq 'i' -or $ch -ceq 'o') { $all = $true }
                            if ('mFCctuS'.IndexOf($ch) -ge 0) {
                                if ($q -eq $L - 1 -and 'mFCct'.IndexOf($ch) -ge 0) { $j++ }
                                break
                            }
                        }
                    } else { $all = $true }
                }
                [void]$found.Add([pscustomobject]@{ All = $all; Unknown = $u; Dirs = @($gd.ToArray()) })
            }
        }
    }
    return ,$found
}

$found = $null
try { $found = Find-Commits $cmd } catch { Invoke-Fallback }
if ($null -eq $found -or $found.Count -eq 0) { exit 0 }

foreach ($inv in $found) {
    $ga = @('-C', $base)
    if (-not $inv.Unknown) { foreach ($d in $inv.Dirs) { $ga += @('-C', $d) } }
    $bad = Get-Bad $ga ([bool]$inv.All)
    if ($null -eq $bad -or $bad.Count -eq 0) { continue }
    $where = ''
    if ($base -ne '.' -or ($inv.Dirs.Count -gt 0 -and -not $inv.Unknown)) {
        $top = & git @ga rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $top) { $where = " ($top)" }
    }
    Block $where $bad
}
exit 0
