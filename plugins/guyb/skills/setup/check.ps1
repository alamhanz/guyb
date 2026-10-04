<#
.SYNOPSIS
  guyb setup checks. Read-only: prints one JSON object, never prompts, never changes cwd or config.
.PARAMETER StartDir
  Folder the Claude session started in (optional; reported as the root fallback).
#>
param([string]$StartDir = '')

$ErrorActionPreference = 'SilentlyContinue'
$checks = New-Object System.Collections.Generic.List[object]

function Add-Check($id, $status, $blocking, $detail, $fix = '', $fixBy = 'none') {
    $checks.Add([ordered]@{ id = $id; status = $status; blocking = [bool]$blocking; detail = $detail; fix = $fix; fixBy = $fixBy })
}
function Has-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function Run($exe, [string[]]$a) { $o = & $exe @a 2>$null | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o.Trim() } }
# Bounded probe of a known tool from PATH (works on PS 5.1): never hangs, stderr discarded. Code -1 = not found or failed to start.
function Probe($exe, [string]$argStr, [int]$ms = 3000) {
    $r = [pscustomobject]@{ Code = -1; Out = ''; TimedOut = $false }
    $cmd = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $r }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cmd.Source; $psi.Arguments = $argStr
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit($ms)) {
            $p.WaitForExit(); $r.Code = $p.ExitCode
            if ($so.Wait(1000)) { $r.Out = ([string]$so.Result).Trim() }
        } else {
            $r.TimedOut = $true
            # kill the whole tree: an orphaned grandchild would keep our stdout open (Windows)
            if ($env:OS -eq 'Windows_NT') { & taskkill /PID $p.Id /T /F *> $null }
            try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
        }
    } catch { }
    return $r
}
function Read-Json($p) { if (Test-Path -LiteralPath $p) { try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { $null } } }

