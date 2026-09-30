#requires -Version 5.1
<#
.SYNOPSIS
  Tray app to switch Claude Code between sources (Personal / IBM ICA / RISE API).

.DESCRIPTION
  Each source is a "profile": a set of env vars (e.g. ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN)
  and an optional model. Switching rewrites ~/.claude/settings.json: it removes every env key
  that any profile manages, then applies the chosen profile's values. All other settings are kept.
  It also mirrors those same keys into your Windows User environment variables (persisted via
  [Environment]::SetEnvironmentVariable), so tools outside Claude Code that read $env:ANTHROPIC_API_KEY
  etc. directly see the switch too. Existing processes/terminals only pick this up after they restart.
  A profile with no env vars (Personal) leaves Claude Code on your normal claude.ai login.

  Run with no arguments for the tray app, or:
    -List           show profiles and which one is active
    -Use <id>       switch and exit (personal | ica | rise)
    -Test <id|all>  check whether a source is live, print the result and exit (exit code 1 on failure)
    -Usage <id|all> show usage: session/weekly limits (Personal), spend and budgets (gateways)
    -Silent         start in the tray without opening the window (use this for a startup shortcut)
#>
[CmdletBinding()]
param(
    [string]$Use,
    [switch]$List,
    [string]$Test,
    [string]$Usage,
    [switch]$Silent,
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$ConfigDir = (Join-Path $env:APPDATA 'claude-switcher')
)

$ErrorActionPreference = 'Stop'
$ProfilesPath = Join-Path $ConfigDir 'profiles.json'
$BackupDir = Join-Path $ConfigDir 'backups'
# Always cleared on a switch, even if no profile lists them, so nothing leaks between sources.
# CLAUDE_CONFIG_DIR is what lets a second Personal profile have its own separate claude.ai login.
$AlwaysManaged = 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'CLAUDE_CONFIG_DIR'
# Env keys that mean "this is a gateway profile". A profile without any of these is Personal-type,
# even if it sets CLAUDE_CONFIG_DIR (that's how a second personal account differs from the first).
$GatewayKeys = 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY'

# ---------- JSON helpers ----------

function ConvertTo-Ordered($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Ordered $p.Value }
        return $h
    }
    if ($o -is [System.Collections.IList]) {
        return , @($o | ForEach-Object { ConvertTo-Ordered $_ })
    }
    return $o
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [ordered]@{} }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }
    ConvertTo-Ordered (ConvertFrom-Json $raw)
}

function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json $Object -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------- profiles ----------

function New-Personal2Profile {
    [ordered]@{ id = 'personal2'; name = 'Personal (2nd account)'; color = '#B45309'; model = ''
        env = [ordered]@{ CLAUDE_CONFIG_DIR = (Join-Path $ConfigDir 'accounts\personal2') } }
}

function New-DefaultConfig {
    $settings = Read-JsonFile $SettingsPath
    $model = ''
    if ($settings.Contains('model')) { $model = [string]$settings['model'] }
    [ordered]@{
        profiles = @(
            [ordered]@{ id = 'personal'; name = 'Personal Claude'; color = '#D97757'; model = $model; env = [ordered]@{} },
            (New-Personal2Profile),
            [ordered]@{ id = 'ica'; name = 'IBM ICA'; color = '#0F62FE'; model = ''
                env = [ordered]@{ ANTHROPIC_BASE_URL = ''; ANTHROPIC_AUTH_TOKEN = '' } },
            [ordered]@{ id = 'rise'; name = 'RISE API'; color = '#24A148'; model = ''
                env = [ordered]@{ ANTHROPIC_BASE_URL = ''; ANTHROPIC_AUTH_TOKEN = '' } }
        )
    }
}

function Find-Profile($Cfg, [string]$Id) {
    foreach ($p in $Cfg['profiles']) { if ($p['id'] -eq $Id) { return $p } }
    $null
}

# One-time upgrade for installs whose saved profiles.json predates the 2nd-personal-account
# profile. Only appends it when missing, so hand-edited profiles.json files aren't clobbered.
function Merge-DefaultProfiles($Cfg) {
    if (Find-Profile $Cfg 'personal2') { return $false }
    $Cfg['profiles'] = @($Cfg['profiles']) + , (New-Personal2Profile)
    $true
}

function Get-Config {
    if (Test-Path -LiteralPath $ProfilesPath) {
        $cfg = Read-JsonFile $ProfilesPath
        if (Merge-DefaultProfiles $cfg) { Write-JsonFile $ProfilesPath $cfg }
        return $cfg
    }
    $cfg = New-DefaultConfig
    Write-JsonFile $ProfilesPath $cfg
    $cfg
}

# A profile is Personal-type (a claude.ai login, not a gateway) when it has none of the
# gateway auth keys - it may still set CLAUDE_CONFIG_DIR to isolate a second account's login.
function Test-PersonalProfile($Prof) {
    foreach ($k in $GatewayKeys) { if ($Prof['env'].Contains($k)) { return $false } }
    $true
}

# A profile is usable unless it has env keys that are still blank (the placeholders).
function Test-Configured($Prof) {
    foreach ($k in $Prof['env'].Keys) { if ([string]$Prof['env'][$k] -eq '') { return $false } }
    $true
}

function Get-ManagedKeys($Cfg) {
    $keys = New-Object System.Collections.Generic.List[string]
    $keys.AddRange([string[]]$AlwaysManaged)
    foreach ($p in $Cfg['profiles']) { foreach ($k in $p['env'].Keys) { if (-not $keys.Contains($k)) { $keys.Add($k) } } }
    , $keys
}

# CLAUDE_CONFIG_DIR can never live in settings.json - Claude Code needs it to find settings.json
# in the first place - so its current value has to come from the real Windows User environment.
function Get-CurrentManagedEnv($Cfg) {
    $settings = Read-JsonFile $SettingsPath
    $senv = [ordered]@{}
    if ($settings.Contains('env') -and $settings['env'] -is [System.Collections.IDictionary]) {
        foreach ($k in $settings['env'].Keys) { $senv[$k] = $settings['env'][$k] }
    }
    $senv['CLAUDE_CONFIG_DIR'] = [string][Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')
    $senv
}

# Work out the active profile from settings.json (plus the real CLAUDE_CONFIG_DIR env var), so
# manual edits can't leave it stale.
function Get-ActiveId($Cfg) { Get-ProfileIdForEnv $Cfg (Get-CurrentManagedEnv $Cfg) }

# The profile whose env values all appear in $Senv, the plain (no-env) profile when $Senv has no
# managed keys set at all, or $null for a mix that matches nothing.
function Get-ProfileIdForEnv($Cfg, $Senv) {
    $plain = $null
    foreach ($p in $Cfg['profiles']) {
        $vals = @($p['env'].Keys | Where-Object { [string]$p['env'][$_] -ne '' })
        if ($vals.Count -eq 0) { if ($null -eq $plain) { $plain = $p['id'] }; continue }
        $match = $true
        foreach ($k in $vals) { if ([string]$Senv[$k] -ne [string]$p['env'][$k]) { $match = $false; break } }
        if ($match) { return $p['id'] }
    }
    $hasManaged = $false
    foreach ($k in (Get-ManagedKeys $Cfg)) { if ([string]$Senv[$k] -ne '') { $hasManaged = $true } }
    if (-not $hasManaged) { return $plain }
    $null
}

function Backup-Settings {
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return }
    if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    Copy-Item -LiteralPath $SettingsPath -Destination (Join-Path $BackupDir ("settings-{0:yyyyMMdd-HHmmss-fff}.json" -f (Get-Date)))
    Get-ChildItem -LiteralPath $BackupDir -Filter 'settings-*.json' | Sort-Object Name -Descending | Select-Object -Skip 20 | Remove-Item -Force
}

function Set-ActiveProfile($Cfg, [string]$Id) {
    $p = Find-Profile $Cfg $Id
    if (-not $p) { throw "Unknown profile '$Id'." }
    if (-not (Test-Configured $p)) { throw "Profile '$($p['name'])' has blank env values. Fill them in first." }

    $settings = Read-JsonFile $SettingsPath
    Backup-Settings

    if (-not ($settings.Contains('env') -and $settings['env'] -is [System.Collections.IDictionary])) { $settings['env'] = [ordered]@{} }
    foreach ($k in (Get-ManagedKeys $Cfg)) { if ($settings['env'].Contains($k)) { $settings['env'].Remove($k) } }
    # CLAUDE_CONFIG_DIR is mirrored to the real Windows User env only (below), never into
    # settings.json - see Get-CurrentManagedEnv for why.
    foreach ($k in $p['env'].Keys) { if ($k -ne 'CLAUDE_CONFIG_DIR') { $settings['env'][$k] = [string]$p['env'][$k] } }
    if ($settings['env'].Count -eq 0) { $settings.Remove('env') }

    $model = [string]$p['model']
    if ($model) { $settings['model'] = $model } elseif ($settings.Contains('model')) { $settings.Remove('model') }

    Write-JsonFile $SettingsPath $settings
    Set-ManagedUserEnv $Cfg $p
}

# Mirrors the managed keys into real Windows User environment variables, so tools that read
# $env:ANTHROPIC_API_KEY etc. directly (outside Claude Code's own settings.json) see the switch too.
function Set-ManagedUserEnv($Cfg, $Prof) {
    foreach ($k in (Get-ManagedKeys $Cfg)) {
        $val = if ($Prof['env'].Contains($k)) { [string]$Prof['env'][$k] } else { '' }
        $current = [Environment]::GetEnvironmentVariable($k, 'User')
        if ($val) {
            if ($current -ne $val) { [Environment]::SetEnvironmentVariable($k, $val, 'User') }
        } elseif ($null -ne $current) {
            [Environment]::SetEnvironmentVariable($k, $null, 'User')
        }
    }
    Sync-ProcessManagedEnv $Cfg
}

# Brings this process's own copy of the managed keys in line with what a freshly started program
# would get (User, else Machine), so anything we launch - e.g. `claude -p` for a login refresh - uses
# the active source rather than whatever was set when the tray app started.
function Sync-ProcessManagedEnv($Cfg) {
    foreach ($k in (Get-ManagedKeys $Cfg)) {
        $val = [Environment]::GetEnvironmentVariable($k, 'User')
        if (-not $val) { $val = [Environment]::GetEnvironmentVariable($k, 'Machine') }
        [Environment]::SetEnvironmentVariable($k, $(if ($val) { $val } else { $null }), 'Process')
    }
}

# ---------- stale app environments ----------
# Windows gives each program a copy of the environment when it starts, and nothing can change that
# copy afterwards. An editor started while a gateway was active keeps that gateway's ANTHROPIC_* values
# for as long as it runs, and so does every Claude Code session it starts - settings.json can override
# a variable but not remove one, so switching back to Personal silently does nothing in there.

# Process name -> label, for the long-running apps that host Claude Code sessions.
$StaleEnvApps = [ordered]@{ 'Code' = 'VS Code'; 'Code - Insiders' = 'VS Code Insiders'; 'Cursor' = 'Cursor'; 'Windsurf' = 'Windsurf' }

# Another process's environment, read from its PEB, as a (case-insensitive) hashtable; $null if we
# can't read it (elevated, protected, or this isn't a 64-bit PowerShell).
function Read-ProcessEnv([int]$ProcessId) {
    if (-not ('ProcEnvReader' -as [type])) {
        Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class ProcEnvReader {
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, byte[] info, int len, out int ret);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    static byte[] Read(IntPtr h, long addr, int size) {
        var b = new byte[size]; IntPtr n;
        return (ReadProcessMemory(h, new IntPtr(addr), b, new IntPtr(size), out n) && (long)n == size) ? b : null;
    }
    // x64 layout: PEB+0x20 -> RTL_USER_PROCESS_PARAMETERS; +0x80 Environment, +0x3F0 EnvironmentSize.
    public static string Get(int pid) {
        if (IntPtr.Size != 8) return null;
        IntPtr h = OpenProcess(0x1000 | 0x0010, false, pid);   // QUERY_LIMITED_INFORMATION | VM_READ
        if (h == IntPtr.Zero) return null;
        try {
            var pbi = new byte[48]; int ret;
            if (NtQueryInformationProcess(h, 0, pbi, pbi.Length, out ret) != 0) return null;
            var pp = Read(h, BitConverter.ToInt64(pbi, 8) + 0x20, 8); if (pp == null) return null;
            long pars = BitConverter.ToInt64(pp, 0);
            var ev = Read(h, pars + 0x80, 8); var es = Read(h, pars + 0x3F0, 8);
            if (ev == null || es == null) return null;
            long env = BitConverter.ToInt64(ev, 0), size = BitConverter.ToInt64(es, 0);
            if (env == 0 || size <= 0 || size > (1 << 22)) return null;
            var buf = Read(h, env, (int)size);
            return buf == null ? null : Encoding.Unicode.GetString(buf);
        } finally { CloseHandle(h); }
    }
}
"@
    }
    $raw = $null
    try { $raw = [ProcEnvReader]::Get($ProcessId) } catch { }
    if (-not $raw) { return $null }
    $h = @{}
    foreach ($line in ($raw -split "`0")) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $h[$line.Substring(0, $i)] = $line.Substring($i + 1) }   # skips the "=C:=C:\" entries
    }
    $h
}

