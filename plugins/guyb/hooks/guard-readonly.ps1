# guyb PreToolUse guard: stop read-only subagents from running git write commands.
# PowerShell twin of guard-readonly.sh: same algorithm and rules, pinned by tests/readonly-cases.tsv.
#
# What it promises: defense in depth against routine and accidental git writes by read-only agents.
# The agent prompt rules stay the main control. It is NOT a sandbox: runtime substitution
# (g=git; $g add), scripts the agent writes and then runs, language runtimes (python -c ...),
# -c core.pager=/core.sshCommand= payloads and aliases defined in files the agent writes all evade it.
# Hard enforcement needs OS-level isolation (read-only worktree, separate user).
#
# Fail open: exit 2 only when the hook input names a read-only guyb subagent AND the parsed command
# contains a git write. Missing field, parse error (unbalanced quote or substitution), any
# exception, or any other agent: exit 0. A heredoc without its terminator is not an error (bash runs
# it): the body runs to the end of input.
#
# KNOWN GAPS (skipped to stay small): PowerShell here-strings (@' '@) and <# #> block comments are
# not special; Start-Process with -ArgumentList @(...) is only seen for the plain 'a','b' form.
#
# Verified hook stdin (Claude Code 2.1.288): PreToolUse JSON for a call made inside a subagent
# carries "agent_id" and "agent_type". Plugin agents report "agent_type":"guyb:<name>"
# (accept the bare name too). Main-session calls carry neither field.
#
# Invocation: hooks.json checks the agent with a regex, then runs this file in its own PowerShell
# host as a scriptblock with -Raw <hook json>; `exit 2` inside that scriptblock is the process exit
# code (verified on pwsh 7 and Windows PowerShell 5.1, stderr included). Without -Raw, stdin is read.
# Works on Windows PowerShell 5.1 and PowerShell 7.
param([string]$Raw)

$ShellNames = 'bash', 'sh', 'zsh', 'dash', 'ksh'
$AlwaysWrite = 'add stage commit reset checkout switch clean restore rebase merge push rm mv apply cherry-pick pull fetch revert am notes update-ref symbolic-ref replace gc prune repack submodule init clone filter-branch maintenance sparse-checkout read-tree checkout-index update-index bisect' -split ' '
$KnownRead = 'status log diff show grep blame annotate ls-files ls-tree ls-remote rev-parse rev-list cat-file describe shortlog show-ref show-branch for-each-ref merge-base name-rev var help version whatchanged range-diff cherry diff-tree diff-index diff-files check-ignore check-attr check-mailmap count-objects verify-commit verify-tag fsck format-patch archive bundle request-pull fast-export' -split ' '

