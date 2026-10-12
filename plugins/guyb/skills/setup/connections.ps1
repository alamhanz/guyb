# guyb connections status. Dot-sourced by brief.ps1 and check.ps1; read-only, local files and env presence only.
# No CLI is run (Get-Command only), no network. Secrets files are read only for the "expiresAt" value (aws caches);
# env var VALUES are never read. Same lines as connections.sh (keep in sync).
# Get-GuybConnections -Dir <folder> returns List ("connections: ..." or ''), Warns (Type, Name, Reason), Project ("project config: ..." or ''), Gh1 (first github name).

function Get-GuybConnections {
  param([string]$Mode = 'brief', [string]$Dir = '')
  $ErrorActionPreference = 'SilentlyContinue'
  $res = [pscustomobject]@{ List = ''; Warns = @(); Project = ''; Gh1 = '' }
  $warns = New-Object System.Collections.ArrayList
  $hm = $HOME
  $dirT = $Dir.TrimEnd('\', '/')
  $pj = Join-Path $dirT '.claude/CLAUDE.md'
  $pm = Join-Path $hm '.claude/guyb/profile.md'
  $hasPj = Test-Path -LiteralPath $pj -PathType Leaf
  $hasProf = Test-Path -LiteralPath $pm -PathType Leaf
  $isProj = $hasPj -or ($dirT -ne '' -and (Test-Path -LiteralPath (Join-Path $dirT '.git')))
  $mcpJson = ($dirT -ne '' -and (Test-Path -LiteralPath (Join-Path $dirT '.mcp.json') -PathType Leaf))
  if (-not $hasPj -and -not $hasProf) {
    if ($isProj) { $res.Project = if ($mcpJson) { 'project config: .mcp.json' } else { 'project config: none - follows global (~/.claude/guyb/profile.md)' } }
    return $res
  }

  $known = @('github', 'gitlab', 'bitbucket', 'aws', 'gcp', 'azure', 'cloudflare', 'mcp', 'db', 'service')
  $cfgKeys = @('max_parallel', 'cleanup_claude_md_lines', 'cleanup_state_lines', 'cleanup_rows', 'cleanup_days')

  # one file: Connections entries, project extras (Cloud line, Credentials names, cfg keys it defines)
  function Read-Conf([string]$path, [bool]$isProject) {
    $r = [pscustomobject]@{ Entries = New-Object System.Collections.ArrayList; Cloud = ''; HasCred = $false; NCred = 0; MaxPar = $null; Cleanup = $false }
    $sec = ''; $seen = @{}
    $text = [System.IO.File]::ReadAllText($path)
    foreach ($raw in @($text -split "`n")) {
      $line = ($raw -replace "`r$", '') -replace '[\x01-\x08\x0B-\x1F]', ' '
      if ($line -cmatch '^#') {
        $sec = ''
        if ($line -cmatch '^##[ \t]+[Cc]onnections[ \t]*$') { $sec = 'conn' }
        elseif ($isProject -and $line -cmatch '^##[ \t]+[Cc]redentials') { $sec = 'cred'; $r.HasCred = $true }
        continue
      }
      if ($sec -eq 'conn' -and $line -cmatch '^[ \t]*-[ \t]+([^ \t:]+)[ \t]+([^ \t:]+)[ \t]*:(.*)$') {
        [void]$r.Entries.Add([pscustomobject]@{ Type = $Matches[1].ToLowerInvariant(); Name = $Matches[2]; Rest = $Matches[3] })
      } elseif ($sec -eq 'cred' -and $line -cmatch '^[ \t]*[-*][ \t]+(.*)$') {
        if ($Matches[1].Trim(" `t").ToLowerInvariant() -notmatch '^none[.]?$') { $r.NCred++ }
      } elseif ($isProject -and $r.Cloud -eq '' -and $line -cmatch '^[ \t]*[-*][ \t]+[*`]*Cloud[*`]*[ \t]*:(.*)$') {
        $c = ($Matches[1] -replace '[*`]', '').Trim(" `t")
        $r.Cloud = $c.Substring(0, [Math]::Min(40, $c.Length)).Trim(" `t")
      }
      if ($isProject -and $line -cmatch '^[ \t]*(?:[-*][ \t]+)?[`*]*([a-z_]+)[`*]*[ \t]*:[`* \t]*([0-9]+)[`* \t]*$' -and $cfgKeys -contains $Matches[1]) {
        $k = $Matches[1]; $d = $Matches[2].TrimStart('0')
        if ($d -ne '' -and $d.Length -le $(if ($k -eq 'max_parallel') { 2 } else { 9 }) -and -not $seen.ContainsKey($k)) {
          $n = [int]$d
          if ($n -ge 1 -and ($k -ne 'max_parallel' -or $n -le 20)) {
            $seen[$k] = $true
            if ($k -eq 'max_parallel') { $r.MaxPar = $n } else { $r.Cleanup = $true }
          }
        }
      }
    }
    return $r
  }
  function Get-Kv([string]$rest) {
    $kv = @{}
    foreach ($t in @($rest -split '[ \t]+')) { $p = $t.IndexOf('='); if ($p -gt 0) { $kv[$t.Substring(0, $p)] = $t.Substring($p + 1) } }
    return $kv
  }
  function Add-Warn($t, $n, $r) { [void]$warns.Add([pscustomobject]@{ Type = $t; Name = $n; Reason = $r }) }
  function Test-Cli([string]$type, [string]$name, [string]$cli, [string]$dep) {
    if (-not (Get-Command $cli -CommandType Application -ErrorAction SilentlyContinue)) { Add-Warn $type $name "$cli not on PATH" }
    elseif ($dep) { Add-Warn $type $name $dep }
  }
  function Test-EnvSet([string]$list, [string]$type, [string]$name) {
    foreach ($v in @($list -split ',')) { if ($v -and $null -eq [Environment]::GetEnvironmentVariable($v)) { Add-Warn $type $name "$v not set in this session" } }
  }
  function Read-Lines([string]$p) { if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return @(([System.IO.File]::ReadAllText($p)) -split "`n") }; return @() }
  function Test-AwsProfile([string]$p, [string]$name) {
    foreach ($l in (Read-Lines $p)) {
      $s = $l.Trim(" `t`r")
      if (-not $s.StartsWith('[')) { continue }
      $s = $s -replace '[ \t]*[#;].*$', ''
      if ($s -ceq "[$name]" -or $s -ceq "[profile $name]") { return $true }
    }
    return $false
  }

  $hp = if ($hasProf) { Read-Conf $pm $false } else { $null }
  $pp = if ($hasPj) { Read-Conf $pj $true } else { $null }
  $pEntries = @(); if ($pp) { $pEntries = @($pp.Entries) }
  $items = New-Object System.Collections.ArrayList
  if ($hp) {
    $povr = @{}; foreach ($e in $pEntries) { $povr[$e.Type] = $true }
    foreach ($e in @($hp.Entries)) { if (-not $povr.ContainsKey($e.Type)) { [void]$items.Add([pscustomobject]@{ E = $e; Project = $false }) } }
    foreach ($e in $pEntries) { [void]$items.Add([pscustomobject]@{ E = $e; Project = $true }) }
    if ($items.Count -eq 0) { $res.List = 'connections: not recorded in ~/.claude/guyb/profile.md' }
  }

  # paths of the other tools
  $appdata = $env:APPDATA
  $claudeJson = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' } else { Join-Path $hm '.claude.json' }
  $ghDir = if ($env:GH_CONFIG_DIR) { $env:GH_CONFIG_DIR } elseif ($appdata) { Join-Path $appdata 'GitHub CLI' } elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'gh' } else { Join-Path $hm '.config/gh' }
  $gcDir = if ($env:CLOUDSDK_CONFIG) { $env:CLOUDSDK_CONFIG } elseif ($appdata) { Join-Path $appdata 'gcloud' } else { Join-Path $hm '.config/gcloud' }
  $azDir = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $hm '.azure' }
  $awsCfg = if ($env:AWS_CONFIG_FILE) { $env:AWS_CONFIG_FILE } else { Join-Path $hm '.aws/config' }
  $awsCred = if ($env:AWS_SHARED_CREDENTIALS_FILE) { $env:AWS_SHARED_CREDENTIALS_FILE } else { Join-Path $hm '.aws/credentials' }

  $listParts = New-Object System.Collections.ArrayList
  $mnames = $null; $mshape = $false
  foreach ($it in $items) {
    $e = $it.E; $ty = $e.Type; $nm = $e.Name; $kv = Get-Kv $e.Rest
    $d = ''
    if ($it.Project) { $d = 'project' } elseif ($ty -eq 'aws') { $d = [string]$kv['region'] } elseif ($ty -eq 'gcp') { $d = [string]$kv['project'] } elseif ($ty -eq 'mcp') { $d = [string]$kv['scope'] }
    [void]$listParts.Add("$ty $nm" + $(if ($d) { " ($d)" } else { '' }))
    if ($known -notcontains $ty) { continue }
    $cli = $null
    switch ($ty) {
      'github' {
        if (-not $res.Gh1) { $res.Gh1 = $nm }
        $c = if ($kv.ContainsKey('cli')) { $kv['cli'] } else { 'gh' }; $dep = ''
        if ($c -eq 'gh' -and $null -eq $env:GH_TOKEN -and $null -eq $env:GITHUB_TOKEN) {
          $ok = $false
          foreach ($l in (Read-Lines (Join-Path $ghDir 'hosts.yml'))) { $s = $l.Trim(" `t`r"); if ($s -ceq "${nm}:" -or $s -ceq "user: $nm") { $ok = $true; break } }
          if (-not $ok) { $dep = "gh not logged in as $nm" }
        }
        Test-Cli $ty $nm $c $dep
      }
      'gitlab' { Test-Cli $ty $nm $(if ($kv.ContainsKey('cli')) { $kv['cli'] } else { 'glab' }) '' }
      'bitbucket' { Test-EnvSet $(if ($kv.ContainsKey('env')) { $kv['env'] } else { 'BITBUCKET_EMAIL,BITBUCKET_API_TOKEN' }) $ty $nm }
      'aws' {
        Test-Cli $ty $nm $(if ($kv.ContainsKey('cli')) { $kv['cli'] } else { 'aws' }) ''
        if (-not (Test-AwsProfile $awsCfg $nm) -and -not (Test-AwsProfile $awsCred $nm)) { Add-Warn $ty $nm "profile $nm missing from ~/.aws/config" }
        if (($kv['login'] -ceq 'sso' -or $kv['login'] -ceq 'aws-login') -and $null -eq $env:AWS_ACCESS_KEY_ID) {
          $newest = $null; $newDate = ''
          foreach ($cd in (Join-Path $hm '.aws/login/cache'), (Join-Path $hm '.aws/sso/cache')) {
            if (-not (Test-Path -LiteralPath $cd -PathType Container)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $cd -Filter '*.json' -File)) {
              foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f.FullName), '"expiresAt"[ \t]*:[ \t]*"([^"]*)"')) {
                $v = $m.Groups[1].Value
                if ($v -match '^(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)') {
                  $t = [datetime]::ParseExact("$($Matches[1])T$($Matches[2])", 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                  if ($null -eq $newest -or $t -gt $newest) { $newest = $t; $newDate = $Matches[1] }
                }
              }
            }
          }
          $nowU = [datetime]::UtcNow
          if ($null -ne $newest -and $newest -lt $nowU.AddSeconds(-43200)) { Add-Warn $ty $nm "login session likely expired (last refresh $newDate)" }
        }
      }
      'gcp' {
        $dep = ''
        if (-not (Test-Path -LiteralPath (Join-Path $gcDir "configurations/config_$nm") -PathType Leaf)) { $dep = "configuration $nm missing" }
        elseif (-not (Test-Path -LiteralPath (Join-Path $gcDir 'credentials.db') -PathType Leaf)) { $dep = 'not logged in' }
        Test-Cli $ty $nm $(if ($kv.ContainsKey('cli')) { $kv['cli'] } else { 'gcloud' }) $dep
      }
      'azure' {
        $dep = ''
        if ($kv['subscription']) {
          $azp = Join-Path $azDir 'azureProfile.json'
          if (-not ((Test-Path -LiteralPath $azp -PathType Leaf) -and [System.IO.File]::ReadAllText($azp).Contains($kv['subscription']))) { $dep = "subscription $($kv['subscription']) not in az profile" }
        }
        Test-Cli $ty $nm $(if ($kv.ContainsKey('cli')) { $kv['cli'] } else { 'az' }) $dep
      }
      'cloudflare' {
        if ($kv['auth'] -ceq 'wrangler') {
          $wr = $false
          $xdg = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $hm '.config' }
          $cands = @((Join-Path $xdg '.wrangler/config/default.toml'), (Join-Path $hm 'Library/Preferences/.wrangler/config/default.toml'), (Join-Path $hm '.wrangler/config/default.toml'))
          if ($appdata) { $cands += (Join-Path $appdata 'xdg.config/.wrangler/config/default.toml') }
          foreach ($cf in $cands) { if (Test-Path -LiteralPath $cf -PathType Leaf) { $wr = $true; break } }
          Test-Cli $ty $nm $(if ($kv.ContainsKey('cli')) { $kv['cli'] } else { 'wrangler' }) $(if ($wr) { '' } else { 'wrangler not logged in' })
        } elseif ($kv['auth'] -ceq 'env') { Test-EnvSet 'CLOUDFLARE_API_TOKEN' $ty $nm }
      }
      'mcp' {
        if (-not $kv['scope'] -or $kv['scope'] -ceq 'user') {
          if ($null -eq $mnames) {
            $mnames = @{}
            $ins = $false
            foreach ($l in (Read-Lines $claudeJson)) {
              $l = $l -replace "`r$", ''
              if (-not $ins) {
                if ($l -cmatch '^  "mcpServers"[ \t]*:') { $mshape = $true; if ($l -match '\{[ \t]*\}' -or $l -notmatch '\{[ \t]*$') { break }; $ins = $true }
                continue
              }
              if ($l -match '^  [}\]]') { break }
              if ($l -match '^    "([^"]+)"[ \t]*:') { $mnames[$Matches[1]] = $true }
            }
          }
          if ($mshape -and -not $mnames.ContainsKey($nm)) { Add-Warn $ty $nm 'MCP server not configured at user scope' }
        }
      }
      { $_ -eq 'db' -or $_ -eq 'service' } {
        if ($kv.ContainsKey('cli')) { Test-Cli $ty $nm $kv['cli'] '' }
        if ($ty -eq 'service' -and $kv.ContainsKey('env')) { Test-EnvSet $kv['env'] $ty $nm }
      }
    }
  }
  if ($listParts.Count -gt 0) { $res.List = 'connections: ' + ($listParts -join ', ') }

  if ($isProj) {
    $parts = New-Object System.Collections.ArrayList
    if ($pEntries.Count -gt 0) { [void]$parts.Add('connections ' + ((@($pEntries) | ForEach-Object { "$($_.Type) $($_.Name)" }) -join ', ')) }
    if ($pp) {
      if ($pp.Cloud) { [void]$parts.Add("cloud $($pp.Cloud)") }
      if ($pp.HasCred) { [void]$parts.Add($(if ($pp.NCred -gt 0) { "credentials $($pp.NCred) names" } else { 'credentials none' })) }
      if ($null -ne $pp.MaxPar) { [void]$parts.Add("max_parallel $($pp.MaxPar)") }
      if ($pp.Cleanup) { [void]$parts.Add('cleanup limits') }
    }
    if ($mcpJson) { [void]$parts.Add('.mcp.json') }
    $res.Project = 'project config: ' + $(if ($parts.Count -eq 0) { 'none - follows global (~/.claude/guyb/profile.md)' } else { $parts -join '; ' })
  }
  $res.Warns = @($warns)
  return $res
}

# the three line kinds: connections, warn: connection ..., project config
function Get-GuybConnLines($c) {
  $l = New-Object System.Collections.Generic.List[string]
  if ($c.List) { $l.Add($c.List) }
  foreach ($w in @($c.Warns)) { $l.Add("warn: connection $($w.Type) $($w.Name): $($w.Reason)") }
  if ($c.Project) { $l.Add($c.Project) }
  return , $l.ToArray()
}