# Running apps whose inherited environment disagrees with the active profile in a way Claude Code inside
# them can't recover from: a gateway key the active profile doesn't set (settings.json can't unset it),
# or a different CLAUDE_CONFIG_DIR (never in settings.json at all). One entry per app, with the name of
# the source its leftovers match, if any.
function Get-StaleApps($Cfg) {
    $active = Get-ActiveId $Cfg
    $ap = if ($active) { Find-Profile $Cfg $active } else { $null }
    if (-not $ap) { return , @() }
    $keys = Get-ManagedKeys $Cfg
    $found = @()
    foreach ($name in $StaleEnvApps.Keys) {
        foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $penv = Read-ProcessEnv $proc.Id
            if ($null -eq $penv) { continue }
            $bad = @(foreach ($k in $keys) {
                    $have = [string]$penv[$k]; $want = [string]$ap['env'][$k]
                    if ($k -eq 'CLAUDE_CONFIG_DIR') { if ($have.TrimEnd('\') -ne $want.TrimEnd('\')) { $k } }
                    elseif ($have -and -not $want) { $k }
                })
            if ($bad.Count -eq 0) { continue }
            $srcId = Get-ProfileIdForEnv $Cfg $penv
            $src = if ($srcId -and $srcId -ne $active) { [string](Find-Profile $Cfg $srcId)['name'] } else { $null }
            $found += , @{ Label = $StaleEnvApps[$name]; Keys = $bad; Source = $src }
            break
        }
    }
    , $found
}

# One sentence for the window/balloon/CLI, or '' when nothing is stale.
function Get-StaleAppsText($Stale) {
    if ($Stale.Count -eq 0) { return '' }
    $names = @($Stale | ForEach-Object { $_.Label })
    $who = if ($names.Count -eq 1) { $names[0] } else { ($names[0..($names.Count - 2)] -join ', ') + ' and ' + $names[-1] }
    $srcs = @($Stale | ForEach-Object { $_.Source } | Where-Object { $_ } | Select-Object -Unique)
    $src = if ($srcs.Count -eq 1) { $srcs[0] } else { 'an earlier source' }
    if ($names.Count -eq 1) { "$who is still using $src - it keeps the settings it started with. Quit it fully (File > Exit) and start it again." }
    else { "$who are still using $src - they keep the settings they started with. Quit each fully (File > Exit) and start it again." }
}

# ---------- connection tester ----------

Add-Type -AssemblyName System.Net.Http
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
$TestTimeoutSec = 25

function New-TestClient {
    # Use the system proxy with the signed-in Windows credentials, as corporate networks expect.
    $proxy = [System.Net.WebRequest]::DefaultWebProxy
    if ($proxy) { $proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
    $handler = New-Object System.Net.Http.HttpClientHandler
    if ($proxy) { $handler.Proxy = $proxy }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TestTimeoutSec)
    $client
}

# $ConfigDirOverride is a profile's CLAUDE_CONFIG_DIR (a 2nd personal account's isolated
# config dir); empty means the default ~/.claude.
function Get-CredentialsPath([string]$ConfigDirOverride = '') {
    $dir = if ($ConfigDirOverride) { $ConfigDirOverride } else { Join-Path $env:USERPROFILE '.claude' }
    Join-Path $dir '.credentials.json'
}

function Get-PersonalLoginNote([string]$ConfigDirOverride = '') {
    # Reads only the expiry timestamp, never the token itself.
    $path = Get-CredentialsPath $ConfigDirOverride
    if (-not (Test-Path -LiteralPath $path)) { return @{ Found = $false; Text = 'no login found - run "claude" and use /login' } }
    try {
        $oauth = (Read-JsonFile $path)['claudeAiOauth']
        if ($oauth -and $oauth.Contains('expiresAt')) {
            $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$oauth['expiresAt']).LocalDateTime
            if ($exp -gt (Get-Date)) {
                $left = $exp - (Get-Date)
                $when = if ($left.TotalHours -ge 1) { '{0:N0}h' -f $left.TotalHours } else { '{0:N0}m' -f $left.TotalMinutes }
                return @{ Found = $true; Text = "login found, access token valid for ~$when" }
            }
            return @{ Found = $true; Text = 'login found, access token expired (Claude Code refreshes it on next use)' }
        }
        if ($oauth) { return @{ Found = $true; Text = 'login found' } }
    } catch { }
    @{ Found = $false; Text = 'no usable login found - run "claude" and use /login' }
}

function Get-TestModel($Prof) {
    foreach ($v in @([string]$Prof['model'], [string]$Prof['env']['ANTHROPIC_MODEL'], [string]$Prof['env']['ANTHROPIC_DEFAULT_HAIKU_MODEL'], [string]$Prof['env']['ANTHROPIC_SMALL_FAST_MODEL'])) {
        if ($v) { return $v }
    }
    'claude-haiku-4-5-20251001'
}

function Test-ModelError([string]$Text) { $Text -match '(?i)\bmodels?\b' }

# Builds and sends one request to a gateway profile without blocking. $Over can change any part of it:
# Base, Path, Method, Auth (auto|bearer|apikey), Model, plus Key/Desc labels for the caller.
function New-GatewayProbe($Prof, [hashtable]$Over = @{}) {
    $penv = $Prof['env']
    $base = if ($Over.ContainsKey('Base')) { [string]$Over['Base'] } else { [string]$penv['ANTHROPIC_BASE_URL'] }
    $base = $base.Trim().TrimEnd('/')
    if (-not $base) { $base = 'https://api.anthropic.com' }
    $path = if ($Over.ContainsKey('Path')) { [string]$Over['Path'] } else { '/v1/messages' }
    $method = if ($Over.ContainsKey('Method')) { [string]$Over['Method'] } else { 'POST' }
    $auth = if ($Over.ContainsKey('Auth')) { [string]$Over['Auth'] } else { 'auto' }
    $model = if ($Over.ContainsKey('Model')) { [string]$Over['Model'] } else { Get-TestModel $Prof }
    $token = [string]$penv['ANTHROPIC_AUTH_TOKEN']
    $key = [string]$penv['ANTHROPIC_API_KEY']
    $secret = if ($token) { $token } else { $key }
    $url = $base + $path

    $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $method), $url
    [void]$req.Headers.TryAddWithoutValidation('anthropic-version', '2023-06-01')
    switch ($auth) {
        'bearer' { if ($secret) { [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $secret") } }
        'apikey' { if ($secret) { [void]$req.Headers.TryAddWithoutValidation('x-api-key', $secret) } }
        default {
            if ($token) { [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $token") }
            if ($key) { [void]$req.Headers.TryAddWithoutValidation('x-api-key', $key) }
        }
    }
    foreach ($line in (([string]$penv['ANTHROPIC_CUSTOM_HEADERS']) -split "`r?`n")) {
        $i = $line.IndexOf(':')
        if ($i -gt 0) { [void]$req.Headers.TryAddWithoutValidation($line.Substring(0, $i).Trim(), $line.Substring($i + 1).Trim()) }
    }
    if ($method -eq 'POST') {
        $body = @{ model = $model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'hi' }) } | ConvertTo-Json -Depth 5 -Compress
        $req.Content = New-Object System.Net.Http.StringContent -ArgumentList $body, ([System.Text.Encoding]::UTF8), 'application/json'
    }
    $client = New-TestClient
    [ordered]@{
        Key = [string]$Over['Key']; Desc = [string]$Over['Desc']; Model = $model; Url = $url
        Client = $client; Task = $client.SendAsync($req); Sw = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

# Turns a finished request into plain data: Kind is 'net' (no HTTP reply) or 'http'.
function Get-ProbeResult($Task) {
    $r = @{ Kind = 'http'; Code = 0; Raw = ''; Json = $null; Detail = ''; Net = ''; Ms = 0; Headers = [ordered]@{} }
    if ($Task.IsCanceled) {
        $r.Kind = 'net'; $r.Net = "Timed out after ${TestTimeoutSec}s - host unreachable, or blocked by a firewall/proxy."
        return $r
    }
    if ($Task.IsFaulted) {
        # Keep the whole exception chain: the outer messages are generic, the inner one has the real cause.
        $msgs = New-Object System.Collections.Generic.List[string]
        $e = $Task.Exception
        while ($e) { if ($e -isnot [System.AggregateException] -and -not $msgs.Contains($e.Message)) { $msgs.Add($e.Message) }; $e = $e.InnerException }
        $r.Kind = 'net'; $r.Net = "Unreachable: $($msgs -join ' -> ')"
        return $r
    }
    $resp = $Task.Result
    $r.Code = [int]$resp.StatusCode
    foreach ($h in $resp.Headers) { $r.Headers[$h.Key.ToLower()] = ($h.Value -join ', ') }
    try { $r.Raw = $resp.Content.ReadAsStringAsync().Result } catch { }
    $detail = ''
    try {
        $j = ConvertFrom-Json $r.Raw
        $r.Json = $j
        if ($j.error.message) { $detail = [string]$j.error.message } elseif ($j.message) { $detail = [string]$j.message }
    } catch { }
    # Not JSON (e.g. an HTML page from a proxy or login wall): show its readable text instead.
    if (-not $detail -and $r.Raw) { $detail = ($r.Raw -replace '(?is)<(script|style).*?</\1>', ' ' -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim() }
    if ($detail.Length -gt 800) { $detail = $detail.Substring(0, 800) + '...' }
    $r.Detail = $detail
    $r
}

# True only for a real Claude API message, so a proxy login page returning 200 doesn't count.
function Test-Live($R) {
    $R.Kind -eq 'http' -and $R.Code -ge 200 -and $R.Code -lt 300 -and $R.Json -and ($R.Json.type -eq 'message' -or $R.Json.content)
}

# Starts the request without blocking; poll Update-TestClock / Get-TestOutcome for the result.
function Start-ProfileTest($Prof) {
    $t = [ordered]@{
        Id = $Prof['id']; Name = $Prof['name']; Kind = 'gateway'; Task = $null; Client = $null
        Failure = $null; Item = $null; Shown = $false; Sw = [System.Diagnostics.Stopwatch]::StartNew()
        ConfigDir = [string]$Prof['env']['CLAUDE_CONFIG_DIR']
    }
    if (-not (Test-Configured $Prof)) {
        $t.Failure = @{ Level = 'warn'; Text = 'Not configured - fill in the blank values first.' }
        return $t
    }
    if (Test-PersonalProfile $Prof) {
        $t.Kind = 'personal'
        $t.Client = New-TestClient
        $t.Task = $t.Client.GetAsync('https://api.anthropic.com/')
        return $t
    }
    $probe = New-GatewayProbe $Prof @{}
    $t.Client = $probe.Client
    $t.Task = $probe.Task
    $t
}

# Freeze the stopwatch when the request finishes so latency isn't inflated by our polling.
function Update-TestClock($T) {
    if ($T.Task -and $T.Task.IsCompleted -and $T.Sw.IsRunning) { $T.Sw.Stop() }
}

function Test-Finished($T) { [bool]($T.Failure -or ($T.Task -and $T.Task.IsCompleted)) }

function Get-TestOutcome($T) {
    if ($T.Failure) { return @{ Level = $T.Failure.Level; Text = $T.Failure.Text; Ms = $null } }
    $ms = [int]$T.Sw.ElapsedMilliseconds
    $r = Get-ProbeResult $T.Task
    if ($r.Kind -eq 'net') { return @{ Level = 'fail'; Ms = $null; Text = $r.Net } }

    $code = $r.Code
    $detail = $r.Detail
    $suffix = if ($detail) { " - $detail" } else { '' }

    if ($T.Kind -eq 'personal') {
        $login = Get-PersonalLoginNote $T.ConfigDir
        $lvl = if ($login.Found) { 'ok' } else { 'warn' }
        return @{ Level = $lvl; Ms = $ms; Text = "api.anthropic.com reachable; $($login.Text). (Login not verified server-side.)" }
    }

    if (Test-Live $r) { return @{ Level = 'ok'; Ms = $ms; Text = 'Live - request accepted and authenticated.' } }
    if ($code -ge 200 -and $code -lt 300) {
        return @{ Level = 'warn'; Ms = $ms; Text = "HTTP $code but the reply is not a Claude API message - likely a proxy, login page or wrong URL. Reply: $detail" }
    }
    $tip = if (Test-ModelError $detail) { "  [Tip: select this row and click Troubleshoot to find a model this source allows]" } else { '' }
    switch ($code) {
        { $_ -in 401, 403 } { return @{ Level = 'fail'; Ms = $ms; Text = "Reachable, but credentials rejected ($code)$suffix$tip" } }
        404 { return @{ Level = 'fail'; Ms = $ms; Text = "Reachable, but endpoint or model not found (404) - check base URL / model$suffix$tip" } }
        400 { return @{ Level = 'warn'; Ms = $ms; Text = "Reachable; request rejected (400) - often a wrong model name$suffix$tip" } }
        429 { return @{ Level = 'ok'; Ms = $ms; Text = "Live, but rate limited (429)$suffix" } }
        default {
            $lvl = if ($code -ge 500) { 'fail' } else { 'warn' }
            return @{ Level = $lvl; Ms = $ms; Text = "Unexpected HTTP $code$suffix" }
        }
    }
}

function Stop-ProfileTest($T) { if ($T.Client) { $T.Client.Dispose() } }

# ---------- usage check ----------
# Personal: Anthropic's plan-usage endpoint (the one Claude Code's /usage reads), with the login token held in memory only.
# Gateways (LiteLLM): key spend from response headers, plus /key/info and /team/info for budgets and limits when exposed.

$UsageCachePath = Join-Path $ConfigDir 'usage-cache.json'
$UsageReuseSec = 30       # Anthropic rate-limits the plan-usage call, so a very recent result is reused

# IBM ICA's gateway exposes spend via the response header but not a budget via /key/info or /team/info.
# That header is lifetime key spend, while the ICA admin portal (not reachable from here) counts "Advantage Credits"
# against a weekly quota of 500 that resets every Monday 08:00 SGT. Calibration from the portal:
#   2026-09-24: 94 credits at $140.81 lifetime spend -> about $1.50 per credit
#   2026-09-29: 46 credits (9%) at $231.92 lifetime spend -> the week from Mon 28 Sep started at about $163.01
# Later weeks start from the last spend seen before their reset (kept in the usage cache), so they may slightly
# overcount if the key was used between that last check and the reset.
$IcaWeeklyCredits = 500
$IcaUsdPerCredit = 140.81 / 94
$IcaSeedWeek = '2026-09-28'
$IcaSeedWeekStartSpend = 231.92 - 46 * $IcaUsdPerCredit

# Start of the current ICA credit week (Monday 08:00 SGT, UTC+8 with no DST) as a DateTimeOffset.
function Get-IcaWeekStart {
    $sg = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
    $start = (New-Object DateTimeOffset -ArgumentList $sg.Date, $sg.Offset).AddHours(8).AddDays(-((([int]$sg.DayOfWeek) + 6) % 7))
    if ($start -gt $sg) { $start = $start.AddDays(-7) }
    $start
}

# Spend at the start of the current ICA week, remembering the last spend seen so the next week has a baseline.
function Get-IcaWeekStartSpend([double]$Spend, [string]$Week) {
    $c = $null; $st = $null
    try { $c = Read-JsonFile $UsageCachePath; if ($c.Contains('ica-week')) { $st = $c['ica-week'] } } catch { }
    $base = if ($Week -eq $IcaSeedWeek) { $IcaSeedWeekStartSpend }
            elseif ($st -and [string]$st['week'] -eq $Week) { [double]$st['base'] }
            elseif ($st -and $null -ne $st['last']) { [double]$st['last'] }
            else { $Spend }
    if ($base -gt $Spend) { $base = $Spend }
    if ($c) { try { $c['ica-week'] = [ordered]@{ week = $Week; base = $base; last = $Spend }; Write-JsonFile $UsageCachePath $c } catch { } }
    $base
}

function Get-ShortDetail($R) {
    if ($R.Kind -eq 'net') { return $R.Net }
    $d = [string]$R.Detail
    if ($d.Length -gt 220) { $d = $d.Substring(0, 220) + '...' }
    if ($d) { "HTTP $($R.Code): $d" } else { "HTTP $($R.Code)" }
}

function Format-Duration([TimeSpan]$Span) {
    if ($Span.TotalMinutes -lt 1) { return 'under a minute' }
    if ($Span.TotalHours -lt 1) { return '{0}m' -f [int]$Span.TotalMinutes }
    if ($Span.TotalDays -lt 1) { return '{0}h {1}m' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes }
    '{0}d {1}h' -f [int][Math]::Floor($Span.TotalDays), $Span.Hours
}

function Format-ResetTime($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    try {
        $t = if ($Value -is [datetime]) { $Value.ToLocalTime() } else { [DateTimeOffset]::Parse([string]$Value).LocalDateTime }
        $left = $t - (Get-Date)
        if ($left.TotalSeconds -le 0) { return 'resets now' }
        $abs = if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') } else { $t.ToString('ddd d MMM HH:mm') }
        "resets in $(Format-Duration $left) ($abs)"
    } catch { '' }
}

# Compact absolute reset time for one-line summaries: "today 13:40", "tomorrow 06:00", "Thu 06:00", "1 Oct".
# Absolute (not "in 46m") so a cached summary never goes stale.
function Format-ResetShort($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    try {
        $t = if ($Value -is [datetime]) { $Value.ToLocalTime() } else { [DateTimeOffset]::Parse([string]$Value).LocalDateTime }
        $days = ($t.Date - (Get-Date).Date).Days
        if ($days -le 0) { return 'today ' + $t.ToString('HH:mm') }
        if ($days -eq 1) { return 'tomorrow ' + $t.ToString('HH:mm') }
        if ($days -lt 7) { return $t.ToString('ddd HH:mm') }
        $t.ToString('d MMM')
    } catch { '' }
}

function Format-Money($Amount, [string]$Currency = 'USD') {
    $n = '{0:N2}' -f [double]$Amount
    if ($Currency -eq 'USD') { "`$$n" } else { "$Currency $n" }
}

function Get-PctLevel([double]$Pct) { if ($Pct -ge 100) { 'fail' } elseif ($Pct -ge 80) { 'warn' } else { 'ok' } }

function Add-UsageLine($U, [string]$Text, [string]$Level = 'ok') {
    $U.Lines.Add($Text)
    if ($Level -eq 'fail' -or ($Level -eq 'warn' -and $U.Level -eq 'ok')) { $U.Level = $Level }
}

# One "spent X of Y" line for a key/team budget, or "no budget cap" when none is set.
function Add-BudgetLine($U, [string]$Label, $Spend, $Max, $Duration, $ResetAt) {
    $s = if ($null -ne $Spend -and "$Spend" -ne '') { [double]$Spend } else { 0.0 }
    if ($null -ne $Max -and "$Max" -ne '' -and [double]$Max -gt 0) {
        $pct = $s / [double]$Max * 100
        $extra = @()
        if ($Duration) { $extra += "budget period $Duration" }
        $rt = Format-ResetTime $ResetAt; if ($rt) { $extra += $rt }
        $tail = if ($extra.Count) { ' - ' + ($extra -join ', ') } else { '' }
        Add-UsageLine $U ("{0}: spent {1} of {2} ({3:N0}%){4}" -f $Label, (Format-Money $s), (Format-Money $Max), $pct, $tail) (Get-PctLevel $pct)
        $rs = Format-ResetShort $ResetAt
        $U.Short.Add(("{0} {1} of {2} ({3:N0}%){4}" -f $Label, (Format-Money $s), (Format-Money $Max), $pct, $(if ($rs) { " - resets $rs" } else { '' })))
    } else {
        Add-UsageLine $U ("{0}: spent {1} - no budget cap set" -f $Label, (Format-Money $s))
        $U.Short.Add(("{0} {1}, no cap" -f $Label, (Format-Money $s)))
    }
}

function New-PersonalUsageProbe([string]$ConfigDirOverride = '') {
    $tok = ''
    try { $tok = [string]((Read-JsonFile (Get-CredentialsPath $ConfigDirOverride))['claudeAiOauth']['accessToken']) } catch { }
    if (-not $tok) { return $null }
    $client = New-TestClient
    $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList 'GET'), 'https://api.anthropic.com/api/oauth/usage'
    [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $tok")
    [void]$req.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
    [void]$req.Headers.TryAddWithoutValidation('User-Agent', 'claude-switcher/1.0')
    $tok = $null
    [ordered]@{ Key = 'oauth'; Client = $client; Task = $client.SendAsync($req); Sw = [System.Diagnostics.Stopwatch]::StartNew() }
}

function Get-UsageCache([string]$Id) {
    try { $c = Read-JsonFile $UsageCachePath; if ($c.Contains($Id)) { return $c[$Id] } } catch { }
    $null
}

function Set-UsageCache([string]$Id, $U) {
    try {
        $c = Read-JsonFile $UsageCachePath
        $c[$Id] = [ordered]@{ time = (Get-Date).ToString('o'); level = $U.Level; summary = $U.Summary; lines = @($U.Lines) }
        Write-JsonFile $UsageCachePath $c
    } catch { }
}

# Starts a usage check without blocking; call Step-UsageCheck until it returns $true.
function Start-UsageCheck($Prof) {
    $u = [ordered]@{
        Id = $Prof['id']; Name = $Prof['name']; Kind = 'gateway'; Probes = [ordered]@{}; Stage = 1; Done = $false
        Level = 'ok'; Summary = ''; Lines = (New-Object System.Collections.Generic.List[string]); Shown = $false; Item = $null; Prof = $Prof; Data = $null
        Short = (New-Object System.Collections.Generic.List[string])
    }
    if (-not (Test-Configured $Prof)) {
        $u.Level = 'warn'; $u.Summary = 'Not configured'; $u.Lines.Add('Fill in the blank values first (Edit profiles).'); $u.Done = $true
        return $u
    }
    if (Test-PersonalProfile $Prof) {
        $u.Kind = 'personal'
        $cached = Get-UsageCache $u.Id
        if ($cached) {
            $age = (Get-Date) - [datetime]::Parse([string]$cached['time'])
            if ($age.TotalSeconds -lt $UsageReuseSec -and $cached['level'] -ne 'fail') {
                foreach ($l in $cached['lines']) { $u.Lines.Add([string]$l) }
                $u.Lines.Add("(Reusing the result from $([int]$age.TotalSeconds)s ago - Anthropic limits how often this can be checked.)")
                $u.Level = [string]$cached['level']; $u.Summary = [string]$cached['summary']; $u.Done = $true
                return $u
            }
        }
        $probe = New-PersonalUsageProbe ([string]$Prof['env']['CLAUDE_CONFIG_DIR'])
        if (-not $probe) {
            $u.Level = 'fail'; $u.Summary = 'No login found'; $u.Lines.Add('No Claude login token found. Run "claude" in a terminal and use /login.'); $u.Done = $true
            return $u
        }
        $u.Probes['oauth'] = $probe
        return $u
    }
    # Gateway: a 1-token message (its response headers carry the key's spend) and the LiteLLM key info.
    $model = [string]$Prof['env']['ANTHROPIC_DEFAULT_HAIKU_MODEL']; if (-not $model) { $model = Get-TestModel $Prof }
    $u.Probes['msg'] = New-GatewayProbe $Prof @{ Key = 'msg'; Model = $model }
    $u.Probes['key'] = New-GatewayProbe $Prof @{ Key = 'key'; Method = 'GET'; Path = '/key/info' }
    $u
}

function Complete-GatewayUsage1($U) {
    $msg = Get-ProbeResult $U.Probes['msg'].Task
    $key = Get-ProbeResult $U.Probes['key'].Task
    if ($msg.Kind -eq 'net' -and $key.Kind -eq 'net') {
        $U.Level = 'fail'; $U.Summary = 'Unreachable'; $U.Lines.Add($msg.Net); $U.Done = $true; return
    }
    $info = $null
    if ($key.Kind -eq 'http' -and $key.Code -eq 200 -and $key.Json -and $key.Json.info) { $info = $key.Json.info }
    $hdrSpend = $msg.Headers['x-litellm-key-spend']

    if ($info) {
        Add-BudgetLine $U 'Key' $info.spend $info.max_budget $info.budget_duration $info.budget_reset_at
        $lim = @()
        if ($info.rpm_limit) { $lim += "$($info.rpm_limit) requests/min" }
        if ($info.tpm_limit) { $lim += "$($info.tpm_limit) tokens/min" }
        if ($info.max_parallel_requests) { $lim += "$($info.max_parallel_requests) parallel requests" }
        Add-UsageLine $U $(if ($lim.Count) { 'Key rate limits: ' + ($lim -join ', ') } else { 'Key rate limits: none set' })
        if ($info.expires) { Add-UsageLine $U ("Key expires: " + (Format-ResetTime $info.expires).Replace('resets', 'in').Replace('in in', 'in')) }
        if ($info.blocked) { Add-UsageLine $U 'This key is BLOCKED by the gateway.' 'fail' }
        if ($info.team_id) {
            $U.Probes['team'] = New-GatewayProbe $U.Prof @{ Key = 'team'; Method = 'GET'; Path = '/team/info?team_id=' + [uri]::EscapeDataString([string]$info.team_id) }
            $U.Data = @{ TeamId = [string]$info.team_id; Header = $hdrSpend; Msg = $msg }
            $U.Stage = 2
            return
        }
    } elseif ($null -ne $hdrSpend -and $hdrSpend -ne '') {
        $why = if ($key.Kind -eq 'http') { "this gateway does not expose /key/info (HTTP $($key.Code))" } else { '/key/info was unreachable' }
        if ($U.Prof['id'] -eq 'ica' -and $IcaWeeklyCredits -gt 0) {
            $start = Get-IcaWeekStart
            $reset = $start.AddDays(7)
            $base = Get-IcaWeekStartSpend ([double]$hdrSpend) $start.ToString('yyyy-MM-dd')
            $credits = ([double]$hdrSpend - $base) / $IcaUsdPerCredit
            $pct = $credits / $IcaWeeklyCredits * 100
            $rt = Format-ResetTime $reset.UtcDateTime
            Add-UsageLine $U ("Advantage Credits this week: ~{0:N0} of {1} ({2:N0}%) - estimated{3}" -f $credits, $IcaWeeklyCredits, $pct, $(if ($rt) { ", $rt" } else { '' })) (Get-PctLevel $pct)
            Add-UsageLine $U ("Key spend: {0} lifetime, {1} since the Monday 08:00 SGT reset (read from response headers; {2}; credits estimated at ~{3} each)" -f (Format-Money $hdrSpend), (Format-Money ([double]$hdrSpend - $base)), $why, (Format-Money $IcaUsdPerCredit))
            $rs = Format-ResetShort $reset.UtcDateTime
            $U.Short.Add(("Credits ~{0:N0} of {1} ({2:N0}%){3}" -f $credits, $IcaWeeklyCredits, $pct, $(if ($rs) { " - resets $rs" } else { '' })))
        } else {
            Add-UsageLine $U ("Key spend so far: {0}  (read from response headers; {1}, so no budget or limits are shown)" -f (Format-Money $hdrSpend), $why)
            $U.Short.Add(("Key spend {0} (budget not exposed)" -f (Format-Money $hdrSpend)))
        }
    } else {
        $U.Level = 'warn'
        Add-UsageLine $U "Could not read spend. Test message: $(Get-ShortDetail $msg)" 'warn'
        if (Test-ModelError $msg.Detail) { Add-UsageLine $U 'The gateway rejected the model - use Troubleshoot in Test connections to pick one.' 'warn' }
    }
    Add-UsageRateHeaders $U $msg
    Complete-Usage $U
}

function Add-UsageRateHeaders($U, $Msg) {
    foreach ($h in $Msg.Headers.Keys) {
        if ($h -match '^(x-ratelimit|x-litellm-key-remaining|anthropic-ratelimit|retry-after)') { Add-UsageLine $U ("{0}: {1}" -f $h, $Msg.Headers[$h]) }
    }
}

function Complete-GatewayUsage2($U) {
    $t = Get-ProbeResult $U.Probes['team'].Task
    $ti = if ($t.Kind -eq 'http' -and $t.Code -eq 200 -and $t.Json) { $t.Json.team_info } else { $null }
    if ($ti) {
        Add-BudgetLine $U "Team $($U.Data.TeamId)" $ti.spend $ti.max_budget $ti.budget_duration $ti.budget_reset_at
        $lim = @(); if ($ti.rpm_limit) { $lim += "$($ti.rpm_limit) requests/min" }; if ($ti.tpm_limit) { $lim += "$($ti.tpm_limit) tokens/min" }
        if ($lim.Count) { Add-UsageLine $U ('Team rate limits: ' + ($lim -join ', ')) }
        if ($ti.blocked) { Add-UsageLine $U 'This team is BLOCKED by the gateway.' 'fail' }
    } else {
        Add-UsageLine $U ("Team {0}: budget not readable ({1})" -f $U.Data.TeamId, (Get-ShortDetail $t))
    }
    Add-UsageRateHeaders $U $U.Data.Msg
    Complete-Usage $U
}

function Complete-PersonalUsage($U) {
    $r = Get-ProbeResult $U.Probes['oauth'].Task
    $cached = Get-UsageCache $U.Id
    $stale = {
        if ($cached) {
            $when = [datetime]::Parse([string]$cached['time'])
            $U.Lines.Add("Last known usage (from $($when.ToString('HH:mm')), $(Format-Duration ((Get-Date) - $when)) ago; reset times below were true then):")
            foreach ($l in $cached['lines']) { $U.Lines.Add('   ' + [string]$l) }
            $U.Summary += " - showing last known ($($when.ToString('HH:mm')))"
        }
    }
    if ($r.Kind -eq 'net') {
        $U.Level = 'fail'; $U.Summary = 'Unreachable'; $U.Lines.Add($r.Net); & $stale; $U.Done = $true; return
    }
    if ($r.Code -eq 429) {
        $U.Level = 'warn'; $U.Summary = 'Anthropic is rate-limiting this check'
        $U.Lines.Add('Anthropic rate-limits the plan-usage call itself (Claude Code hits the same limit and falls back to its last known bars). Try again in a few minutes.')
        & $stale; $U.Done = $true; return
    }
    if ($r.Code -in 401, 403) {
        $U.Level = 'fail'; $U.Summary = 'Login token expired or rejected'
        $U.Lines.Add("The saved login token was rejected (HTTP $($r.Code)). Open Claude Code once so it refreshes the token, or run /login.")
        & $stale; $U.Done = $true; return
    }
    if ($r.Code -ne 200 -or -not $r.Json) {
        $U.Level = 'warn'; $U.Summary = "Unexpected reply (HTTP $($r.Code))"; $U.Lines.Add((Get-ShortDetail $r)); $U.Done = $true; return
    }

    $j = $r.Json
    $sum = @()
    foreach ($w in @(@('Session (5-hour window)', 'five_hour', 'Session'), @('Weekly (all models)', 'seven_day', 'Weekly'), @('Weekly Opus', 'seven_day_opus', 'Opus'), @('Weekly Sonnet', 'seven_day_sonnet', 'Sonnet'))) {
        $o = $j.($w[1])
        if ($o -and $null -ne $o.utilization) {
            $pct = [double]$o.utilization
            $rt = Format-ResetTime $o.resets_at
            Add-UsageLine $U ("{0}: {1:N0}% used{2}" -f $w[0], $pct, $(if ($rt) { " - $rt" } else { '' })) (Get-PctLevel $pct)
            $rs = Format-ResetShort $o.resets_at
            $sum += ('{0} {1:N0}%{2}' -f $w[2], $pct, $(if ($rs) { " - resets $rs" } else { '' }))
        }
    }
    $x = $j.extra_usage
    if ($x -and $x.monthly_limit) {
        $dec = if ($null -ne $x.decimal_places) { [int]$x.decimal_places } else { 2 }
        $div = [Math]::Pow(10, $dec)
        $cur = if ($x.currency) { [string]$x.currency } else { 'USD' }
        $state = if ($x.is_enabled) { '' } else { " - currently off" + $(if ($x.disabled_reason) { " ($($x.disabled_reason))" } else { '' }) }
        Add-UsageLine $U ("Usage credits this month: {0} of {1} ({2:N0}%){3}" -f (Format-Money ([double]$x.used_credits / $div) $cur), (Format-Money ([double]$x.monthly_limit / $div) $cur), [double]$x.utilization, $state)
    }
    if ($sum.Count -eq 0) { $U.Level = 'warn'; $U.Lines.Add('The reply had no session or weekly figures (the plan may not have usage limits).') }
    $U.Summary = if ($sum.Count) { $sum -join ' | ' } else { 'No limits reported' }
    $U.Done = $true
    Set-UsageCache $U.Id $U
}

function Complete-Usage($U) {
    $U.Summary = if ($U.Short.Count) { $U.Short -join '  |  ' } else { @($U.Lines | Select-Object -First 2) -join '  |  ' }
    $U.Done = $true
}

# Advances the check when its requests have finished; returns $true once the check is complete.
function Step-UsageCheck($U) {
    if ($U.Done) { return $true }
    foreach ($p in $U.Probes.Values) { if (-not $p.Task.IsCompleted) { return $false } }
    if ($U.Kind -eq 'personal') { Complete-PersonalUsage $U }
    elseif ($U.Stage -eq 1) { Complete-GatewayUsage1 $U }
    else { Complete-GatewayUsage2 $U }
    $U.Done
}

function Stop-UsageCheck($U) { foreach ($p in $U.Probes.Values) { if ($p.Client) { $p.Client.Dispose() } } }

# ---------- CLI mode ----------

if ($List -or $Use) {
    $cfg = Get-Config
    if ($Use) {
        Set-ActiveProfile $cfg $Use
        Write-Host "Switched to '$Use'. Restart any running Claude Code sessions."
    }
    $active = Get-ActiveId $cfg
    foreach ($p in $cfg['profiles']) {
        $mark = if ($p['id'] -eq $active) { '*' } else { ' ' }
        $state = if (Test-Configured $p) { '' } else { '  (not configured)' }
        Write-Host ("{0} {1,-10} {2}{3}" -f $mark, $p['id'], $p['name'], $state)
    }
    $staleText = Get-StaleAppsText (Get-StaleApps $cfg)
    if ($staleText) { Write-Host "`n$staleText" -ForegroundColor Yellow }
    if (-not $Test) { return }
}

if ($Test) {
    $cfg = Get-Config
    $runs = @()
    foreach ($p in $cfg['profiles']) { if ($Test -eq 'all' -or $Test -eq $p['id']) { $runs += , (Start-ProfileTest $p) } }
    if ($runs.Count -eq 0) { throw "Unknown profile '$Test'. Use 'all' or one of: $((@($cfg['profiles'] | ForEach-Object { $_['id'] })) -join ', ')" }

    $deadline = (Get-Date).AddSeconds($TestTimeoutSec + 5)
    while ((Get-Date) -lt $deadline) {
        $pending = 0
        foreach ($r in $runs) { Update-TestClock $r; if (-not (Test-Finished $r)) { $pending++ } }
        if ($pending -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }

    $anyFail = $false
    foreach ($r in $runs) {
        $o = Get-TestOutcome $r
        $tag = @{ ok = ' OK ' ; warn = 'WARN'; fail = 'FAIL' }[$o.Level]
        $color = @{ ok = 'Green'; warn = 'Yellow'; fail = 'Red' }[$o.Level]
        $time = if ($null -ne $o.Ms) { " ($($o.Ms) ms)" } else { '' }
        Write-Host ("[{0}] {1}{2}: {3}" -f $tag, $r.Name, $time, $o.Text) -ForegroundColor $color
        if ($o.Level -eq 'fail') { $anyFail = $true }
        Stop-ProfileTest $r
    }
    if ($anyFail) { exit 1 }
    return
}

if ($Usage) {
    $cfg = Get-Config
    $checks = @()
    foreach ($p in $cfg['profiles']) { if ($Usage -eq 'all' -or $Usage -eq $p['id']) { $checks += , (Start-UsageCheck $p) } }
    if ($checks.Count -eq 0) { throw "Unknown profile '$Usage'. Use 'all' or one of: $((@($cfg['profiles'] | ForEach-Object { $_['id'] })) -join ', ')" }

    $deadline = (Get-Date).AddSeconds($TestTimeoutSec * 2 + 10)
    while ((Get-Date) -lt $deadline) {
        $pending = 0
        foreach ($c in $checks) { if (-not (Step-UsageCheck $c)) { $pending++ } }
        if ($pending -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }

    foreach ($c in $checks) {
        $tag = @{ ok = ' OK '; warn = 'WARN'; fail = 'FAIL' }[$c.Level]
        $color = @{ ok = 'Green'; warn = 'Yellow'; fail = 'Red' }[$c.Level]
        Write-Host ("[{0}] {1}: {2}" -f $tag, $c.Name, $c.Summary) -ForegroundColor $color
        foreach ($l in $c.Lines) { Write-Host "       $l" }
        Stop-UsageCheck $c
    }
    return
}

# ---------- tray app ----------

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class NativeIcon { [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h); }
"@
[System.Windows.Forms.Application]::EnableVisualStyles()
# Must run before any control exists on this thread.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$script:appIcon = $null
$appIconPath = Join-Path $PSScriptRoot 'claude-switcher.ico'
if (Test-Path $appIconPath) {
    try { $script:appIcon = New-Object System.Drawing.Icon($appIconPath) } catch { }
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeSwitcherTray', [ref]$createdNew)
if (-not $createdNew) {
    # Already running: ask that copy to bring its window up, then quit.
    try { [void][System.Threading.EventWaitHandle]::OpenExisting('Local\ClaudeSwitcherShow').Set() } catch { }
    return
}
$script:showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\ClaudeSwitcherShow')
$script:exiting = $false

function New-DotBitmap([string]$Hex, [int]$Size, [string]$Letter = '') {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Hex))
    $g.FillEllipse($brush, 1, 1, ($Size - 2), ($Size - 2))
    if ($Letter) {
        $font = New-Object System.Drawing.Font('Segoe UI', [single]($Size * 0.5), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString($Letter, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, $Size, $Size), $sf)
        $font.Dispose()
    }
    $brush.Dispose(); $g.Dispose()
    $bmp
}

function New-DotIcon([string]$Hex, [string]$Letter) {
    $bmp = New-DotBitmap $Hex 32 $Letter
    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
    [NativeIcon]::DestroyIcon($h) | Out-Null
    $bmp.Dispose()
    $icon
}

$script:cfg = Get-Config
Sync-ProcessManagedEnv $script:cfg
$script:staleApps = @()
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:notify.ContextMenuStrip = $script:menu

function Show-Balloon([string]$Title, [string]$Text, [string]$Kind = 'Info') {
    $script:notify.ShowBalloonTip(4000, $Title, $Text, $Kind)
}

function Update-Tray {
    $active = Get-ActiveId $script:cfg
    $ap = if ($active) { Find-Profile $script:cfg $active } else { $null }

    $old = $script:notify.Icon
    if ($ap) {
        $script:notify.Icon = New-DotIcon $ap['color'] ([string]$ap['id'].Substring(0, 1).ToUpper())
        $script:notify.Text = "Claude source: $($ap['name'])"
    } else {
        $script:notify.Icon = New-DotIcon '#6E6E6E' '?'
        $script:notify.Text = 'Claude source: custom / unknown'
    }
    if ($old) { $old.Dispose() }
    $script:notify.Visible = $true

    $script:menu.Items.Clear()
    $title = if ($ap) { "Active: $($ap['name'])" } else { 'Active: custom / unknown' }
    $hdr = $script:menu.Items.Add($title); $hdr.Enabled = $false
    $openWin = $script:menu.Items.Add('Open Claude Switcher'); $openWin.Font = New-Object System.Drawing.Font($openWin.Font, [System.Drawing.FontStyle]::Bold)
    $openWin.Add_Click({ Show-MainWindow })
    [void]$script:menu.Items.Add('-')
    foreach ($p in $script:cfg['profiles']) {
        $label = $p['name']
        if (-not (Test-Configured $p)) { $label += '  (set up...)' }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($label)
        $item.Checked = ($p['id'] -eq $active)
        $item.Tag = $p['id']
        $item.Image = New-DotBitmap $p['color'] 16
        $item.Add_Click({ param($s, $e) Switch-To ([string]$s.Tag) })
        [void]$script:menu.Items.Add($item)
    }
    [void]$script:menu.Items.Add('-')
    $test = $script:menu.Items.Add('Test connections...'); $test.Add_Click({ Show-TestWindow })
    $usage = $script:menu.Items.Add('Check usage...'); $usage.Add_Click({ Show-UsageWindow })
    $upd = $script:menu.Items.Add('Check for updates...'); $upd.Add_Click({ Show-ModelUpdateWindow })
    $edit = $script:menu.Items.Add('Edit profiles...'); $edit.Add_Click({ Show-Editor })
    $open = $script:menu.Items.Add('Open settings.json'); $open.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$SettingsPath`"" })
    $bk = $script:menu.Items.Add('Open backups folder'); $bk.Add_Click({
            if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
            Start-Process explorer.exe -ArgumentList "`"$BackupDir`""
        })
    [void]$script:menu.Items.Add('-')
    $quit = $script:menu.Items.Add('Exit'); $quit.Add_Click({
            $script:exiting = $true
            $script:notify.Visible = $false
            $script:notify.Dispose()
            if ($script:mainForm -and -not $script:mainForm.IsDisposed) { $script:mainForm.Close() }
            [System.Windows.Forms.Application]::Exit()
        })

    # Keep the window (if open) in step with config changes and switches.
    $script:staleApps = Get-StaleApps $script:cfg
    if (Get-Command Update-MainCards -ErrorAction SilentlyContinue) { Update-MainCards }
}

function Switch-To([string]$Id) {
    $p = Find-Profile $script:cfg $Id
    if (-not (Test-Configured $p)) {
        Show-Balloon 'Profile not set up' "Fill in the values for $($p['name']) first." 'Warning'
        Show-Editor $Id
        return
    }
    try {
        Set-ActiveProfile $script:cfg $Id
        Update-Tray
        $staleText = Get-StaleAppsText $script:staleApps
        if ($staleText) { Show-Balloon "Switched to $($p['name'])" $staleText 'Warning' }
        else { Show-Balloon "Switched to $($p['name'])" 'Restart running Claude Code sessions for it to take effect.' }
        Set-MainNote "Switched to $($p['name']). Restart running Claude Code sessions for it to take effect."
    } catch {
        Show-Balloon 'Switch failed' $_.Exception.Message 'Error'
    }
}

# ---------- profile editor ----------

function ConvertTo-EnvText($Env) {
    ($Env.Keys | ForEach-Object { "$_=$($Env[$_])" }) -join "`r`n"
}

function ConvertFrom-EnvText([string]$Text) {
    $env = [ordered]@{}
    foreach ($line in ($Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $i = $l.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $l.Substring(0, $i).Trim()
        $v = $l.Substring($i + 1).Trim()
        if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $env[$k] = $v
    }
    $env
}

function Show-Editor([string]$SelectId = '') {
    $script:edCfg = Get-Config     # edit a fresh copy; Save writes it back
    $script:edIndex = -1

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Claude Switcher - Profiles'
    if ($script:appIcon) { $f.Icon = $script:appIcon }
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(640, 452)
    $f.MinimumSize = New-Object System.Drawing.Size(560, 412)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = '12,12'; $list.Size = '170,306'; $list.Anchor = 'Top,Bottom,Left'
    $f.Controls.Add($list)

    $btnAdd = New-Object System.Windows.Forms.Button; $btnAdd.Text = 'Add profile'
    $btnAdd.Location = '12,326'; $btnAdd.Size = '82,28'; $btnAdd.Anchor = 'Bottom,Left'
    $btnRemove = New-Object System.Windows.Forms.Button; $btnRemove.Text = 'Remove'
    $btnRemove.Location = '100,326'; $btnRemove.Size = '82,28'; $btnRemove.Anchor = 'Bottom,Left'
    $btnUp = New-Object System.Windows.Forms.Button; $btnUp.Text = 'Move up'
    $btnUp.Location = '12,358'; $btnUp.Size = '82,28'; $btnUp.Anchor = 'Bottom,Left'
    $btnDown = New-Object System.Windows.Forms.Button; $btnDown.Text = 'Move down'
    $btnDown.Location = '100,358'; $btnDown.Size = '82,28'; $btnDown.Anchor = 'Bottom,Left'
    $f.Controls.Add($btnAdd); $f.Controls.Add($btnRemove); $f.Controls.Add($btnUp); $f.Controls.Add($btnDown)

    $lblName = New-Object System.Windows.Forms.Label; $lblName.Text = 'Name'
    $lblName.Location = '196,12'; $lblName.Size = '430,16'; $lblName.AutoSize = $false; $lblName.Anchor = 'Top,Left,Right'
    $txtName = New-Object System.Windows.Forms.TextBox; $txtName.Location = '196,30'; $txtName.Size = '430,23'; $txtName.Anchor = 'Top,Left,Right'
    $lblModel = New-Object System.Windows.Forms.Label; $lblModel.Text = 'Model (optional, e.g. sonnet or a gateway model name)'
    $lblModel.Location = '196,62'; $lblModel.Size = '430,32'; $lblModel.AutoSize = $false; $lblModel.Anchor = 'Top,Left,Right'
    $txtModel = New-Object System.Windows.Forms.TextBox; $txtModel.Location = '196,96'; $txtModel.Size = '430,23'; $txtModel.Anchor = 'Top,Left,Right'
    $lblEnv = New-Object System.Windows.Forms.Label; $lblEnv.Text = 'Environment variables (KEY=VALUE, one per line; leave empty for your normal Claude login)'
    $lblEnv.Location = '196,128'; $lblEnv.Size = '430,32'; $lblEnv.AutoSize = $false; $lblEnv.Anchor = 'Top,Left,Right'
    $txtEnv = New-Object System.Windows.Forms.TextBox
    $txtEnv.Multiline = $true; $txtEnv.ScrollBars = 'Vertical'; $txtEnv.AcceptsReturn = $true; $txtEnv.WordWrap = $false
    $txtEnv.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $txtEnv.Location = '196,162'; $txtEnv.Size = '430,190'; $txtEnv.Anchor = 'Top,Bottom,Left,Right'
    foreach ($c in $lblName, $txtName, $lblModel, $txtModel, $lblEnv, $txtEnv) { $f.Controls.Add($c) }

    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = 'Save'; $btnSave.Location = '446,404'; $btnSave.Size = '85,30'; $btnSave.Anchor = 'Bottom,Right'
    $btnClose = New-Object System.Windows.Forms.Button; $btnClose.Text = 'Close'; $btnClose.Location = '541,404'; $btnClose.Size = '85,30'; $btnClose.Anchor = 'Bottom,Right'
    $btnClose.DialogResult = 'Cancel'
    $f.Controls.Add($btnSave); $f.Controls.Add($btnClose); $f.CancelButton = $btnClose

    $script:edFields = @{ List = $list; Name = $txtName; Model = $txtModel; Env = $txtEnv }

    $commit = {
        $i = $script:edIndex
        if ($i -lt 0) { return }
        $p = $script:edCfg['profiles'][$i]
        $p['name'] = $script:edFields.Name.Text.Trim()
        $p['model'] = $script:edFields.Model.Text.Trim()
        $p['env'] = ConvertFrom-EnvText $script:edFields.Env.Text
    }
    $script:edCommit = $commit

    foreach ($p in $script:edCfg['profiles']) { [void]$list.Items.Add($p['name']) }
    # Assigning ListBox.Items[i] re-fires SelectedIndexChanged (twice), so every touch of the
    # list or the selection from our own code goes through $script:edBusy to avoid recursion.
    $script:edBusy = $false
    $script:edRefreshName = {
        param([int]$Index)
        $name = [string]$script:edCfg['profiles'][$Index]['name']
        if ($script:edFields.List.Items[$Index] -ne $name) {
            $keep = $script:edFields.List.SelectedIndex   # assigning the item can reset the selection
            $script:edBusy = $true
            try { $script:edFields.List.Items[$Index] = $name; $script:edFields.List.SelectedIndex = $keep }
            finally { $script:edBusy = $false }
        }
    }
    $list.Add_SelectedIndexChanged({
            if ($script:edBusy) { return }
            $prev = $script:edIndex
            $i = $script:edFields.List.SelectedIndex
            if ($prev -ge 0) {
                & $script:edCommit
                & $script:edRefreshName $prev
            }
            $script:edIndex = $i
            if ($i -lt 0) { return }
            $p = $script:edCfg['profiles'][$i]
            $script:edFields.Name.Text = [string]$p['name']
            $script:edFields.Model.Text = [string]$p['model']
            $script:edFields.Env.Text = ConvertTo-EnvText $p['env']
        })

    $btnAdd.Add_Click({
            $n = 1
            while (Find-Profile $script:edCfg "profile-$n") { $n++ }
            $newP = [ordered]@{ id = "profile-$n"; name = "New profile $n"; color = '#6E6E6E'; model = ''; env = [ordered]@{} }
            $script:edCfg['profiles'] = @($script:edCfg['profiles']) + , $newP
            [void]$script:edFields.List.Items.Add($newP['name'])
            $script:edFields.List.SelectedIndex = $script:edFields.List.Items.Count - 1
            $script:edFields.Name.Focus(); $script:edFields.Name.SelectAll()
        })

    $btnRemove.Add_Click({
            $i = $script:edFields.List.SelectedIndex
            if ($i -lt 0) { return }
            if ($script:edCfg['profiles'].Count -le 1) {
                [void][System.Windows.Forms.MessageBox]::Show('At least one profile must remain.', 'Claude Switcher')
                return
            }
            $p = $script:edCfg['profiles'][$i]
            $msg = "Remove '$($p['name'])'?"
            if ($p['id'] -eq (Get-ActiveId $script:edCfg)) { $msg += "`n`nThis is currently the active source." }
            if ([System.Windows.Forms.MessageBox]::Show($msg, 'Claude Switcher', 'YesNo', 'Warning') -ne 'Yes') { return }

            $script:edIndex = -1     # skip the pending-commit path below - the removed profile is gone
            $script:edCfg['profiles'] = @($script:edCfg['profiles'] | Where-Object { $_ -ne $p })
            $script:edBusy = $true
            try { $script:edFields.List.Items.RemoveAt($i) } finally { $script:edBusy = $false }

            $newSel = [Math]::Min($i, $script:edFields.List.Items.Count - 1)
            if ($newSel -ge 0) { $script:edFields.List.SelectedIndex = $newSel }
        })

    # $script:-scoped (not a local $swap) and no .GetNewClosure() on the buttons below - a
    # GetNewClosure() scriptblock attached via Add_Click silently never fires when the click
    # is dispatched through this dialog's own ShowDialog() message loop.
    $script:edSwap = {
        param([int]$i, [int]$j)
        & $script:edCommit
        $arr = @($script:edCfg['profiles'])
        $tmp = $arr[$i]; $arr[$i] = $arr[$j]; $arr[$j] = $tmp
        $script:edCfg['profiles'] = $arr
        $script:edBusy = $true
        try {
            $script:edFields.List.Items.RemoveAt($i)
            $script:edFields.List.Items.Insert($j, [string]$arr[$j]['name'])
            $script:edFields.List.SelectedIndex = $j
        } finally { $script:edBusy = $false }
        $script:edIndex = $j
    }

    $btnUp.Add_Click({
            $i = $script:edFields.List.SelectedIndex
            if ($i -le 0) { return }
            & $script:edSwap $i ($i - 1)
        })

    $btnDown.Add_Click({
            $i = $script:edFields.List.SelectedIndex
            if ($i -lt 0 -or $i -ge $script:edCfg['profiles'].Count - 1) { return }
            & $script:edSwap $i ($i + 1)
        })

    $btnSave.Add_Click({
            & $script:edCommit
            Write-JsonFile $ProfilesPath $script:edCfg
            $script:cfg = $script:edCfg
            $editedId = if ($script:edIndex -ge 0) { $script:edCfg['profiles'][$script:edIndex]['id'] } else { $null }
            $wasActive = (Get-ActiveId $script:cfg) -eq $editedId
            try {
                # If the edited profile is the active one, push the new values into settings.json.
                if ($editedId -and $wasActive -and (Test-Configured (Find-Profile $script:cfg $editedId))) { Set-ActiveProfile $script:cfg $editedId }
            } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Claude Switcher') }
            Update-Tray
            if ($script:edIndex -ge 0) { & $script:edRefreshName $script:edIndex }
            Show-Balloon 'Saved' 'Profiles updated.'
        })

    $sel = 0
    if ($SelectId) { for ($n = 0; $n -lt $script:edCfg['profiles'].Count; $n++) { if ($script:edCfg['profiles'][$n]['id'] -eq $SelectId) { $sel = $n } } }
    $list.SelectedIndex = $sel

    [void]$f.ShowDialog()
    $f.Dispose()
}

# ---------- connection test window ----------

function Show-TestWindow {
    if ($script:testForm -and -not $script:testForm.IsDisposed) { $script:testForm.Activate(); return }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Claude Switcher - Connection test'
    if ($script:appIcon) { $f.Icon = $script:appIcon }
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(820, 420)
    $f.MinimumSize = New-Object System.Drawing.Size(600, 360)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.GridLines = $true; $lv.ShowItemToolTips = $true; $lv.HideSelection = $false
    $lv.Location = '12,12'; $lv.Size = '796,200'; $lv.Anchor = 'Top,Left,Right'
    [void]$lv.Columns.Add('Source', 140)
    [void]$lv.Columns.Add('Status', 60)
    [void]$lv.Columns.Add('Time', 70)
    [void]$lv.Columns.Add('Detail (select a row to read it in full below)', 510)
    $f.Controls.Add($lv)

    $lblFull = New-Object System.Windows.Forms.Label
    $lblFull.Text = 'Full detail for the selected row'; $lblFull.Location = '12,220'; $lblFull.AutoSize = $true
    $f.Controls.Add($lblFull)

    $txtFull = New-Object System.Windows.Forms.TextBox
    $txtFull.Multiline = $true; $txtFull.ReadOnly = $true; $txtFull.WordWrap = $true; $txtFull.ScrollBars = 'Vertical'
    $txtFull.BackColor = [System.Drawing.SystemColors]::Window
    $txtFull.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $txtFull.Location = '12,238'; $txtFull.Size = '796,96'; $txtFull.Anchor = 'Top,Bottom,Left,Right'
    $f.Controls.Add($txtFull)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Gateway sources get a 1-token test message. Personal checks reachability and that a login exists.'
    $hint.Location = '12,342'; $hint.Size = '358,32'; $hint.AutoSize = $false
    $hint.Anchor = 'Bottom,Left'; $hint.ForeColor = [System.Drawing.Color]::DimGray
    $f.Controls.Add($hint)

    $btnRun = New-Object System.Windows.Forms.Button; $btnRun.Text = 'Test all'; $btnRun.Size = '85,28'; $btnRun.Location = '632,380'; $btnRun.Anchor = 'Bottom,Right'
    $btnClose = New-Object System.Windows.Forms.Button; $btnClose.Text = 'Close'; $btnClose.Size = '85,28'; $btnClose.Location = '723,380'; $btnClose.Anchor = 'Bottom,Right'
    $btnClose.DialogResult = 'Cancel'
    $btnClose.Add_Click({ $f.Close() }.GetNewClosure())
    $btnFix = New-Object System.Windows.Forms.Button; $btnFix.Text = 'Troubleshoot...'; $btnFix.Size = '115,28'; $btnFix.Location = '509,380'; $btnFix.Anchor = 'Bottom,Right'
    $btnUse = New-Object System.Windows.Forms.Button; $btnUse.Text = 'Check usage...'; $btnUse.Size = '115,28'; $btnUse.Location = '384,380'; $btnUse.Anchor = 'Bottom,Right'
    $btnUse.Add_Click({ Show-UsageWindow })
    $f.Controls.Add($btnUse); $f.Controls.Add($btnFix); $f.Controls.Add($btnRun); $f.Controls.Add($btnClose); $f.CancelButton = $btnClose

    $script:testForm = $f
    $script:testList = $lv
    $script:testBtn = $btnRun
    $script:testFull = $txtFull
    $script:testRuns = @()

    $lv.Add_SelectedIndexChanged({
            if ($script:testList.SelectedItems.Count -eq 0) { return }
            $item = $script:testList.SelectedItems[0]
            $script:testFull.Text = "$($item.SubItems[1].Text)  $($item.SubItems[2].Text)`r`n`r`n$($item.Tag)"
        })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $script:testTimer = $timer

    $timer.Add_Tick({
            $pending = 0
            foreach ($r in $script:testRuns) {
                Update-TestClock $r
                if (Test-Finished $r) {
                    if (-not $r.Shown) {
                        $r.Shown = $true
                        $o = Get-TestOutcome $r
                        $item = $r.Item
                        $item.SubItems[1].Text = @{ ok = 'OK'; warn = 'WARN'; fail = 'FAIL' }[$o.Level]
                        $item.SubItems[2].Text = if ($null -ne $o.Ms) { "$($o.Ms) ms" } else { '' }
                        $item.SubItems[3].Text = $o.Text
                        $item.ToolTipText = $o.Text
                        $item.Tag = $o.Text
                        # Refresh the detail pane if this is the row being read.
                        if ($item.Selected) { $script:testFull.Text = "$($item.SubItems[1].Text)  $($item.SubItems[2].Text)`r`n`r`n$($o.Text)" }
                        $item.ForeColor = @{ ok = [System.Drawing.Color]::DarkGreen; warn = [System.Drawing.Color]::DarkOrange; fail = [System.Drawing.Color]::Firebrick }[$o.Level]
                    }
                } else { $pending++ }
            }
            if ($pending -eq 0) {
                $script:testTimer.Stop(); $script:testBtn.Enabled = $true; $script:testBtn.Text = 'Test all'
                # Land on the first problem row so its full error is already showing.
                if ($script:testList.SelectedItems.Count -eq 0 -and $script:testList.Items.Count -gt 0) {
                    $pick = $script:testList.Items[0]
                    foreach ($it in $script:testList.Items) { if ($it.SubItems[1].Text -in 'FAIL', 'WARN') { $pick = $it; break } }
                    $pick.Selected = $true
                }
            }
        })

    $start = {
        foreach ($r in $script:testRuns) { Stop-ProfileTest $r }
        $script:testRuns = @()
        $script:testList.Items.Clear()
        $cfg = Get-Config
        $active = Get-ActiveId $cfg
        foreach ($p in $cfg['profiles']) {
            $label = $p['name']; if ($p['id'] -eq $active) { $label += ' (active)' }
            $item = New-Object System.Windows.Forms.ListViewItem($label)
            $item.Name = [string]$p['id']
            [void]$item.SubItems.Add('...'); [void]$item.SubItems.Add(''); [void]$item.SubItems.Add('testing...')
            [void]$script:testList.Items.Add($item)
            $run = Start-ProfileTest $p
            $run.Item = $item
            $script:testRuns += , $run
        }
        $script:testBtn.Enabled = $false; $script:testBtn.Text = 'Testing...'
        $script:testTimer.Start()
    }
    $script:testStart = $start
    $btnRun.Add_Click({ & $script:testStart })
    $btnFix.Add_Click({
            if ($script:testList.SelectedItems.Count -eq 0) {
                [void][System.Windows.Forms.MessageBox]::Show('Select a source in the list first.', 'Claude Switcher')
                return
            }
            $applied = Show-Troubleshooter ([string]$script:testList.SelectedItems[0].Name)
            if ($applied) { & $script:testStart }   # a fix was written: re-test everything
        })
    $f.Add_FormClosed({
            $script:testTimer.Stop(); $script:testTimer.Dispose()
            foreach ($r in $script:testRuns) { Stop-ProfileTest $r }
        })

    $f.Show()
    & $start
}

# ---------- troubleshooter ----------
# Diagnoses a gateway source that fails its test and proposes a config fix, all without Claude:
#   phase 1: baseline + model list + alternate auth header + base URL without /v1, all at once
#   phase 2: (model problems) try every model the gateway lists or names in its error message

# Credentials were accepted; any remaining failure is about something else (e.g. the model).
function Test-AuthAccepted($R) {
    $R.Kind -eq 'http' -and $R.Code -lt 500 -and $R.Code -ne 401 -and $R.Code -ne 404 -and ($R.Code -ne 403 -or (Test-ModelError $R.Detail))
}

# Version numbers in a model name ("claude-sonnet-4-6" -> 4,6), ignoring date stamps like 20251001.
function Get-ModelVersion([string]$Name) {
    $nums = @([regex]::Matches($Name, '\d+') | ForEach-Object { [int64]$_.Value } | Where-Object { $_ -lt 1000 })
    $nums
}

# -1/0/1 as A's version is older/same/newer than B's, comparing each numeric component in turn.
function Compare-ModelVersion([string]$A, [string]$B) {
    $va = @(Get-ModelVersion $A); $vb = @(Get-ModelVersion $B)
    for ($i = 0; $i -lt [Math]::Max($va.Count, $vb.Count); $i++) {
        $x = if ($i -lt $va.Count) { $va[$i] } else { -1 }
        $y = if ($i -lt $vb.Count) { $vb[$i] } else { -1 }
        if ($x -ne $y) { return [Math]::Sign($x - $y) }
    }
    0
}

# First model matching the earliest pattern; among several matches the newest version wins.
function Get-PreferredModel($List, [string[]]$Patterns, [string]$Fallback) {
    foreach ($pat in $Patterns) {
        $best = $null
        foreach ($m in $List) {
            if ($m -notmatch $pat) { continue }
            if ($null -eq $best -or (Compare-ModelVersion $m $best) -gt 0) { $best = $m }
        }
        if ($best) { return $best }
    }
    $Fallback
}

# Model ids from a /v1/models-style JSON reply: either {"data": [...]} or a bare array, of
# strings or {"id": ...} objects.
function Get-ModelListIds($R) {
    $found = New-Object System.Collections.Generic.List[string]
    if ($R -and $R.Kind -eq 'http' -and $R.Code -ge 200 -and $R.Code -lt 300 -and $R.Json) {
        $items = @()
        if ($R.Json.data) { $items = @($R.Json.data) } elseif ($R.Json -is [System.Array]) { $items = @($R.Json) }
        foreach ($m in $items) {
            $id = if ($m -is [string]) { $m } else { [string]$m.id }
            if ($id -and -not $found.Contains($id)) { $found.Add($id) }
        }
    }
    , $found
}

# Which of Claude Code's model-alias families a model name belongs to, or $null for a custom name.
function Get-ModelFamily([string]$Name) {
    foreach ($pat in '(?i)opus', '(?i)sonnet', '(?i)haiku') { if ($Name -match $pat) { return $pat } }
    $null
}

# Model names to try: whatever the gateway lists, plus any names quoted in its error text
# (e.g. "can only access models=['global-models']"), Claude-looking names first.
function Get-ModelCandidates($Models, $Base, [string]$Tried) {
    $found = New-Object System.Collections.Generic.List[string]
    $found.AddRange((Get-ModelListIds $Models))
    foreach ($src in @($Base.Detail, $(if ($Models) { $Models.Detail }))) {
        foreach ($m in [regex]::Matches([string]$src, '(?i)models?\s*=\s*\[([^\]]*)\]')) {
            foreach ($q in [regex]::Matches($m.Groups[1].Value, '[''"]([^''"]+)[''"]')) {
                $id = $q.Groups[1].Value
                if (-not $found.Contains($id)) { $found.Add($id) }
            }
        }
    }
    [void]$found.Remove($Tried)
    $pref = @($found | Where-Object { $_ -match '(?i)claude|sonnet|haiku|opus' })
    $rest = @($found | Where-Object { $_ -notmatch '(?i)claude|sonnet|haiku|opus' })
    # Claude Code needs Claude models: only fall back to other names when the gateway has none.
    if ($pref.Count -gt 0) { return @($pref | Select-Object -First 12) }
    @($rest | Select-Object -First 12)
}

# Env vars that make Claude Code's model aliases (sonnet/opus/haiku) resolve to names this gateway has.
function Get-ModelEnvDefaults($Working, [string]$Fast) {
    $e = [ordered]@{}
    $s = Get-PreferredModel @($Working) @('(?i)sonnet') ''
    $o = Get-PreferredModel @($Working) @('(?i)opus') ''
    if ($s) { $e['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $s }
    if ($o) { $e['ANTHROPIC_DEFAULT_OPUS_MODEL'] = $o }
    if ($Fast) { $e['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = $Fast }
    $e
}

function Add-TsLog([string]$Text) { $script:tsUi.Log.AppendText($Text + "`r`n") }

function Stop-TsProbes {
    foreach ($pr in @($script:tsProbes)) { if ($pr.Client) { $pr.Client.Dispose() } }
    $script:tsProbes = @()
}

function Set-TsBusy([bool]$Busy) {
    $u = $script:tsUi
    $u.Run.Enabled = -not $Busy; $u.Try.Enabled = -not $Busy; $u.Man.Enabled = -not $Busy
    $u.Apply.Enabled = (-not $Busy) -and ($null -ne $script:tsFix)
}

function Set-TsFix($Fix) {
    $script:tsFix = $Fix
    $u = $script:tsUi
    if (-not $Fix) { $u.Group.Visible = $false; $u.Apply.Enabled = $false; return }
    $u.Group.Visible = $true
    $u.FixText.Text = $Fix.Text
    $isModel = ($Fix.Kind -eq 'model')
    foreach ($c in $u.LblMain, $u.Main, $u.LblFast, $u.Fast) { $c.Visible = $isModel }
    if ($isModel) {
        $u.Main.Items.Clear(); $u.Fast.Items.Clear()
        foreach ($m in $Fix.Working) { [void]$u.Main.Items.Add($m); [void]$u.Fast.Items.Add($m) }
        $u.Main.Text = $Fix.Main; $u.Fast.Text = $Fix.Fast
    }
    $u.Apply.Enabled = $true
}

function Set-TsModelFix($Working, [string]$Main = '') {
    $w = @($Working)
    if (-not $Main) { $Main = Get-PreferredModel $w @('(?i)sonnet', '(?i)opus') $w[0] }
    $fast = Get-PreferredModel $w @('(?i)haiku') $Main
    Set-TsFix @{
        Kind = 'model'; Working = $w; Main = $Main; Fast = $fast
        Text = "Pick the models to use for this source. Main is what you chat with. Fast is what Claude Code uses for background tasks (saved as ANTHROPIC_DEFAULT_HAIKU_MODEL). Only models that passed the test are listed, but you can type another name."
    }
}

function Start-TsPhase1 {
    Set-TsBusy $true
    Stop-TsProbes
    $cfg = Get-Config
    $p = Find-Profile $cfg $script:tsProfileId
    $script:tsProf = $p
    $penv = $p['env']
    $probes = New-Object System.Collections.ArrayList
    [void]$probes.Add((New-GatewayProbe $p @{ Key = 'base'; Desc = 'current settings' }))
    [void]$probes.Add((New-GatewayProbe $p @{ Key = 'models'; Desc = 'model list'; Method = 'GET'; Path = '/v1/models' }))
    $hasTok = [string]$penv['ANTHROPIC_AUTH_TOKEN'] -ne ''
    $hasKey = [string]$penv['ANTHROPIC_API_KEY'] -ne ''
    if ($hasTok -and -not $hasKey) { [void]$probes.Add((New-GatewayProbe $p @{ Key = 'auth'; Auth = 'apikey' })) }
    elseif ($hasKey -and -not $hasTok) { [void]$probes.Add((New-GatewayProbe $p @{ Key = 'auth'; Auth = 'bearer' })) }
    $base = ([string]$penv['ANTHROPIC_BASE_URL']).Trim().TrimEnd('/')
    if ($base -match '/v1$') { [void]$probes.Add((New-GatewayProbe $p @{ Key = 'url'; Base = $base.Substring(0, $base.Length - 3) })) }
    $script:tsProbes = $probes
    $script:tsPhase = 'p1'
    Add-TsLog "Testing $($p['name']) ($($base)) ..."
    $script:tsUi.Timer.Start()
}

function Complete-TsPhase1 {
    $res = @{}
    foreach ($pr in $script:tsProbes) { $r = Get-ProbeResult $pr.Task; $r.Ms = [int]$pr.Sw.ElapsedMilliseconds; $res[$pr.Key] = $r }
    $b = $res['base']; $models = $res['models']; $auth = $res['auth']; $url = $res['url']
    Add-TsLog ('  1. your current settings              -> ' + (Get-ShortDetail $b))
    Add-TsLog ('  2. ask the gateway for its model list -> ' + (Get-ShortDetail $models))
    if ($auth) { Add-TsLog ('  3. same, other auth header style      -> ' + (Get-ShortDetail $auth)) }
    if ($url) { Add-TsLog ('  4. same, base URL without /v1         -> ' + (Get-ShortDetail $url)) }
    Add-TsLog ''

    if (Test-Live $b) {
        Add-TsLog 'RESULT: nothing to fix - this source is live.'
        Set-TsBusy $false; return
    }
    if ($b.Kind -eq 'net') {
        Add-TsLog 'RESULT: could not reach the gateway at all, so there is nothing to fix in the config yet. Check:'
        Add-TsLog '  - you are on the right network / VPN for this gateway'
        Add-TsLog '  - the base URL is spelled correctly (http vs https, host, port)'
        Add-TsLog '  - your proxy or firewall allows the host (try the URL in a browser)'
        Set-TsBusy $false; return
    }

    $penv = $script:tsProf['env']
    $authFail = ($b.Code -eq 401) -or ($b.Code -eq 403 -and -not (Test-ModelError $b.Detail))
    if ($authFail -and $auth -and (Test-AuthAccepted $auth)) {
        if ([string]$penv['ANTHROPIC_AUTH_TOKEN']) { $from = 'ANTHROPIC_AUTH_TOKEN'; $to = 'ANTHROPIC_API_KEY'; $how = 'x-api-key header' }
        else { $from = 'ANTHROPIC_API_KEY'; $to = 'ANTHROPIC_AUTH_TOKEN'; $how = 'Authorization: Bearer header' }
        Add-TsLog "RESULT: the gateway rejects your credential as currently sent, but accepts it as an $how."
        Set-TsFix @{ Kind = 'auth'; From = $from; To = $to; Text = "Rename $from to $to in this profile (the value stays the same) so Claude Code sends it as an $how." }
        Set-TsBusy $false; return
    }
    if ($b.Code -eq 404 -and $url -and $url.Kind -eq 'http' -and $url.Code -ne 404) {
        $newBase = ([string]$penv['ANTHROPIC_BASE_URL']).Trim().TrimEnd('/') -replace '/v1$', ''
        Add-TsLog 'RESULT: the endpoint is found once the trailing /v1 is removed from the base URL.'
        Set-TsFix @{ Kind = 'url'; NewBase = $newBase; Text = "Change ANTHROPIC_BASE_URL to $newBase (remove the trailing /v1)." }
        Set-TsBusy $false; return
    }

    $modelsOk = $models -and $models.Kind -eq 'http' -and $models.Code -ge 200 -and $models.Code -lt 300
    if ((Test-ModelError $b.Detail) -or $b.Code -eq 400 -or ($b.Code -eq 404 -and $modelsOk)) {
        $tried = Get-TestModel $script:tsProf
        Add-TsLog "RESULT: the gateway does not accept the model '$tried' (from this profile's Model setting, or the app's default when none is set)."
        $cands = @(Get-ModelCandidates $models $b $tried)
        if ($cands.Count -eq 0) {
            Add-TsLog 'The gateway did not list any models and its error names none. Ask the RISE/ICA admins which model names your key can use, then type one below and press "Try model".'
            Set-TsBusy $false; return
        }
        Start-TsPhase2 $cands
        return
    }

    if ($authFail) {
        Add-TsLog "RESULT: the gateway rejected the credentials (HTTP $($b.Code)) and the other header style did not help. The token/key is most likely wrong, expired or revoked: get a fresh one and paste it into Edit profiles."
    } elseif ($b.Code -eq 404) {
        Add-TsLog 'RESULT: endpoint not found (404) and no variant of the URL worked. Double-check ANTHROPIC_BASE_URL with the RISE/ICA docs.'
    } elseif ($b.Code -ge 200 -and $b.Code -lt 300) {
        Add-TsLog 'RESULT: the reply is not a Claude API message - the URL probably points at a proxy, a login page or the wrong service.'
    } else {
        Add-TsLog "RESULT: unexpected reply (HTTP $($b.Code)). If it is a 5xx error the gateway itself is having trouble; try again later."
    }
    Set-TsBusy $false
}

function Start-TsPhase2($Cands) {
    Add-TsLog ("Trying {0} model name(s) the gateway lists or mentions:" -f $Cands.Count)
    Stop-TsProbes
    $probes = New-Object System.Collections.ArrayList
    foreach ($m in $Cands) { [void]$probes.Add((New-GatewayProbe $script:tsProf @{ Key = 'cand'; Model = $m })) }
    $script:tsProbes = $probes
    $script:tsPhase = 'p2'
    $script:tsUi.Timer.Start()
}

function Complete-TsPhase2 {
    $working = New-Object System.Collections.Generic.List[string]
    foreach ($pr in $script:tsProbes) {
        $r = Get-ProbeResult $pr.Task
        if ((Test-Live $r) -or ($r.Kind -eq 'http' -and $r.Code -eq 429)) {
            $working.Add($pr.Model); Add-TsLog ('  OK        ' + $pr.Model)
        } else {
            Add-TsLog ('  rejected  ' + $pr.Model + '   (' + (Get-ShortDetail $r) + ')')
        }
    }
    Add-TsLog ''
    if ($working.Count -gt 0) {
        Add-TsLog "RESULT: $($working.Count) model name(s) work for this source. Choose below and press Apply fix."
        Set-TsModelFix $working
    } else {
        Add-TsLog 'RESULT: none of those models worked. Ask the RISE/ICA admins which model names your key can use, then type one below and press "Try model".'
    }
    Set-TsBusy $false
}

function Start-TsManual([string]$Name) {
    $Name = $Name.Trim()
    if (-not $Name) { return }
    Set-TsBusy $true
    Stop-TsProbes
    Add-TsLog "Trying model '$Name' ..."
    $script:tsProbes = @(New-GatewayProbe $script:tsProf @{ Key = 'manual'; Model = $Name })
    $script:tsPhase = 'manual'
    $script:tsUi.Timer.Start()
}

function Complete-TsManual {
    $pr = $script:tsProbes[0]
    $r = Get-ProbeResult $pr.Task
    if ((Test-Live $r) -or ($r.Kind -eq 'http' -and $r.Code -eq 429)) {
        Add-TsLog ("  OK        " + $pr.Model + "  - added to the fix below.`r`n")
        $w = @()
        if ($script:tsFix -and $script:tsFix.Kind -eq 'model') { $w += @($script:tsFix.Working) }
        if ($w -notcontains $pr.Model) { $w += $pr.Model }
        Set-TsModelFix $w $pr.Model
    } else {
        Add-TsLog ('  rejected  ' + $pr.Model + '   (' + (Get-ShortDetail $r) + ")`r`n")
    }
    Set-TsBusy $false
}

function Invoke-TsFix {
    $fix = $script:tsFix
    if (-not $fix) { return }
    $id = $script:tsProfileId
    $wasActive = (Get-ActiveId (Get-Config)) -eq $id     # judge before we change the profile
    $cfg = Get-Config
    $p = Find-Profile $cfg $id
    switch ($fix.Kind) {
        'auth' {
            $v = [string]$p['env'][$fix.From]
            $p['env'].Remove($fix.From)
            $p['env'][$fix.To] = $v
            $what = "renamed $($fix.From) to $($fix.To)"
        }
        'url' {
            $p['env']['ANTHROPIC_BASE_URL'] = $fix.NewBase
            $what = "set ANTHROPIC_BASE_URL to $($fix.NewBase)"
        }
        'model' {
            $main = $script:tsUi.Main.Text.Trim()
            $fast = $script:tsUi.Fast.Text.Trim()
            if (-not $main) { [void][System.Windows.Forms.MessageBox]::Show('Choose a main model first.', 'Claude Switcher'); return }
            $p['model'] = $main
            $defaults = Get-ModelEnvDefaults @($fix.Working) $fast
            foreach ($k in $defaults.Keys) { $p['env'][$k] = $defaults[$k] }
            $what = "set Model to '$main'" + $(if ($defaults.Count) { ' and ' + (($defaults.Keys | ForEach-Object { "$_ to '$($defaults[$_])'" }) -join ', ') } else { '' })
        }
    }
    Write-JsonFile $ProfilesPath $cfg
    $script:cfg = $cfg
    if ($wasActive) { Set-ActiveProfile $cfg $id }
    Update-Tray
    $script:tsApplied = $true
    Add-TsLog ''
    Add-TsLog "APPLIED: $what."
    if ($wasActive) { Add-TsLog 'This source is active, so settings.json is updated too. Restart running Claude Code sessions to pick it up.' }
    else { Add-TsLog 'Saved to the profile. Switch to this source from the tray menu to use it.' }
    Add-TsLog ''
    Set-TsFix $null
    Start-TsPhase1        # confirm the fix worked
}

# Returns $true if a fix was applied (so the caller can refresh its view).
function Show-Troubleshooter([string]$Id) {
    $cfg = Get-Config
    $p = Find-Profile $cfg $Id
    if (-not $p) { return $false }
    if (Test-PersonalProfile $p) {
        [void][System.Windows.Forms.MessageBox]::Show('Personal profiles use your claude.ai login, so there are no gateway settings to fix here. If it fails, open a terminal, run "claude" and use /login.', 'Claude Switcher')
        return $false
    }
    if (-not (Test-Configured $p)) {
        [void][System.Windows.Forms.MessageBox]::Show("$($p['name']) still has blank values. Fill them in with Edit profiles first.", 'Claude Switcher')
        return $false
    }

    $script:tsProfileId = $Id; $script:tsApplied = $false; $script:tsFix = $null; $script:tsProbes = @(); $script:tsProf = $p
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Troubleshoot - $($p['name'])"
    if ($script:appIcon) { $f.Icon = $script:appIcon }
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.ClientSize = New-Object System.Drawing.Size(720, 490)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'The app tests your settings against the gateway, works out what is wrong and offers a fix - no Claude needed.'
    $title.Location = '12,10'; $title.AutoSize = $true
    $f.Controls.Add($title)

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.WordWrap = $true; $log.ScrollBars = 'Vertical'
    $log.BackColor = [System.Drawing.SystemColors]::Window; $log.Font = New-Object System.Drawing.Font('Consolas', 9)
    $log.Location = '12,34'; $log.Size = '696,210'
    $f.Controls.Add($log)

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Suggested fix'; $grp.Location = '12,252'; $grp.Size = '696,136'; $grp.Visible = $false
    $fixText = New-Object System.Windows.Forms.Label; $fixText.Location = '12,20'; $fixText.Size = '672,44'
    $lblMain = New-Object System.Windows.Forms.Label; $lblMain.Text = 'Main model'; $lblMain.Location = '12,76'; $lblMain.AutoSize = $true
    $cmbMain = New-Object System.Windows.Forms.ComboBox; $cmbMain.Location = '210,72'; $cmbMain.Size = '470,24'
    $lblFast = New-Object System.Windows.Forms.Label; $lblFast.Text = 'Fast model (background tasks)'; $lblFast.Location = '12,106'; $lblFast.AutoSize = $true
    $cmbFast = New-Object System.Windows.Forms.ComboBox; $cmbFast.Location = '210,102'; $cmbFast.Size = '470,24'
    foreach ($c in $fixText, $lblMain, $cmbMain, $lblFast, $cmbFast) { $grp.Controls.Add($c) }
    $f.Controls.Add($grp)

    $lblMan = New-Object System.Windows.Forms.Label; $lblMan.Text = 'Or try a model name yourself:'; $lblMan.Location = '12,402'; $lblMan.AutoSize = $true
    $txtMan = New-Object System.Windows.Forms.TextBox; $txtMan.Location = '210,398'; $txtMan.Size = '370,24'
    $btnTry = New-Object System.Windows.Forms.Button; $btnTry.Text = 'Try model'; $btnTry.Location = '590,396'; $btnTry.Size = '118,28'
    foreach ($c in $lblMan, $txtMan, $btnTry) { $f.Controls.Add($c) }

    $btnApply = New-Object System.Windows.Forms.Button; $btnApply.Text = 'Apply fix'; $btnApply.Location = '12,444'; $btnApply.Size = '110,32'; $btnApply.Enabled = $false
    $btnRun = New-Object System.Windows.Forms.Button; $btnRun.Text = 'Run again'; $btnRun.Location = '130,444'; $btnRun.Size = '100,32'
    $btnClose = New-Object System.Windows.Forms.Button; $btnClose.Text = 'Close'; $btnClose.Location = '608,444'; $btnClose.Size = '100,32'; $btnClose.DialogResult = 'Cancel'
    foreach ($c in $btnApply, $btnRun, $btnClose) { $f.Controls.Add($c) }
    $f.CancelButton = $btnClose

    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 150
    $script:tsUi = @{
        Log = $log; Group = $grp; FixText = $fixText; LblMain = $lblMain; Main = $cmbMain; LblFast = $lblFast; Fast = $cmbFast
        Man = $txtMan; Try = $btnTry; Apply = $btnApply; Run = $btnRun; Timer = $timer
    }

    $timer.Add_Tick({
            $pending = 0
            foreach ($pr in $script:tsProbes) {
                if ($pr.Task.IsCompleted) { if ($pr.Sw.IsRunning) { $pr.Sw.Stop() } } else { $pending++ }
            }
            if ($pending -gt 0) { return }
            $script:tsUi.Timer.Stop()
            switch ($script:tsPhase) {
                'p1' { Complete-TsPhase1 }
                'p2' { Complete-TsPhase2 }
                'manual' { Complete-TsManual }
            }
        })
    $btnApply.Add_Click({ Invoke-TsFix })
    $btnRun.Add_Click({ $script:tsUi.Log.Clear(); Set-TsFix $null; Start-TsPhase1 })
    $btnTry.Add_Click({ Start-TsManual $script:tsUi.Man.Text })
    $f.Add_Shown({ Start-TsPhase1 })

    [void]$f.ShowDialog()
    $timer.Stop(); $timer.Dispose()
    Stop-TsProbes
    $f.Dispose()
    return [bool]$script:tsApplied
}

# ---------- model update check ----------
# For each profile, asks that source for its model list (the gateway's /v1/models, or Anthropic's
# for Personal using the same login token as the usage check) and offers to update any pinned model
# - the main model/ANTHROPIC_MODEL pin, plus each of ANTHROPIC_DEFAULT_SONNET/OPUS/HAIKU_MODEL that's
# set - if a newer version of the same family is listed. A profile can produce several rows, one per
# pin, all sharing a single model-list fetch. Read-only until you press Update; the candidate is not
# test-called first, so re-run Test connections after.

function New-PersonalModelListProbe([string]$ConfigDirOverride = '') {
    $tok = ''
    try { $tok = [string]((Read-JsonFile (Get-CredentialsPath $ConfigDirOverride))['claudeAiOauth']['accessToken']) } catch { }
    if (-not $tok) { return $null }
    $client = New-TestClient
    $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList 'GET'), 'https://api.anthropic.com/v1/models?limit=1000'
    [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $tok")
    [void]$req.Headers.TryAddWithoutValidation('anthropic-version', '2023-06-01')
    [void]$req.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
    [void]$req.Headers.TryAddWithoutValidation('User-Agent', 'claude-switcher/1.0')
    $tok = $null
    [ordered]@{ Client = $client; Task = $client.SendAsync($req); Sw = [System.Diagnostics.Stopwatch]::StartNew() }
}

# Every model this profile pins, and where each one lives: the main model/ANTHROPIC_MODEL pin
# (whichever is set, 'model' taking priority), plus each per-alias ANTHROPIC_DEFAULT_*_MODEL that's
# set. A profile can have several of these at once (e.g. a gateway profile pinning its own Opus and
# Haiku defaults alongside a main Sonnet pin).
function Get-PinnedModels($Prof) {
    $pins = New-Object System.Collections.Generic.List[object]
    if ([string]$Prof['model']) { $pins.Add(@{ Value = [string]$Prof['model']; Field = 'model' }) }
    elseif ([string]$Prof['env']['ANTHROPIC_MODEL']) { $pins.Add(@{ Value = [string]$Prof['env']['ANTHROPIC_MODEL']; Field = 'env:ANTHROPIC_MODEL' }) }
    foreach ($k in 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL') {
        if ([string]$Prof['env'][$k]) { $pins.Add(@{ Value = [string]$Prof['env'][$k]; Field = "env:$k" }) }
    }
    , $pins
}

function Set-PinnedModel($Prof, [string]$Field, [string]$Value) {
    if ($Field -eq 'model') { $Prof['model'] = $Value } else { $Prof['env'][($Field -replace '^env:', '')] = $Value }
}

function New-ModelCheckBase($Prof) {
    [ordered]@{
        Id = $Prof['id']; Name = $Prof['name']; Done = $false; Level = 'ok'; Text = ''
        Current = ''; Latest = ''; Field = ''; Probe = $null; Item = $null; Shown = $false
    }
}

# Starts every check for this profile without blocking (one row per pin, sharing one model-list
# probe); poll Step-ModelCheck on each until it returns $true.
function Start-ModelChecks($Prof) {
    if (-not (Test-Configured $Prof)) {
        $c = New-ModelCheckBase $Prof
        $c.Level = 'warn'; $c.Text = 'Not configured - fill in the blank values first.'; $c.Done = $true
        return @($c)
    }
    $pins = @(Get-PinnedModels $Prof)
    if ($pins.Count -eq 0) {
        $c = New-ModelCheckBase $Prof
        $c.Text = "No model pinned - $(if (Test-PersonalProfile $Prof) { 'Claude Code' } else { 'this profile' }) always uses the latest default."
        $c.Done = $true
        return @($c)
    }
    if (Test-PersonalProfile $Prof) {
        $probe = New-PersonalModelListProbe ([string]$Prof['env']['CLAUDE_CONFIG_DIR'])
        if (-not $probe) {
            $c = New-ModelCheckBase $Prof
            $c.Level = 'fail'; $c.Text = 'No login found. Run "claude" and use /login.'; $c.Done = $true
            return @($c)
        }
    } else {
        $probe = New-GatewayProbe $Prof @{ Key = 'models'; Method = 'GET'; Path = '/v1/models' }
    }
    @($pins | ForEach-Object {
            $c = New-ModelCheckBase $Prof
            $c.Current = $_.Value; $c.Field = $_.Field; $c.Probe = $probe
            $c
        })
}

function Step-ModelCheck($C) {
    if ($C.Done) { return $true }
    if (-not $C.Probe.Task.IsCompleted) { return $false }
    $r = Get-ProbeResult $C.Probe.Task
    if ($r.Kind -eq 'net' -or $r.Code -lt 200 -or $r.Code -ge 300) {
        $C.Level = 'warn'; $C.Text = "Could not list models ($(Get-ShortDetail $r))."; $C.Done = $true; return $true
    }
    $ids = @(Get-ModelListIds $r)
    if ($ids.Count -eq 0) { $C.Level = 'warn'; $C.Text = 'No models were listed.'; $C.Done = $true; return $true }
    $fam = Get-ModelFamily $C.Current
    if (-not $fam) {
        $C.Text = "Custom model name - can't auto-detect a newer version ($($ids.Count) model(s) listed)."; $C.Done = $true; return $true
    }
    $best = Get-PreferredModel $ids @($fam) $C.Current
    if ($best -eq $C.Current -or (Compare-ModelVersion $best $C.Current) -le 0) {
        $C.Text = "Up to date ($($C.Current))."
    } else {
        $C.Level = 'update'; $C.Latest = $best; $C.Text = "Update available: $($C.Current)  ->  $best"
    }
    $C.Done = $true
    $true
}

function Stop-ModelCheck($C) { if ($C.Probe -and $C.Probe.Client) { $C.Probe.Client.Dispose() } }

# ---------- usage window ----------

function Show-UsageWindow {
    if ($script:usageForm -and -not $script:usageForm.IsDisposed) { $script:usageForm.Activate(); return }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Claude Switcher - Usage'
    if ($script:appIcon) { $f.Icon = $script:appIcon }
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(820, 400)
    $f.MinimumSize = New-Object System.Drawing.Size(600, 340)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.GridLines = $true; $lv.HideSelection = $false; $lv.ShowItemToolTips = $true
    $lv.Location = '12,12'; $lv.Size = '796,140'; $lv.Anchor = 'Top,Left,Right'
    [void]$lv.Columns.Add('Source', 150)
    [void]$lv.Columns.Add('Status', 60)
    [void]$lv.Columns.Add('Usage', 570)
    $f.Controls.Add($lv)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Details for the selected source'; $lbl.Location = '12,160'; $lbl.AutoSize = $true
    $f.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true; $txt.ReadOnly = $true; $txt.WordWrap = $true; $txt.ScrollBars = 'Vertical'
    $txt.BackColor = [System.Drawing.SystemColors]::Window; $txt.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $txt.Location = '12,178'; $txt.Size = '796,140'; $txt.Anchor = 'Top,Bottom,Left,Right'
    $f.Controls.Add($txt)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Personal reads your plan limits from Anthropic (login token stays in memory). Gateways report the key''s spend and budgets.'
    $hint.Location = '12,324'; $hint.Size = '600,32'; $hint.AutoSize = $false
    $hint.Anchor = 'Bottom,Left'; $hint.ForeColor = [System.Drawing.Color]::DimGray
    $f.Controls.Add($hint)

    $btnRefresh = New-Object System.Windows.Forms.Button; $btnRefresh.Text = 'Refresh'; $btnRefresh.Size = '85,28'; $btnRefresh.Location = '632,360'; $btnRefresh.Anchor = 'Bottom,Right'
    $btnClose = New-Object System.Windows.Forms.Button; $btnClose.Text = 'Close'; $btnClose.Size = '85,28'; $btnClose.Location = '723,360'; $btnClose.Anchor = 'Bottom,Right'
    $btnClose.DialogResult = 'Cancel'
    $btnClose.Add_Click({ $f.Close() }.GetNewClosure())
    $f.Controls.Add($btnRefresh); $f.Controls.Add($btnClose); $f.CancelButton = $btnClose

    $script:usageForm = $f; $script:usageList = $lv; $script:usageText = $txt; $script:usageBtn = $btnRefresh
    $script:usageRuns = @()

    $lv.Add_SelectedIndexChanged({
            if ($script:usageList.SelectedItems.Count -eq 0) { return }
            $script:usageText.Text = [string]$script:usageList.SelectedItems[0].Tag
        })

    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 200
    $script:usageTimer = $timer
    $timer.Add_Tick({
            $pending = 0
            foreach ($u in $script:usageRuns) {
                if (Step-UsageCheck $u) {
                    if (-not $u.Shown) {
                        $u.Shown = $true
                        $item = $u.Item
                        $item.SubItems[1].Text = @{ ok = 'OK'; warn = 'WARN'; fail = 'FAIL' }[$u.Level]
                        $item.SubItems[2].Text = $u.Summary
                        $item.ToolTipText = $u.Summary
                        $item.Tag = ($u.Lines -join "`r`n`r`n")
                        $item.ForeColor = @{ ok = [System.Drawing.Color]::DarkGreen; warn = [System.Drawing.Color]::DarkOrange; fail = [System.Drawing.Color]::Firebrick }[$u.Level]
                        if ($item.Selected) { $script:usageText.Text = [string]$item.Tag }
                    }
                } else { $pending++ }
            }
            if ($pending -eq 0) {
                $script:usageTimer.Stop(); $script:usageBtn.Enabled = $true; $script:usageBtn.Text = 'Refresh'
                if ($script:usageList.SelectedItems.Count -eq 0 -and $script:usageList.Items.Count -gt 0) { $script:usageList.Items[0].Selected = $true }
            }
        })

    $start = {
        foreach ($u in $script:usageRuns) { Stop-UsageCheck $u }
        $script:usageRuns = @()
        $script:usageList.Items.Clear()
        $script:usageText.Text = ''
        $cfg = Get-Config
        $active = Get-ActiveId $cfg
        foreach ($p in $cfg['profiles']) {
            $label = $p['name']; if ($p['id'] -eq $active) { $label += ' (active)' }
            $item = New-Object System.Windows.Forms.ListViewItem($label)
            [void]$item.SubItems.Add('...'); [void]$item.SubItems.Add('checking...')
            [void]$script:usageList.Items.Add($item)
            $u = Start-UsageCheck $p
            $u.Item = $item
            $script:usageRuns += , $u
        }
        $script:usageBtn.Enabled = $false; $script:usageBtn.Text = 'Checking...'
        $script:usageTimer.Start()
    }
    $script:usageStart = $start
    $btnRefresh.Add_Click({ & $script:usageStart })
    $f.Add_FormClosed({
            $script:usageTimer.Stop(); $script:usageTimer.Dispose()
            foreach ($u in $script:usageRuns) { Stop-UsageCheck $u }
        })

    $f.Show()
    & $start
}

# ---------- model update window ----------

function Show-ModelUpdateWindow {
    if ($script:updForm -and -not $script:updForm.IsDisposed) { $script:updForm.Activate(); return }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Claude Switcher - Check for model updates'
    if ($script:appIcon) { $f.Icon = $script:appIcon }
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(820, 420)
    $f.MinimumSize = New-Object System.Drawing.Size(600, 340)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.GridLines = $true; $lv.HideSelection = $false; $lv.ShowItemToolTips = $true
    $lv.Location = '12,12'; $lv.Size = '796,180'; $lv.Anchor = 'Top,Left,Right'
    [void]$lv.Columns.Add('Source', 150)
    [void]$lv.Columns.Add('Field', 90)
    [void]$lv.Columns.Add('Status', 540)
    $f.Controls.Add($lv)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Details for the selected source'; $lbl.Location = '12,198'; $lbl.AutoSize = $true
    $f.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true; $txt.ReadOnly = $true; $txt.WordWrap = $true; $txt.ScrollBars = 'Vertical'
    $txt.BackColor = [System.Drawing.SystemColors]::Window; $txt.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $txt.Location = '12,216'; $txt.Size = '796,102'; $txt.Anchor = 'Top,Bottom,Left,Right'
    $f.Controls.Add($txt)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "Reads each source's model list and compares it to the model pinned in its profile. This only reads the list - it does not test the new model, so re-run Test connections afterwards."
    $hint.Location = '12,324'; $hint.Size = '796,32'; $hint.AutoSize = $false
    $hint.Anchor = 'Bottom,Left,Right'; $hint.ForeColor = [System.Drawing.Color]::DimGray
    $f.Controls.Add($hint)

    $btnUpdate = New-Object System.Windows.Forms.Button; $btnUpdate.Text = 'Update'; $btnUpdate.Size = '90,28'; $btnUpdate.Location = '521,380'; $btnUpdate.Anchor = 'Bottom,Right'; $btnUpdate.Enabled = $false
    $btnRefresh = New-Object System.Windows.Forms.Button; $btnRefresh.Text = 'Check again'; $btnRefresh.Size = '100,28'; $btnRefresh.Location = '617,380'; $btnRefresh.Anchor = 'Bottom,Right'
    $btnClose = New-Object System.Windows.Forms.Button; $btnClose.Text = 'Close'; $btnClose.Size = '85,28'; $btnClose.Location = '723,380'; $btnClose.Anchor = 'Bottom,Right'
    $btnClose.DialogResult = 'Cancel'
    $btnClose.Add_Click({ $f.Close() }.GetNewClosure())
    $f.Controls.Add($btnUpdate); $f.Controls.Add($btnRefresh); $f.Controls.Add($btnClose); $f.CancelButton = $btnClose

    $script:updForm = $f; $script:updList = $lv; $script:updText = $txt; $script:updBtn = $btnRefresh; $script:updApply = $btnUpdate
    $script:updRuns = @()

    $lv.Add_SelectedIndexChanged({
            if ($script:updList.SelectedItems.Count -eq 0) { $script:updApply.Enabled = $false; return }
            $item = $script:updList.SelectedItems[0]
            $script:updText.Text = [string]$item.Tag
            $c = @($script:updRuns | Where-Object { $_.Item -eq $item })[0]
            $script:updApply.Enabled = [bool]($c -and $c.Level -eq 'update')
        })

    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 200
    $script:updTimer = $timer
    $timer.Add_Tick({
            $pending = 0
            foreach ($c in $script:updRuns) {
                if (Step-ModelCheck $c) {
                    if (-not $c.Shown) {
                        $c.Shown = $true
                        $item = $c.Item
                        $item.SubItems[1].Text = $(if ($c.Field -eq 'model') { 'Model' } elseif ($c.Field) { $c.Field -replace '^env:', '' } else { '' })
                        $item.SubItems[2].Text = $c.Text
                        $item.ToolTipText = $c.Text
                        $item.Tag = $c.Text
                        $item.ForeColor = @{ ok = [System.Drawing.Color]::DarkGreen; warn = [System.Drawing.Color]::DarkOrange; fail = [System.Drawing.Color]::Firebrick; update = [System.Drawing.Color]::MediumBlue }[$c.Level]
                        if ($item.Selected) { $script:updText.Text = [string]$item.Tag; $script:updApply.Enabled = ($c.Level -eq 'update') }
                    }
                } else { $pending++ }
            }
            if ($pending -eq 0) {
                $script:updTimer.Stop(); $script:updBtn.Enabled = $true; $script:updBtn.Text = 'Check again'
                if ($script:updList.SelectedItems.Count -eq 0 -and $script:updList.Items.Count -gt 0) { $script:updList.Items[0].Selected = $true }
            }
        })

    $start = {
        foreach ($c in $script:updRuns) { Stop-ModelCheck $c }
        $script:updRuns = @()
        $script:updList.Items.Clear()
        $script:updText.Text = ''
        $script:updApply.Enabled = $false
        $cfg = Get-Config
        $active = Get-ActiveId $cfg
        foreach ($p in $cfg['profiles']) {
            $label = $p['name']; if ($p['id'] -eq $active) { $label += ' (active)' }
            foreach ($c in @(Start-ModelChecks $p)) {
                $item = New-Object System.Windows.Forms.ListViewItem($label)
                [void]$item.SubItems.Add(''); [void]$item.SubItems.Add('checking...')
                [void]$script:updList.Items.Add($item)
                $c.Item = $item
                $script:updRuns += , $c
            }
        }
        $script:updBtn.Enabled = $false; $script:updBtn.Text = 'Checking...'
        $script:updTimer.Start()
    }
    $script:updStart = $start
    $btnRefresh.Add_Click({ & $script:updStart })
    $btnUpdate.Add_Click({
            if ($script:updList.SelectedItems.Count -eq 0) { return }
            $item = $script:updList.SelectedItems[0]
            $c = @($script:updRuns | Where-Object { $_.Item -eq $item })[0]
            if (-not $c -or $c.Level -ne 'update') { return }
            $cfg = Get-Config
            $p = Find-Profile $cfg $c.Id
            if (-not $p) { return }
            Set-PinnedModel $p $c.Field $c.Latest
            Write-JsonFile $ProfilesPath $cfg
            $script:cfg = $cfg
            $wasActive = (Get-ActiveId $cfg) -eq $c.Id
            try { if ($wasActive) { Set-ActiveProfile $cfg $c.Id } } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Claude Switcher') }
            Update-Tray
            Show-Balloon 'Model updated' "$($p['name']): $($c.Current) -> $($c.Latest)$(if ($wasActive) { ' (settings.json updated - restart Claude Code sessions)' } else { '' })"
            & $script:updStart
        })
    $f.Add_FormClosed({
            $script:updTimer.Stop(); $script:updTimer.Dispose()
            foreach ($c in $script:updRuns) { Stop-ModelCheck $c }
        })

    $f.Show()
    & $start
}

# ---------- main window ----------
# The dashboard that opens on a left-click of the tray icon: one card per source with its live
# status and usage, and buttons to switch, fix or edit it. Closing it only hides it.

$script:mainState = @{}        # profile id -> @{ Test = outcome; Usage = usage check }, $null while checking
$script:mainCards = @{}        # profile id -> the card's controls
$script:mainRuns = @()
$script:mainLastRefresh = [datetime]::MinValue
$MainAutoRefreshSec = 120
$CardHeight = 128
$FootHeight = 76
$WarnHeight = 52    # the stale-app banner under the header, when shown
$WinWidth = 614
$script:loginRefresh = $null   # @{ Id; Proc; Sw } while a "Refresh login" run is in flight, one at a time

# ---------- login refresh (Personal) ----------
# We never hold the refresh token or call Anthropic's OAuth endpoint ourselves - that's undocumented
# and only Claude Code should touch it. Instead we ask the Claude Code CLI, which already knows how
# to refresh its own token, to do one trivial no-op call. That rewrites .credentials.json for us.

function Start-LoginRefresh([string]$ConfigDirOverride = '') {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) { return @{ Failed = $true; Error = "Couldn't find the 'claude' command on PATH." } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/d /c claude -p "hi" >NUL 2>&1'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Force the right CLAUDE_CONFIG_DIR for this profile rather than relying on this process's
    # own (possibly stale) environment - the tray app may have started before a later switch.
    if ($ConfigDirOverride) { $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $ConfigDirOverride }
    elseif ($psi.EnvironmentVariables.ContainsKey('CLAUDE_CONFIG_DIR')) { $psi.EnvironmentVariables.Remove('CLAUDE_CONFIG_DIR') }
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ Failed = $true; Error = $_.Exception.Message }
    }
    @{ Failed = $false; Proc = $proc; Sw = [System.Diagnostics.Stopwatch]::StartNew() }
}

# Opens a real, visible console already running `claude` so the user can type /login and finish
# the OAuth sign-in in their browser. We can't do this silently in the background like the refresh
# above - a first-time login needs an interactive console, not just a no-op API call.
#
# Uses ShellExecute (not a raw CreateProcess) because this app is a pure GUI process with no
# console of its own: on Windows 11, with Windows Terminal set as the default terminal app, a
# console spawned via CreateProcess from a console-less GUI process can silently fail the
# terminal-handoff and never show a window, even though Process.Start() itself reports success.
# ShellExecute goes through the same path Explorer uses to open a .exe and doesn't hit that bug.
# The tradeoff: EnvironmentVariables is ignored when UseShellExecute is true, so
# CLAUDE_CONFIG_DIR has to be set (or cleared) via the command line instead.
function Start-Login([string]$ConfigDirOverride = '') {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) { return @{ Failed = $true; Error = "Couldn't find the 'claude' command on PATH." } }
    $setEnv = if ($ConfigDirOverride) { "set `"CLAUDE_CONFIG_DIR=$ConfigDirOverride`" && " } else { 'set CLAUDE_CONFIG_DIR=&& ' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/k ${setEnv}claude"
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    try {
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ Failed = $true; Error = $_.Exception.Message }
    }
    @{ Failed = $false }
}

# Polls one refresh run; returns $true once it's done (finished, timed out, or failed to start).
function Step-LoginRefresh($R) {
    if ($R.Failed) { return $true }
    if ($R.Proc.HasExited) { return $true }
    if ($R.Sw.Elapsed.TotalSeconds -gt 45) { try { $R.Proc.Kill() } catch { }; return $true }
    $false
}

function Get-LevelColor([string]$Level) {
    $hex = switch ($Level) { 'ok' { '#107C10' } 'warn' { '#B25000' } 'fail' { '#C42B1C' } default { '#6E6E6E' } }
    [System.Drawing.ColorTranslator]::FromHtml($hex)
}

function Get-HostLabel($Prof) {
    if (Test-PersonalProfile $Prof) {
        if ([string]$Prof['env']['CLAUDE_CONFIG_DIR']) { return 'Your claude.ai login (separate account)' }
        return 'Your claude.ai login'
    }
    $u = [string]$Prof['env']['ANTHROPIC_BASE_URL']
    if (-not $u) { return 'Base URL not set' }
    try { ([uri]$u).Host } catch { $u }
}

function Set-MainNote([string]$Text) {
    if ($script:mainNote -and -not $script:mainNote.IsDisposed) { $script:mainNote.Text = $Text }
}

function Set-CardState([string]$Id) {
    $c = $script:mainCards[$Id]
    if (-not $c) { return }
    $p = Find-Profile $script:cfg $Id
    if (-not $p) { return }
    $st = $script:mainState[$Id]
    $dot = [string][char]0x25CF
    $isGateway = -not (Test-PersonalProfile $p)

    # connection status
    if (-not $st -or $null -eq $st.Test) {
        $c.Status.Text = "$dot Checking..."; $c.Status.ForeColor = Get-LevelColor ''
        $script:mainTip.SetToolTip($c.Status, '')
        $c.Fix.Enabled = $false
        $script:mainTip.SetToolTip($c.Fix, 'Checking...')
    } else {
        $o = $st.Test
        $notSet = ($o.Text -like 'Not configured*')
        $text = if ($notSet) { "$dot Not set up - press Edit and fill in the values" }
                elseif ($o.Level -eq 'ok') { if ($isGateway) { "$dot Live" + $(if ($null -ne $o.Ms) { " - $($o.Ms) ms" } else { '' }) } else { "$dot Ready - login found" } }
                elseif ($o.Level -eq 'warn') { "$dot Needs attention - $($o.Text)" }
                else { "$dot Not working - $($o.Text)" }
        $c.Status.Text = $text
        $c.Status.ForeColor = Get-LevelColor $(if ($notSet) { 'warn' } else { $o.Level })
        $script:mainTip.SetToolTip($c.Status, $o.Text)
        # Fix is only useful when the source is set up but not working; otherwise it stays greyed out.
        $c.Fix.Enabled = ($isGateway -and -not $notSet -and $o.Level -ne 'ok')
        $script:mainTip.SetToolTip($c.Fix, $(if ($notSet) { 'Not set up yet - use Edit to fill in the values' } elseif ($o.Level -eq 'ok') { 'Connection is working - nothing to fix' } else { 'Diagnose this source and fix its settings' }))
    }

    # usage
    if (-not $st -or $null -eq $st.Usage) {
        $c.Usage.Text = 'Usage: checking...'; $c.Usage.ForeColor = Get-LevelColor ''
        $script:mainTip.SetToolTip($c.Usage, '')
    } else {
        $u = $st.Usage
        $c.Usage.Text = 'Usage: ' + $u.Summary
        $c.Usage.ForeColor = if ($u.Level -eq 'ok') { Get-LevelColor '' } else { Get-LevelColor $u.Level }
        $script:mainTip.SetToolTip($c.Usage, ($u.Lines -join "`n"))
    }

    # login refresh (Personal only) - lets a rejected/expired token be fixed without leaving the app
    if ($c.Login) {
        if ($script:loginRefresh -and $script:loginRefresh.Id -eq $Id) {
            $c.Login.Enabled = $false; $c.Login.Text = 'Refreshing...'
            $script:mainTip.SetToolTip($c.Login, 'Asking the Claude Code CLI to refresh the login token...')
        } else {
            $u = if ($st) { $st.Usage } else { $null }
            $noLogin = ($u -and $u.Summary -eq 'No login found')
            $needsIt = ($u -and $u.Level -eq 'fail')
            $c.Login.Text = if ($noLogin) { 'Log in...' } else { 'Refresh login' }
            $c.Login.Enabled = (-not $isGateway -and $needsIt)
            $script:mainTip.SetToolTip($c.Login, $(
                    if ($noLogin) { "Opens a terminal already running 'claude' - type /login there and finish sign-in in your browser." }
                    elseif (-not $isGateway -and $needsIt) { "Runs 'claude -p' in the background so Claude Code refreshes its saved token." }
                    elseif (-not $u) { 'Checking usage first...' }
                    else { 'Only needed when the login token has been rejected.' }))
        }
    }
}

function Update-MainCards {
    $f = $script:mainForm
    if (-not $f -or $f.IsDisposed) { return }
    $panel = $script:mainPanel
    $panel.SuspendLayout()
    foreach ($old in @($panel.Controls)) { $old.Dispose() }
    $panel.Controls.Clear()
    $script:mainCards = @{}

    $active = Get-ActiveId $script:cfg
    $ap = if ($active) { Find-Profile $script:cfg $active } else { $null }
    $script:mainSub.Text = if ($ap) { "Active source: $($ap['name'])" } else { 'Active source: custom / unknown settings' }

    $staleText = Get-StaleAppsText $script:staleApps
    $warnH = if ($staleText) { $WarnHeight } else { 0 }
    $script:mainWarn.Visible = [bool]$staleText
    $script:mainWarnText.Text = $staleText
    $script:mainTip.SetToolTip($script:mainWarnText, $(if ($staleText) {
                (@($script:staleApps | ForEach-Object { "$($_.Label) still has: $($_.Keys -join ', ')" }) -join "`n") +
                "`n`nWindows gives each app a copy of the environment variables when it starts, and a switch can't change that copy.`nReload Window isn't enough - every window has to close. Press Refresh here afterwards to re-check."
            } else { '' }))

    $cardWidth = $WinWidth - 28
    $y = 8
    foreach ($p in $script:cfg['profiles']) {
        $id = [string]$p['id']
        $color = [System.Drawing.ColorTranslator]::FromHtml([string]$p['color'])
        $isActive = ($id -eq $active)

        $card = New-Object System.Windows.Forms.Panel
        $card.Location = New-Object System.Drawing.Point(12, $y); $card.Size = New-Object System.Drawing.Size($cardWidth, $CardHeight)
        $card.BackColor = [System.Drawing.Color]::White; $card.Anchor = 'Top,Left,Right'

        $bar = New-Object System.Windows.Forms.Panel
        $bar.Dock = 'Left'; $bar.Width = 6; $bar.BackColor = $color
        $card.Controls.Add($bar)

        $name = New-Object System.Windows.Forms.Label
        $name.Text = [string]$p['name']; $name.Location = '20,10'; $name.AutoSize = $true
        $name.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        $card.Controls.Add($name)

        $badge = New-Object System.Windows.Forms.Label
        $badge.Text = 'ACTIVE'; $badge.AutoSize = $true; $badge.Location = "$($cardWidth - 72),13"; $badge.Anchor = 'Top,Right'
        $badge.Font = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)
        $badge.ForeColor = [System.Drawing.Color]::White; $badge.BackColor = $color; $badge.Padding = New-Object System.Windows.Forms.Padding(5, 2, 5, 2)
        $badge.Visible = $isActive
        $card.Controls.Add($badge)

        $host1 = New-Object System.Windows.Forms.Label
        $host1.Text = Get-HostLabel $p; $host1.Location = '20,34'; $host1.AutoSize = $true
        $host1.Font = New-Object System.Drawing.Font('Segoe UI', 8.5); $host1.ForeColor = [System.Drawing.Color]::Gray
        $card.Controls.Add($host1)

        $status = New-Object System.Windows.Forms.Label
        $status.Location = '20,54'; $status.Size = "$($cardWidth - 32),20"; $status.AutoEllipsis = $true; $status.Anchor = 'Top,Left,Right'
        $status.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $card.Controls.Add($status)

        $usage = New-Object System.Windows.Forms.Label
        $usage.Location = '20,74'; $usage.Size = "$($cardWidth - 32),18"; $usage.AutoEllipsis = $true; $usage.Anchor = 'Top,Left,Right'
        $usage.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
        $card.Controls.Add($usage)

        $btnSwitch = New-Object System.Windows.Forms.Button
        $btnSwitch.Location = '20,96'; $btnSwitch.Size = '124,26'; $btnSwitch.Tag = $id
        if ($isActive) { $btnSwitch.Text = 'Active'; $btnSwitch.Enabled = $false } else { $btnSwitch.Text = 'Switch to this' }
        $btnSwitch.Add_Click({ param($s, $e) Switch-To ([string]$s.Tag) })
        $card.Controls.Add($btnSwitch)

        $isPersonal = Test-PersonalProfile $p

        $btnFix = New-Object System.Windows.Forms.Button
        $btnFix.Text = 'Fix...'; $btnFix.Location = '152,96'; $btnFix.Size = '76,26'; $btnFix.Tag = $id
        $btnFix.Visible = -not $isPersonal             # Personal has no gateway settings to fix
        $btnFix.Enabled = $false                        # enabled by Set-CardState once a check shows a problem
        $btnFix.Add_Click({
                param($s, $e)
                if (Show-Troubleshooter ([string]$s.Tag)) { Start-MainRefresh }
            })
        $card.Controls.Add($btnFix)

        $btnLogin = New-Object System.Windows.Forms.Button
        $btnLogin.Text = 'Refresh login'; $btnLogin.Location = '152,96'; $btnLogin.Size = '100,26'; $btnLogin.Tag = $id
        $btnLogin.Visible = $isPersonal                 # only Personal has a login token to refresh
        $btnLogin.Enabled = $false                       # enabled by Set-CardState once usage shows it's rejected
        $btnLogin.Add_Click({ param($s, $e) Start-CardLoginRefresh ([string]$s.Tag) })
        $card.Controls.Add($btnLogin)

        $btnEdit = New-Object System.Windows.Forms.Button
        $btnEdit.Text = 'Edit...'; $btnEdit.Location = $(if ($isPersonal) { '260,96' } else { '236,96' }); $btnEdit.Size = '76,26'; $btnEdit.Tag = $id
        $btnEdit.Add_Click({ param($s, $e) Show-Editor ([string]$s.Tag) })
        $card.Controls.Add($btnEdit)

        $panel.Controls.Add($card)
        $script:mainCards[$id] = @{ Status = $status; Usage = $usage; Fix = $btnFix; Login = $btnLogin; Switch = $btnSwitch }
        $y += $CardHeight + 10
    }
    $panel.ResumeLayout()

    # size the window to fit every card - no scrolling or clipping
    $y -= 10   # drop the trailing inter-card gap left after the last card
    $want = 64 + $warnH + $y + 6 + $FootHeight
    $h = $want
    $f.ClientSize = New-Object System.Drawing.Size($WinWidth, $h)
    $script:mainHead.Size = New-Object System.Drawing.Size($WinWidth, 64)
    $script:mainWarn.Location = New-Object System.Drawing.Point(12, 64); $script:mainWarn.Size = New-Object System.Drawing.Size(($WinWidth - 24), ($WarnHeight - 8))
    $panel.Location = New-Object System.Drawing.Point(0, (64 + $warnH)); $panel.Size = New-Object System.Drawing.Size($WinWidth, ($h - 64 - $warnH - $FootHeight))
    $script:mainFoot.Location = New-Object System.Drawing.Point(0, ($h - $FootHeight)); $script:mainFoot.Size = New-Object System.Drawing.Size($WinWidth, $FootHeight)

    foreach ($p in $script:cfg['profiles']) { Set-CardState ([string]$p['id']) }
}

function Stop-MainRuns {
    foreach ($r in @($script:mainRuns)) { Stop-ProfileTest $r.T; Stop-UsageCheck $r.U }
    $script:mainRuns = @()
}

function Start-CardLoginRefresh([string]$Id) {
    $p = Find-Profile $script:cfg $Id
    $st = $script:mainState[$Id]
    if ($st -and $st.Usage -and $st.Usage.Summary -eq 'No login found') {
        $run = Start-Login ([string]$p['env']['CLAUDE_CONFIG_DIR'])
        if ($run.Failed) {
            [System.Windows.Forms.MessageBox]::Show($run.Error, 'Claude Switcher', 'OK', 'Warning') | Out-Null
        } else {
            Show-Balloon 'Log in' 'Opened a terminal - run /login there, then press Refresh on this window.'
        }
        return
    }

    if ($script:loginRefresh) { return }     # one refresh at a time
    $run = Start-LoginRefresh ([string]$p['env']['CLAUDE_CONFIG_DIR'])
    if ($run.Failed) {
        [System.Windows.Forms.MessageBox]::Show(
            "$($run.Error)`n`nOpen a terminal, run 'claude', and use /login - then press Refresh login again.",
            'Claude Switcher', 'OK', 'Warning') | Out-Null
        return
    }
    $script:loginRefresh = @{ Id = $Id; Run = $run }
    Set-CardState $Id
    $script:loginRefreshTimer.Start()
}

function Start-MainRefresh {
    if (-not $script:mainForm -or $script:mainForm.IsDisposed) { return }
    $script:mainTimer.Stop()
    Stop-MainRuns
    # re-check for stale editors too (e.g. after quitting and reopening VS Code); resizes the window if that changed
    $was = Get-StaleAppsText $script:staleApps
    $script:staleApps = Get-StaleApps $script:cfg
    if ((Get-StaleAppsText $script:staleApps) -ne $was) { Update-MainCards }
    $runs = @()
    foreach ($p in $script:cfg['profiles']) {
        $id = [string]$p['id']
        $script:mainState[$id] = @{ Test = $null; Usage = $null }
        $runs += , @{ Id = $id; T = (Start-ProfileTest $p); U = (Start-UsageCheck $p); TDone = $false; UDone = $false }
        Set-CardState $id
    }
    $script:mainRuns = $runs
    $script:mainRefresh.Enabled = $false; $script:mainRefresh.Text = 'Checking...'
    $script:mainLastRefresh = Get-Date
    $script:mainTimer.Start()
}

function New-MainWindow {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Claude Switcher'
    if ($script:appIcon) { $f.Icon = $script:appIcon }
    $f.FormBorderStyle = 'FixedSingle'; $f.MaximizeBox = $false
    $f.StartPosition = 'Manual'; $f.ShowInTaskbar = $true; $f.KeyPreview = $true
    $f.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F0F0F0')
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.ClientSize = New-Object System.Drawing.Size($WinWidth, 588)

    $head = New-Object System.Windows.Forms.Panel; $head.Location = '0,0'; $head.Size = "$WinWidth,64"; $head.Anchor = 'Top,Left,Right'
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Claude Switcher'; $title.Location = '16,8'; $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $sub = New-Object System.Windows.Forms.Label
    $sub.Location = '18,40'; $sub.AutoSize = $true; $sub.ForeColor = [System.Drawing.Color]::DimGray
    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = 'Refresh'; $refresh.Location = "$($WinWidth - 102),18"; $refresh.Size = '86,28'; $refresh.Anchor = 'Top,Right'
    foreach ($c in $title, $sub, $refresh) { $head.Controls.Add($c) }

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = '0,64'; $panel.Size = ('{0},{1}' -f $WinWidth, (588 - 64 - $FootHeight)); $panel.AutoScroll = $false; $panel.Anchor = 'Top,Bottom,Left,Right'

    $foot = New-Object System.Windows.Forms.Panel; $foot.Location = ('0,{0}' -f (588 - $FootHeight)); $foot.Size = ('{0},{1}' -f $WinWidth, $FootHeight); $foot.Anchor = 'Bottom,Left,Right'
    $note = New-Object System.Windows.Forms.Label
    $note.Text = 'Restart running Claude Code sessions after switching.'
    $note.Location = '16,8'; $note.Size = "$($WinWidth - 32),18"; $note.AutoEllipsis = $true; $note.ForeColor = [System.Drawing.Color]::DimGray
    $btnTest = New-Object System.Windows.Forms.Button; $btnTest.Text = 'Test connections...'; $btnTest.Location = '12,34'; $btnTest.Size = '120,30'
    $btnUsage = New-Object System.Windows.Forms.Button; $btnUsage.Text = 'Check usage...'; $btnUsage.Location = '140,34'; $btnUsage.Size = '102,30'
    $btnUpd = New-Object System.Windows.Forms.Button; $btnUpd.Text = 'Check for updates...'; $btnUpd.Location = '250,34'; $btnUpd.Size = '130,30'
    $btnEdit = New-Object System.Windows.Forms.Button; $btnEdit.Text = 'Edit profiles...'; $btnEdit.Location = '388,34'; $btnEdit.Size = '104,30'
    $btnFile = New-Object System.Windows.Forms.Button; $btnFile.Text = 'settings.json'; $btnFile.Location = '500,34'; $btnFile.Size = '102,30'
    foreach ($c in $note, $btnTest, $btnUsage, $btnUpd, $btnEdit, $btnFile) { $foot.Controls.Add($c) }

    # Shown by Update-MainCards when an editor is still running on an earlier source (Get-StaleApps).
    $warn = New-Object System.Windows.Forms.Panel; $warn.Visible = $false
    $warn.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFF4CE')
    $warnText = New-Object System.Windows.Forms.Label
    $warnText.Dock = 'Fill'; $warnText.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4); $warnText.TextAlign = 'MiddleLeft'
    $warnText.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#5C3B00')
    $warn.Controls.Add($warnText)

    $f.Controls.Add($panel); $f.Controls.Add($warn); $f.Controls.Add($head); $f.Controls.Add($foot)

    $script:mainForm = $f; $script:mainPanel = $panel; $script:mainHead = $head; $script:mainFoot = $foot
    $script:mainWarn = $warn; $script:mainWarnText = $warnText
    $script:mainSub = $sub; $script:mainNote = $note; $script:mainRefresh = $refresh
    $script:mainTip = New-Object System.Windows.Forms.ToolTip
    $script:mainTip.AutoPopDelay = 20000

    $refresh.Add_Click({ Start-MainRefresh })
    $btnTest.Add_Click({ Show-TestWindow })
    $btnUsage.Add_Click({ Show-UsageWindow })
    $btnUpd.Add_Click({ Show-ModelUpdateWindow })
    $btnEdit.Add_Click({ Show-Editor })
    $btnFile.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$SettingsPath`"" })

    # X and Esc hide the window; only Exit from the tray menu really closes it.
    $f.Add_FormClosing({ param($s, $e) if (-not $script:exiting) { $e.Cancel = $true; $s.Hide() } })
    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $s.Hide() } })

    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 200
    $script:mainTimer = $timer
    $timer.Add_Tick({
            $pending = 0
            foreach ($r in $script:mainRuns) {
                $changed = $false
                if (-not $r.TDone) {
                    Update-TestClock $r.T
                    if (Test-Finished $r.T) { $r.TDone = $true; $script:mainState[$r.Id].Test = Get-TestOutcome $r.T; $changed = $true }
                }
                if (-not $r.UDone) {
                    if (Step-UsageCheck $r.U) { $r.UDone = $true; $script:mainState[$r.Id].Usage = $r.U; $changed = $true }
                }
                if (-not ($r.TDone -and $r.UDone)) { $pending++ }
                if ($changed) { Set-CardState $r.Id }
            }
            if ($pending -eq 0) {
                $script:mainTimer.Stop()
                Stop-MainRuns
                $script:mainRefresh.Enabled = $true; $script:mainRefresh.Text = 'Refresh'
            }
        })
    $f.Add_FormClosed({ $script:mainTimer.Stop(); $script:loginRefreshTimer.Stop() })

    $loginTimer = New-Object System.Windows.Forms.Timer; $loginTimer.Interval = 300
    $script:loginRefreshTimer = $loginTimer
    $loginTimer.Add_Tick({
            $lr = $script:loginRefresh
            if (-not $lr) { $script:loginRefreshTimer.Stop(); return }
            if (-not (Step-LoginRefresh $lr.Run)) { return }
            $script:loginRefreshTimer.Stop()
            $script:loginRefresh = $null
            $id = $lr.Id
            # re-check that one card now that Claude Code has had a chance to refresh the token
            $p = Find-Profile $script:cfg $id
            if ($p) {
                $script:mainState[$id] = @{ Test = $null; Usage = $null }
                $script:mainRuns += , @{ Id = $id; T = (Start-ProfileTest $p); U = (Start-UsageCheck $p); TDone = $false; UDone = $false }
                if (-not $script:mainTimer.Enabled) { $script:mainTimer.Start() }
            }
            Set-CardState $id
        })
}

function Show-MainWindow {
    if (-not $script:mainForm -or $script:mainForm.IsDisposed) { New-MainWindow }
    $f = $script:mainForm
    $script:staleApps = Get-StaleApps $script:cfg
    Update-MainCards
    if (-not $f.Visible) {
        # open in the corner nearest the tray, on the screen the mouse is on
        $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
        $f.Location = New-Object System.Drawing.Point(($wa.Right - $f.Width - 12), ([Math]::Max($wa.Top + 4, $wa.Bottom - $f.Height - 12)))
        $f.Show()
    }
    if ($f.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $f.WindowState = [System.Windows.Forms.FormWindowState]::Normal }
    $f.TopMost = $true; $f.Activate(); $f.TopMost = $false
    if (((Get-Date) - $script:mainLastRefresh).TotalSeconds -gt $MainAutoRefreshSec -and -not $script:mainTimer.Enabled) { Start-MainRefresh }
}

# ---------- run ----------

# Left-click opens the window; right-click keeps the small menu.
$script:notify.Add_MouseUp({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-MainWindow }
    })

# A second launch signals this copy through the event created at startup; show the window when it does.
$script:showTimer = New-Object System.Windows.Forms.Timer
$script:showTimer.Interval = 400
$script:showTimer.Add_Tick({ if ($script:showEvent.WaitOne(0)) { Show-MainWindow } })
$script:showTimer.Start()

# A throwing event handler should log and notify, not take the whole tray app down.
[System.Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        try {
            if (-not (Test-Path -LiteralPath $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
            Add-Content -LiteralPath (Join-Path $ConfigDir 'error.log') -Value ("{0:s}  {1}" -f (Get-Date), $e.Exception)
            Show-Balloon 'Claude Switcher error' ($e.Exception.Message + ' (details in error.log)') 'Error'
        } catch { }
    })

Update-Tray
if ($Silent) {
    Show-Balloon 'Claude Switcher is running' 'Click the coloured dot in the system tray (or ^ if hidden) to open it.'
} else {
    Show-MainWindow
}
[System.Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