function Get-Base([string]$w) {
    $k = [Math]::Max($w.LastIndexOf('/'), $w.LastIndexOf('\'))
    if ($k -ge 0) { $w = $w.Substring($k + 1) }
    return ($w.ToLower() -replace '\.exe$', '')
}

# Index of the ')' that closes a substitution whose body starts at $start; throws at EOF.
function Get-SubstEnd([string]$s, [int]$start) {
    $d = 1
    $k = $start
    while ($k -lt $s.Length) {
        $c = $s[$k]
        if ($c -eq "'") {
            $e = $s.IndexOf("'", $k + 1)
            if ($e -lt 0) { throw 'parse' }
            $k = $e
        } elseif ($c -eq '"') {
            $k++
            while ($k -lt $s.Length -and $s[$k] -ne '"') {
                if ($s[$k] -eq '\' -or $s[$k] -eq '`') { $k++ }
                $k++
            }
            if ($k -ge $s.Length) { throw 'parse' }
        } elseif ($c -eq '(') { $d++ }
        elseif ($c -eq ')') { $d--; if ($d -eq 0) { return $k } }
        $k++
    }
    throw 'parse'
}

# Command split into segments (string[] of words). Throws 'parse' on EOF inside a quote,
# substitution or heredoc. $sh: sh quoting rules (heredocs, backslash, backtick substitution);
# otherwise PowerShell rules.
function Split-Command([string]$s, [bool]$sh, [int]$depth) {
    $segs = New-Object 'System.Collections.Generic.List[string[]]'
    if ($depth -gt 3) { return , $segs }
    $words = New-Object 'System.Collections.Generic.List[string]'
    $sb = New-Object System.Text.StringBuilder
    $inWord = $false
    $pending = New-Object 'System.Collections.Generic.List[object]'
    $rdr = $false
    $endWord = { if ($inWord) { if ($rdr) { $rdr = $false } else { $words.Add($sb.ToString()) }; [void]$sb.Clear(); $inWord = $false } }
    $endSeg = { . $endWord; if ($words.Count -gt 0) { $segs.Add($words.ToArray()); $words.Clear() }; $rdr = $false }
    $n = $s.Length
    $i = 0
    while ($i -lt $n) {
        $c = $s[$i]
        if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`r") {
            . $endWord; $i++
        } elseif ($c -eq "`n") {
            $readBody = $false
            if ($pending.Count -gt 0) {
                . $endWord
                $d0 = $null
                $r0 = @(Remove-Wrapper $words.ToArray() ([ref]$d0))
                if ($r0.Count -gt 0 -and $ShellNames -contains (Get-Base $r0[0])) {
                    $readBody = $true
                    foreach ($x in $r0) { if ($x -cmatch '^-[A-Za-z]*c[A-Za-z]*$') { $readBody = $false } }
                }
            }
            . $endSeg
            $i++
            foreach ($h in $pending) {
                $body = New-Object System.Text.StringBuilder
                while ($i -lt $n) {
                    $e = $s.IndexOf("`n", $i)
                    if ($e -lt 0) { $line = $s.Substring($i); $i = $n } else { $line = $s.Substring($i, $e - $i); $i = $e + 1 }
                    $cmp = $line.TrimEnd("`r")
                    if ($h.strip) { $cmp = $cmp.TrimStart("`t") }
                    if ($cmp -ceq $h.delim) { break }
                    [void]$body.Append($line).Append("`n")
                }
                if ($readBody) { $segs.AddRange((Split-Command $body.ToString() $true ($depth + 1))) }
            }
            $pending.Clear()
        } elseif (';|&()'.IndexOf($c) -ge 0) {
            . $endSeg; $i++
        } elseif ($c -eq '#' -and -not $inWord) {
            while ($i -lt $n -and $s[$i] -ne "`n") { $i++ }
        } elseif ($c -eq "'") {
            $inWord = $true
            $i++
            while ($true) {
                $e = $s.IndexOf("'", $i)
                if ($e -lt 0) { throw 'parse' }
                [void]$sb.Append($s.Substring($i, $e - $i))
                $i = $e + 1
                if (-not $sh -and $i -lt $n -and $s[$i] -eq "'") { [void]$sb.Append("'"); $i++ } else { break }
            }
        } elseif ($c -eq '"') {
            $inWord = $true
            $i++
            $closed = $false
            while ($i -lt $n) {
                $c = $s[$i]
                if ($c -eq '"') {
                    if (-not $sh -and $i + 1 -lt $n -and $s[$i + 1] -eq '"') { [void]$sb.Append('"'); $i += 2; continue }
                    $closed = $true; $i++; break
                }
                if ($sh -and $c -eq '\') {
                    if ($i + 1 -ge $n) { throw 'parse' }
                    $x = $s[$i + 1]
                    if ($x -eq "`n") { $i += 2; continue }
                    if ('"\$`'.IndexOf($x) -ge 0) { [void]$sb.Append($x); $i += 2 } else { [void]$sb.Append($c); $i++ }
                    continue
                }
                if (-not $sh -and $c -eq '`') {
                    if ($i + 1 -ge $n) { throw 'parse' }
                    [void]$sb.Append($s[$i + 1]); $i += 2
                    continue
                }
                if ($c -eq '$' -and $i + 1 -lt $n -and $s[$i + 1] -eq '(') {
                    $e = Get-SubstEnd $s ($i + 2)
                    $segs.AddRange((Split-Command $s.Substring($i + 2, $e - $i - 2) $sh ($depth + 1)))
                    $i = $e + 1
                    continue
                }
                if ($sh -and $c -eq '`') {
                    $e = $s.IndexOf('`', $i + 1)
                    if ($e -lt 0) { throw 'parse' }
                    $segs.AddRange((Split-Command $s.Substring($i + 1, $e - $i - 1) $true ($depth + 1)))
                    $i = $e + 1
                    continue
                }
                [void]$sb.Append($c); $i++
            }
            if (-not $closed) { throw 'parse' }
        } elseif ($sh -and $c -eq '`') {
            $e = $s.IndexOf('`', $i + 1)
            if ($e -lt 0) { throw 'parse' }
            $segs.AddRange((Split-Command $s.Substring($i + 1, $e - $i - 1) $true ($depth + 1)))
            $inWord = $true
            $i = $e + 1
        } elseif ($sh -and $c -eq '\') {
            $inWord = $true
            if ($i + 1 -lt $n) {
                if ($s[$i + 1] -ne "`n") { [void]$sb.Append($s[$i + 1]) }
                $i += 2
            } else { $i++ }
        } elseif (-not $sh -and $c -eq '`') {
            if ($i + 1 -lt $n) {
                if ($s[$i + 1] -ne "`n") { [void]$sb.Append($s[$i + 1]); $inWord = $true }
                $i += 2
            } else { $i++ }
        } elseif ($sh -and $c -eq '<' -and $i + 1 -lt $n -and $s[$i + 1] -eq '<' -and -not ($i + 2 -lt $n -and $s[$i + 2] -eq '<')) {
            $i += 2
            $strip = $false
            if ($i -lt $n -and $s[$i] -eq '-') { $strip = $true; $i++ }
            while ($i -lt $n -and ($s[$i] -eq ' ' -or $s[$i] -eq "`t")) { $i++ }
            $delim = New-Object System.Text.StringBuilder
            while ($i -lt $n -and " `t`r`n;|&()<>".IndexOf($s[$i]) -lt 0) {
                $d = $s[$i]
                if ($d -eq "'" -or $d -eq '"') {
                    $e = $s.IndexOf($d, $i + 1)
                    if ($e -lt 0) { throw 'parse' }
                    [void]$delim.Append($s.Substring($i + 1, $e - $i - 1))
                    $i = $e + 1
                } else { [void]$delim.Append($d); $i++ }
            }
            if ($delim.Length -gt 0) { $pending.Add(@{ delim = $delim.ToString(); strip = $strip }) }
        } elseif ($c -eq '<' -or $c -eq '>') {
            if ($inWord -and $sb.ToString() -match '^[0-9]+$') { [void]$sb.Clear(); $inWord = $false } else { . $endWord }
            while ($i -lt $n -and ($s[$i] -eq '<' -or $s[$i] -eq '>')) { $i++ }
            if ($i -lt $n -and ($s[$i] -eq '&' -or $s[$i] -eq '|')) { $i++ }
            $rdr = $true
        } else {
            [void]$sb.Append($c); $inWord = $true; $i++
        }
    }
    . $endSeg
    return , $segs
}

# Drop leading assignments and wrapper commands; returns the remaining words. For `cmd /c ...`
# returns nothing and puts the command string in $nested.
function Remove-Wrapper([string[]]$Arr, [ref]$nested) {
    $Arr = [string[]]$Arr.Clone()
    $n = $Arr.Count
    $i = 0
    $go = $true
    while ($go -and $i -lt $n) {
        $w = $Arr[$i]
        $b = Get-Base $w
        if ($w -match '^[A-Za-z_][A-Za-z0-9_]*=') { $i++ }
        elseif ($w -match '^\$[A-Za-z_][A-Za-z0-9_:]*[+]?=(.+)$') { $Arr[$i] = $Matches[1] }
        elseif ($w -match '^\$[A-Za-z_][A-Za-z0-9_:]*$' -and $i + 1 -lt $n -and $Arr[$i + 1] -match '^[+]?=$') { $i += 2 }
        elseif ('!', '{', 'if', 'then', 'elif', 'else', 'do', 'while', 'until', '&', '.' -ccontains $w) { $i++ }
        elseif ($b -eq 'env') {
            $i++
            while ($i -lt $n) {
                $x = $Arr[$i]
                if ($x -match '^[A-Za-z_][A-Za-z0-9_]*=') { $i++ }
                elseif ($x -cmatch '^(-u|-C|-S|--unset|--chdir)$') { $i += 2 }
                elseif ($x.StartsWith('-')) { $i++ }
                else { break }
            }
        }
        elseif ('command', 'builtin', 'exec', 'nohup', 'time' -contains $b) {
            $i++
            while ($i -lt $n -and $Arr[$i].StartsWith('-') -and $Arr[$i] -ne '-') {
                if ($b -eq 'command' -and $Arr[$i] -cmatch '^-[vV]$') { return @() }
                if ($b -eq 'exec' -and $Arr[$i] -ceq '-a') { $i++ }
                $i++
            }
        }
        elseif ($b -eq 'timeout') {
            $i++
            while ($i -lt $n -and $Arr[$i].StartsWith('-')) { if ($Arr[$i] -cmatch '^-[sk]$') { $i += 2 } else { $i++ } }
            $i++
        }
        elseif ('nice', 'sudo', 'watch', 'stdbuf', 'xargs' -contains $b) {
            $take = @{ nice = '^-n$'; sudo = '^-[ugCDhprtTUR]$'; watch = '^-n$'; stdbuf = '^-[ioe]$'; xargs = '^-[IinPdLaEs]$' }[$b]
            $i++
            while ($i -lt $n -and $Arr[$i].StartsWith('-')) { if ($Arr[$i] -cmatch $take) { $i += 2 } else { $i++ } }
        }
        elseif ($b -eq 'cmd' -and $i + 1 -lt $n -and $Arr[$i + 1] -match '^/[cCkK]$') {
            if ($i + 2 -lt $n) { $nested.Value = ($Arr[($i + 2)..($n - 1)] -join ' ') }
            return @()
        }
        else { $go = $false }
    }
    if ($i -lt $n) { return $Arr[$i..($n - 1)] }
    return @()
}

function Test-Nested([string]$str, [bool]$sh, [int]$depth) {
    if ($depth -gt 3) { return $false }
    foreach ($seg in (Split-Command $str $sh $depth)) {
        if (Test-Segment $seg $sh $depth) { return $true }
    }
    return $false
}

function Test-Segment([string[]]$Words, [bool]$sh, [int]$depth) {
    $nested = $null
    $r = @(Remove-Wrapper $Words ([ref]$nested))
    if ($nested) { return (Test-Nested $nested $sh ($depth + 1)) }
    if ($r.Count -eq 0) { return $false }
    $b = Get-Base $r[0]
    $rest = @()
    if ($r.Count -gt 1) { $rest = $r[1..($r.Count - 1)] }
    if ($b -eq 'git') { return (Test-GitWords $rest $depth) }
    if ($ShellNames -contains $b) {
        for ($j = 0; $j -lt $rest.Count; $j++) {
            if ($rest[$j] -cmatch '^-[A-Za-z]*c[A-Za-z]*$') {
                if ($j + 1 -lt $rest.Count) { return (Test-Nested $rest[$j + 1] $true ($depth + 1)) }
                return $false
            }
        }
        return $false
    }
    if ($b -eq 'eval') { return (Test-Nested ($rest -join ' ') $true ($depth + 1)) }
    if ($b -eq 'pwsh' -or $b -eq 'powershell') {
        for ($j = 0; $j -lt $rest.Count; $j++) {
            if ($rest[$j] -imatch '^-c(o(m(m(a(n(d)?)?)?)?)?)?$') {
                if ($j + 1 -lt $rest.Count) { return (Test-Nested ($rest[($j + 1)..($rest.Count - 1)] -join ' ') $false ($depth + 1)) }
                return $false
            }
        }
        return $false
    }
    if ($b -eq 'iex' -or $b -eq 'invoke-expression') {
        $a = @($rest | Where-Object { $_ -inotmatch '^-command$' })
        return (Test-Nested ($a -join ' ') $false ($depth + 1))
    }
    if ($b -eq 'find') {
        $j = 0
        while ($j -lt $rest.Count) {
            if ($rest[$j] -cmatch '^-(exec|execdir|ok|okdir)$') {
                $sub = New-Object 'System.Collections.Generic.List[string]'
                $j++
                while ($j -lt $rest.Count -and $rest[$j] -ne ';' -and $rest[$j] -ne '\;' -and $rest[$j] -ne '+') { $sub.Add($rest[$j]); $j++ }
                if ($sub.Count -gt 0 -and (Test-Segment $sub.ToArray() $sh ($depth + 1))) { return $true }
            } else { $j++ }
        }
        return $false
    }
    if ('start-process', 'saps' -contains $b) {
        $file = $null
        $argv = $null
        $j = 0
        while ($j -lt $rest.Count) {
            $x = $rest[$j]
            if ($x -imatch '^-filepath$') { if ($j + 1 -lt $rest.Count) { $file = $rest[$j + 1] }; $j += 2 }
            elseif ($x -imatch '^-(argumentlist|args)$') { if ($j + 1 -lt $rest.Count) { $argv = $rest[$j + 1] }; $j += 2 }
            elseif ($x -imatch '^-(nonewwindow|wait|passthru|usenewenvironment|loaduserprofile)$') { $j++ }
            elseif ($x.StartsWith('-')) { $j += 2 }
            else {
                if (-not $file) { $file = $x } elseif (-not $argv) { $argv = $x }
                $j++
            }
        }
        if ($file -and (Get-Base $file) -eq 'git') {
            $aw = @(([string]$argv) -split '[,\s]+' | Where-Object { $_ })
            return (Test-GitWords $aw $depth)
        }
    }
    return $false
}

function Test-GitWords([string[]]$Arr, [int]$depth) {
    $n = $Arr.Count
    $dir = ''
    $alias = @{}
    $verb = $null
    $i = 0
    while ($i -lt $n) {
        $w = $Arr[$i]
        if ($w -ceq '-C') { if ($i + 1 -lt $n) { $dir = $Arr[$i + 1] }; $i += 2 }
        elseif ($w -ceq '-c') {
            if ($i + 1 -lt $n -and $Arr[$i + 1] -imatch '^alias\.([^=]+)=(.*)$') { $alias[$Matches[1].ToLower()] = $Matches[2] }
            $i += 2
        }
        elseif ($w -cmatch '^--(git-dir|work-tree|namespace|super-prefix|config-env|exec-path)$') { $i += 2 }
        elseif ($w.StartsWith('-')) { $i++ }
        else { $verb = $w.ToLower(); $i++; break }
    }
    if (-not $verb) { return $false }
    $a = @()
    if ($i -lt $n) { $a = $Arr[$i..($n - 1)] }
    $first = ''
    if ($a.Count -gt 0) { $first = $a[0].ToLower() }

    if ($AlwaysWrite -contains $verb) { return $true }
    if ($verb -eq 'stash') {
        return ($a.Count -eq 0 -or $first.StartsWith('-') -or ('push', 'pop', 'apply', 'drop', 'clear', 'save', 'branch', 'create', 'store' -contains $first))
    }
    if ($verb -eq 'branch') {
        foreach ($x in $a) { if ($x -cmatch '^(-[^-]*[dDmMcCfu][^-]*|--(delete|move|copy|force|set-upstream-to(=.*)?|unset-upstream|edit-description))$') { return $true } }
        return ($a.Count -gt 0 -and -not $first.StartsWith('-'))
    }
    if ($verb -eq 'tag') {
        foreach ($x in $a) { if ($x -cmatch '^(-[^-]*[dasfmFu][^-]*|--(delete|annotate|sign|force|message(=.*)?|file(=.*)?))$') { return $true } }
        return ($a.Count -gt 0 -and -not $first.StartsWith('-'))
    }
    if ($verb -eq 'worktree') { return ('add', 'remove', 'move', 'prune', 'lock', 'unlock', 'repair' -contains $first) }
    if ($verb -eq 'remote') { return ('add', 'remove', 'rm', 'rename', 'set-url', 'set-head', 'set-branches', 'prune', 'update' -contains $first) }
    if ($verb -eq 'reflog') { return ('expire', 'delete' -contains $first) }
    if ($verb -eq 'config') {
        $pos = New-Object 'System.Collections.Generic.List[string]'
        $readFlag = $false
        $writeFlag = $false
        $k = 0
        while ($k -lt $a.Count) {
            $x = $a[$k]
            if ($x -cmatch '^(--get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|--list|-l|--show-origin|--show-scope)$') { $readFlag = $true }
            elseif ($x -cmatch '^(--unset|--unset-all|--add|--replace-all|--rename-section|--remove-section|--edit|-e)$') { $writeFlag = $true }
            elseif ($x -cmatch '^(--file|-f|--blob|--type|--default)$') { $k++ }
            elseif (-not $x.StartsWith('-')) { $pos.Add($x) }
            $k++
        }
        $f = ''
        if ($pos.Count -gt 0) { $f = $pos[0].ToLower() }
        if ($writeFlag -or 'set', 'unset', 'rename-section', 'remove-section', 'edit' -contains $f) { return $true }
        if ($readFlag -or $f -eq 'get' -or $f -eq 'list') { return $false }
        return ($pos.Count -ge 2)
    }
    if ($KnownRead -contains $verb) { return $false }

    # Unknown verb: maybe an alias (-c alias.x=... in this segment, else git config).
    if ($depth -ge 3) { return $false }
    $val = $null
    $d = $dir
    if ($d -and $Cwd -and $d -notmatch '^([/~\\]|[A-Za-z]:)') { $d = $Cwd + '/' + $d }
    if (-not $d) { $d = $Cwd }
    if ($alias.ContainsKey($verb)) { $val = $alias[$verb] }
    else {
        try {
            if ($d) { $out = & git -C $d config --get "alias.$verb" 2>$null } else { $out = & git config --get "alias.$verb" 2>$null }
            $val = ([string](@($out) | Select-Object -First 1)).Trim()
        } catch { $val = $null }
    }
    if (-not $val) { return $false }
    if ($val.StartsWith('!')) { return $true }
    $aw = @()
    foreach ($sg in (Split-Command $val $true ($depth + 1))) { $aw += $sg }
    $pre = @()
    if ($d) { $pre = @('-C', $d) }
    return (Test-GitWords ($pre + $aw + $a) ($depth + 1))
}

$code = 0
try {
    if (-not $Raw) { $Raw = [Console]::In.ReadToEnd() }
    $m = [regex]::Match([string]$Raw, '"agent_type"\s*:\s*"(guyb:)?(code-reviewer|architect|data-modeler|data-analyst|session-tracker|brand-designer)"')
    if ($m.Success) {
        $data = $Raw | ConvertFrom-Json
        $cmd = [string]$data.tool_input.command
        $Cwd = [string]$data.cwd
        if ($cmd -and (Test-Nested $cmd $false 0)) {
            [Console]::Error.WriteLine("guyb: blocked - read-only agent '$($m.Groups[2].Value)' may not run git write commands.")
            [Console]::Error.WriteLine('Report what you would change instead; the orchestrator or git-ops makes repo changes.')
            $code = 2
        }
    }
} catch { $code = 0 }
exit $code
