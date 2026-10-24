# Windows launcher helpers for install.ps1. Functions only: dot-sourcing has no side effects.

# Add-GuybUserPath -Dir <folder> [-SubKey <HKCU subkey>]: append Dir to the user PATH unless present. Returns 'added' or 'present'.
# Reads and writes the raw registry value (a %VAR% entry stays %VAR%, the value stays ExpandString). The previous raw
# value is left in $script:GuybPathPrevious. SubKey is for tests; only the default 'Environment' key broadcasts the change
# and updates the current session.
function Add-GuybUserPath {
    param([Parameter(Mandatory)][string]$Dir, [string]$SubKey = 'Environment')
    $norm = { param($s) [Environment]::ExpandEnvironmentVariables($s.Trim().Trim('"')).TrimEnd('\', '/') }
    $want = & $norm $Dir
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
    try {
        $old = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $script:GuybPathPrevious = $old
        foreach ($e in ($old -split ';')) {
            if ($e.Trim() -and ((& $norm $e) -ieq $want)) { return 'present' }
        }
        $new = if ($old.Trim()) { $old.TrimEnd(';') + ';' + $Dir } else { $Dir }
        $key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Dispose() }
    if ($SubKey -eq 'Environment') {
        # setting and clearing a throwaway variable broadcasts WM_SETTINGCHANGE so new processes re-read the environment
        [Environment]::SetEnvironmentVariable('GUYB_PATHSYNC', '1', 'User')
        [Environment]::SetEnvironmentVariable('GUYB_PATHSYNC', $null, 'User')
        if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') })) { $env:Path = "$Dir;$env:Path" }
    }
    return 'added'
}

# Set-GuybUserRoot -Root <folder>: set the User GUYB_ROOT only when it is empty (never overwrites). Returns 'added' or 'present'.
function Set-GuybUserRoot {
    param([Parameter(Mandatory)][string]$Root)
    if ([Environment]::GetEnvironmentVariable('GUYB_ROOT', 'User')) { return 'present' }
    [Environment]::SetEnvironmentVariable('GUYB_ROOT', $Root, 'User')
    return 'added'
}

# Add-GuybBashrc -Path <rc file> -Repo <clone> [-Root <folder>]: append the launcher source line (LF, no BOM, forward slashes)
# unless a scripts/launch.sh line exists; with -Root also exports GUYB_ROOT when the file never mentions it. Returns 'added' or 'present'.
function Add-GuybBashrc {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Repo, [string]$Root)
    $text = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    if ($text -match 'scripts/launch\.sh') { return 'present' }
    $add = ''
    if ($text -and -not $text.EndsWith("`n")) { $add += "`n" }
    $add += "`n# guyb`nsource `"$($Repo.Replace('\', '/'))/scripts/launch.sh`"`n"
    if ($Root -and $text -notmatch 'GUYB_ROOT') { $add += "export GUYB_ROOT=`"$($Root.Replace('\', '/'))`"`n" }
    [IO.File]::AppendAllText($Path, $add, (New-Object Text.UTF8Encoding($false)))
    return 'added'
}