# Profile files that may hold the guyb lines (PowerShell 7 and Windows PowerShell)
$docs = [Environment]::GetFolderPath('MyDocuments')
$profiles = @($PROFILE.CurrentUserCurrentHost, (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')) | Where-Object { $_ } | Select-Object -Unique
$profileText = ''
foreach ($p in $profiles) { if (Test-Path -LiteralPath $p) { $profileText += (Get-Content -LiteralPath $p -Raw) + "`n" } }

# GUYB_ROOT: process env -> user env -> $PROFILE line
$root = ''; $rootSrc = ''
if ($env:GUYB_ROOT) { $root = $env:GUYB_ROOT; $rootSrc = 'process env' }
elseif ($v = [Environment]::GetEnvironmentVariable('GUYB_ROOT', 'User')) { $root = $v; $rootSrc = 'user env' }
elseif ($profileText -match "(?m)^\s*\`$env:GUYB_ROOT\s*=\s*['""]([^'""]+)['""]") { $root = $Matches[1]; $rootSrc = 'profile line' }

# Repo: source line in profile, else known_marketplaces.json
$repo = ''; $repoSrc = ''
if ($profileText -match "(?m)^\s*\.\s+['""]([^'""]*?)[\\/]scripts[\\/]launch\.ps1['""]") { $repo = $Matches[1]; $repoSrc = 'profile line' }
$claudeDir = Join-Path $HOME '.claude'
$mk = Read-Json (Join-Path $claudeDir 'plugins\known_marketplaces.json')
if (-not $repo -and $mk -and $mk.guyb) {
    if ($mk.guyb.source.path) { $repo = $mk.guyb.source.path; $repoSrc = 'marketplace' }
    elseif ($mk.guyb.installLocation) { $repo = $mk.guyb.installLocation; $repoSrc = 'marketplace' }
}
$launcher = if ($repo) { Join-Path $repo 'scripts\launch.ps1' } else { '' }
$onWin = $env:OS -eq 'Windows_NT'

# --- blocking ---
if (Has-Cmd claude) { Add-Check 'claude' 'ok' $true 'claude found on PATH' }
else { Add-Check 'claude' 'fail' $true 'claude not on PATH' 'Install Claude Code: https://docs.claude.com/en/docs/claude-code/setup' 'user' }

if (Has-Cmd git) { Add-Check 'git' 'ok' $true ((Run git @('--version')).Out) }
else { Add-Check 'git' 'fail' $true 'git not installed' 'winget install Git.Git' 'claude-after-consent' }

if (Has-Cmd git) {
    $n = (Run git @('config', '--global', 'user.name')).Out; $e = (Run git @('config', '--global', 'user.email')).Out
    $miss = @(); if (-not $n) { $miss += 'user.name' }; if (-not $e) { $miss += 'user.email' }
    if ($miss) { Add-Check 'git-identity' 'fail' $true ('missing global ' + ($miss -join ', ')) 'git config --global user.name "<name>"; git config --global user.email "<email>"' 'claude-after-consent' }
    else { Add-Check 'git-identity' 'ok' $true 'global user.name and user.email set' }
} else { Add-Check 'git-identity' 'skip' $true 'git missing' }

if ($launcher -and (Test-Path -LiteralPath $launcher)) { Add-Check 'launcher' 'ok' $true "launcher found ($repoSrc)" }
else { Add-Check 'launcher' 'fail' $true $(if ($repo) { "repo $repo has no scripts\launch.ps1" } else { 'guyb repo not found' }) 'Run scripts\install.ps1 from the guyb repo; without it, cd into the project and run claude manually' 'user' }

# --- warnings ---
if ($root) { Add-Check 'root' 'ok' $false "GUYB_ROOT=$root ($rootSrc)" }
else {
    $fallback = if ($StartDir) { "; session start folder $StartDir is used" } else { '' }
    $tgt = if ($StartDir) { $StartDir } else { '<projects folder>' }
    Add-Check 'root' 'warn' $false ("GUYB_ROOT not set$fallback") "Add `$env:GUYB_ROOT = '$tgt' to `$PROFILE" 'claude-after-consent'
}

if ($profileText -match 'scripts[\\/]launch\.ps1') { Add-Check 'launcher-profile' 'ok' $false 'launcher source line present in $PROFILE' }
else { Add-Check 'launcher-profile' 'warn' $false 'no launcher source line in $PROFILE (the guyb command is unavailable in your terminals)' $(if ($repo) { "Add-Content `$PROFILE `". '$launcher'`"" } else { 'Run scripts\install.ps1' }) 'claude-after-consent' }

$profileMd = Join-Path $claudeDir 'guyb\profile.md'
if (Has-Cmd gh) {
    $r = Run gh @('auth', 'status')
    if ($r.Code -eq 0) {
        $acct = if ($r.Out -match 'account\s+(\S+)') { $Matches[1] } elseif ($r.Out -match 'as\s+(\S+)') { $Matches[1] } else { 'unknown' }
        Add-Check 'gh-auth' 'ok' $false "logged in: yes, account $acct"
        $helpers = (Run git @('config', '--global', '--get-all', 'credential.https://github.com.helper')).Out
        if ($helpers -match 'gh(\.exe)?[''"]?\s+auth\s+git-credential') { Add-Check 'git-cred' 'ok' $false 'HTTPS credential helper: gh' }
        else { Add-Check 'git-cred' 'warn' $false 'gh is not the HTTPS credential helper for github.com' 'gh auth setup-git' 'claude-after-consent' }
    } else {
        Add-Check 'gh-auth' 'warn' $false 'logged in: no' '! gh auth login' 'user'
        Add-Check 'git-cred' 'skip' $false 'gh not logged in'
    }
} elseif ((Test-Path -LiteralPath $profileMd) -and ((Get-Content -LiteralPath $profileMd -Raw) -match 'GitHub')) {
    Add-Check 'gh-auth' 'warn' $false 'gh not installed but profile.md lists GitHub' 'winget install GitHub.cli, then ! gh auth login' 'user'
    Add-Check 'git-cred' 'skip' $false 'gh missing'
} else {
    Add-Check 'gh-auth' 'skip' $false 'gh not installed'
    Add-Check 'git-cred' 'skip' $false 'gh not installed'
}

if ($onWin) {
    if (Has-Cmd wt.exe) { Add-Check 'terminal' 'ok' $false 'wt.exe found (new tabs)' }
    else { Add-Check 'terminal' 'warn' $false 'wt.exe not found; launcher opens a new window instead' 'winget install Microsoft.WindowsTerminal' 'claude-after-consent' }
} elseif ($env:TMUX) { Add-Check 'terminal' 'ok' $false 'inside tmux' }
elseif (Has-Cmd tmux) { Add-Check 'terminal' 'warn' $false 'tmux installed but not inside a tmux session' 'Run guyb <name> yourself, or start tmux first' 'user' }
else { Add-Check 'terminal' 'warn' $false 'tmux not installed' 'Install tmux' 'user' }

$inst = Read-Json (Join-Path $claudeDir 'plugins\installed_plugins.json')
$entry = if ($inst -and $inst.plugins.'guyb@guyb') { @($inst.plugins.'guyb@guyb')[0] } else { $null }
if (-not $entry) { Add-Check 'plugin' 'warn' $false 'guyb plugin not found in installed_plugins.json' 'claude plugin install guyb@guyb' 'claude-after-consent' }
else {
    $iv = $entry.version; $isha = [string]$entry.gitCommitSha
    $sv = ''; $ssha = ''
    if ($repo) {
        $pj = Read-Json (Join-Path $repo 'plugins\guyb\.claude-plugin\plugin.json')
        if ($pj) { $sv = $pj.version }
        if (Has-Cmd git) { $ssha = (Run git @('-C', $repo, 'rev-parse', 'HEAD')).Out }
    }
    $short = { param($s) if ($s.Length -gt 7) { $s.Substring(0, 7) } else { $s } }
    $fix = 'claude plugin marketplace update guyb; claude plugin update guyb@guyb (then restart Claude)'
    if (-not $sv) { Add-Check 'plugin' 'ok' $false "installed $iv ($(& $short $isha)); source version unknown" }
    elseif ($iv -ne $sv -or ($ssha -and $isha -and $isha -ne $ssha)) {
        Add-Check 'plugin' 'warn' $false "installed $iv ($(& $short $isha)), source $sv ($(& $short $ssha))" $fix 'claude-after-consent'
    } else { Add-Check 'plugin' 'ok' $false "up to date: $iv ($(& $short $isha))" }
}

if (Test-Path -LiteralPath $profileMd) { Add-Check 'profile' 'ok' $false 'profile.md exists' }
else { Add-Check 'profile' 'warn' $false 'no ~/.claude/guyb/profile.md' '/guyb:setup' 'user' }

# --- toolchain (non-blocking, read-only; nothing is installed) ---
$onMac = [bool]($PSVersionTable.PSVersion.Major -ge 6 -and $IsMacOS)
$ctr = ''
if (Has-Cmd docker) { $ctr = 'docker' } elseif (Has-Cmd podman) { $ctr = 'podman' }
if ($ctr) {
    $cv = Probe $ctr '--version'
    $ver = if ($cv.Out -match '(\d+\.\d+(?:\.\d+)?)') { $Matches[1] } else { 'unknown' }
    if ($ctr -eq 'docker') { $d = Probe 'docker' 'info --format "{{.ServerVersion}}"' } else { $d = Probe 'podman' 'info --format "{{.Version.Version}}"' }
    if ($d.Code -eq 0 -and $d.Out) { Add-Check 'container' 'ok' $false "$ctr $ver, daemon running" }
    else {
        $why = if ($d.TimedOut) { 'not responding' } else { 'not running' }
        $cfix = if ($ctr -eq 'podman') { 'podman machine start' } elseif ($onWin -or $onMac) { 'Start Docker Desktop' } else { 'sudo systemctl start docker' }
        Add-Check 'container' 'warn' $false "$ctr $ver, daemon $why" $cfix 'user'
    }
} else {
    $scanRoot = if ($root) { $root } else { $StartDir }
    $nCont = 0
    if ($scanRoot -and (Test-Path -LiteralPath $scanRoot -PathType Container)) {
        $dirs = @(Get-ChildItem -LiteralPath $scanRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' -and $_.Name -ne 'node_modules' } | Select-Object -First 200)
        foreach ($dd in $dirs) {
            foreach ($f in 'Dockerfile', 'compose.yaml', 'compose.yml', 'docker-compose.yml', 'docker-compose.yaml') {
                if (Test-Path -LiteralPath (Join-Path $dd.FullName $f) -PathType Leaf) { $nCont++; break }
            }
        }
    }
    if ($nCont -gt 0) {
        $cfix = if ($onWin) { 'winget install Docker.DockerDesktop (needs admin and WSL2; license terms apply to larger companies; alternative: podman)' }
                elseif ($onMac) { 'brew install --cask docker (or brew install podman)' }
                else { 'sudo apt install docker.io docker-compose-v2 (or sudo apt install podman)' }
        Add-Check 'container' 'warn' $false "docker/podman not installed; $nCont project folder(s) use containers" $cfix 'user'
    } else { Add-Check 'container' 'skip' $false 'docker/podman not installed; no container projects found' }
}

$py = $null
foreach ($cand in @(@('python3', '--version'), @('python', '--version'), @('py', '-3 --version'))) {
    $pr = Probe $cand[0] $cand[1]
    if ($pr.Code -eq 0 -and $pr.Out -match '^Python (\d+\.\d+(?:\.\d+)?)') { $py = $Matches[1]; break }
}
if ($py) { Add-Check 'python' 'ok' $false "python $py" }
else { Add-Check 'python' 'skip' $false 'python not installed' 'uv python install <version>' 'user' }

$nv = Probe 'node' '--version'
if ($nv.Code -eq 0 -and $nv.Out -match '^v?(\d+\.\d+(?:\.\d+)?)') { Add-Check 'node' 'ok' $false "node $($Matches[1])" }
else {
    $nfix = if ($onWin) { 'winget install Schniz.fnm' } elseif ($onMac) { 'brew install fnm' } else { 'curl -fsSL https://fnm.vercel.app/install | bash' }
    Add-Check 'node' 'skip' $false 'node not installed' $nfix 'user'
}

$uvp = Probe 'uv' '--version'
if ($uvp.Code -eq 0 -and $uvp.Out -match '(\d+\.\d+(?:\.\d+)?)') { Add-Check 'uv' 'ok' $false "uv $($Matches[1])" }
else {
    $ufix = if ($onWin) { 'winget install astral-sh.uv' } elseif ($onMac) { 'brew install uv' } else { 'curl -LsSf https://astral.sh/uv/install.sh | sh' }
    Add-Check 'uv' 'skip' $false 'uv not installed' $ufix 'user'
}

$blockFail = @($checks | Where-Object { $_.blocking -and $_.status -eq 'fail' }).Count
[ordered]@{
    version = 1
    os      = $(if ($onWin) { 'windows' } else { 'unix' })
    root    = $root
    repo    = $repo
    blockingFailures = $blockFail
    checks  = $checks.ToArray()
} | ConvertTo-Json -Depth 5
