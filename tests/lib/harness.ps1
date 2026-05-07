# Test harness shared across the suite. Provides Run-TestCase, Invoke-InContainer,
# Set-CwcConfig, and a small set of assertion helpers. Loaded by tests/run.ps1.
#
# Conventions:
# - Tests throw on failure (via Should-* helpers). Run-TestCase catches and records.
# - Invoke-InContainer always runs from a known fixture workspace unless -WorkDir is given.
# - Set-CwcConfig writes ~/.cwc/config.json in full each call (no merge with existing).

function Run-TestCase {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string]$Category = 'general',
        [Parameter(Mandatory)] [scriptblock]$Test
    )
    if ($script:Filter -and ("$Category $Name" -notmatch $script:Filter)) {
        $script:skipped++
        return
    }
    Write-Host "  [$Category] $Name" -NoNewline
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Test
        $sw.Stop()
        Write-Host (" $([char]0x2713) {0:N1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        $script:passed++
        $script:results += [pscustomobject]@{
            Category = $Category; Name = $Name; Status = 'pass'; Message = $null
        }
    } catch {
        $sw.Stop()
        Write-Host (" $([char]0x2717) {0:N1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkRed
        $script:failed++
        $script:results += [pscustomobject]@{
            Category = $Category; Name = $Name; Status = 'fail'; Message = $_.Exception.Message
        }
    }
}

# Env vars the launcher manages internally (sets in $env: to communicate with docker
# compose's variable substitution). PowerShell scripts run in the same process as the
# caller, so the launcher's env mutations persist into our test runner -- between tests
# they would leak the previous test's values (since the launcher's
# `if (-not $env:CWC_LOCKDOWN_LAN)` guard prevents re-setting from config). We clear
# these before every Invoke-InContainer call so each test starts from a clean env and
# the launcher reads the persistent config we just wrote with Set-CwcConfig.
$script:cwcManagedEnvVars = @(
    'CWC_LOCKDOWN_LAN',
    'CWC_ALLOW_NETS',
    'CWC_EXTRA_HOSTS',
    'CWC_HARDEN',
    'CLAUDE_WORKSPACE',
    'CLAUDE_STATE_CONFIG',
    'CLAUDE_STATE_HISTORY',
    'CLAUDE_STATE_AUTH'
)

# Tests should never hit the GitHub releases API for the launch banner's "is this
# the latest stable?" check -- it's slow and rate-limited. The launcher honors
# CWC_SKIP_VERSION_CHECK=1 to bypass it, which we set globally for the duration
# of the test run.
$env:CWC_SKIP_VERSION_CHECK = '1'

# Run a PowerShell command inside a one-shot cwc container. Working dir on the host
# determines what gets bind-mounted as the workspace; defaults to the suite's fixture.
# -Env lets tests deliberately set CWC_* vars to test env-driven overrides (those are
# applied AFTER the cleanup, so they actually take effect for this call).
# Strips the launcher's banner / session-summary lines so assertions see only command output.
function Invoke-InContainer {
    param(
        [Parameter(Mandatory)] [string]$Command,
        [string]$WorkDir = $null,
        [hashtable]$Env = @{}
    )
    if (-not $WorkDir) { $WorkDir = $script:fixtures.workspace }

    foreach ($v in $script:cwcManagedEnvVars) {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
    foreach ($k in $Env.Keys) {
        Set-Item "Env:$k" -Value $Env[$k]
    }

    Push-Location $WorkDir
    try {
        $raw = & cwc powershell -NoProfile -Command $Command 2>&1
    } finally {
        Pop-Location
        # Final cleanup -- including any -Env vars the test set
        foreach ($v in $script:cwcManagedEnvVars) {
            Remove-Item "Env:$v" -ErrorAction SilentlyContinue
        }
        foreach ($k in $Env.Keys) {
            Remove-Item "Env:$k" -ErrorAction SilentlyContinue
        }
    }
    $text = ($raw | Out-String)

    # Drop launcher banner: any line starting with '[cwc]' (entrypoint banners) and
    # any line that's part of the launcher's session-summary block (lines indented with
    # two spaces and containing 'Project | State | Auth | Command | Forwarded | Hosts | Mounts :').
    $cleaned = ($text -split "`r?`n") | Where-Object {
        $_ -notmatch '^\s*\[cwc\]' -and
        $_ -notmatch '^\s{2,}(Project|State|Auth|Command|Forwarded|Hosts|Mounts)\s*:'
    }
    return ($cleaned -join "`n")
}

# Mirror of cwc.ps1's Get-ProjectSlug. Tests need to compute the per-project config
# path the same way the launcher does, so we duplicate the formula here.
function Get-CwcSlugForTest([string]$path) {
    $abs = (Resolve-Path $path).Path.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($abs)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha1.ComputeHash($bytes)
    $sha1.Dispose()
    $hex = [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    $base = Split-Path -Leaf $abs
    $base = ($base -replace '[^a-z0-9._-]', '-')
    return "$base-$($hex.Substring(0,12))"
}

# Seed the test environment with both the global config (~/.cwc/config.json) and
# a per-project config (~/.cwc/projects/<slug>/config.json) for the project
# directory specified by -ProjectDir.
#
# Default -ProjectDir is $script:fixtures.workspace -- the dir Invoke-InContainer
# runs from -- so container-side tests don't need to pass it. Host-side tests that
# operate on a different fixture project (project-isolation, setup) pass it
# explicitly.
#
# Replaces both files in full each call -- no merge with existing.
# Accepts ExtraHosts in either old bare-string format ({fqdn -> '<target>'}) or
# the {fqdn -> @{target, ports}} format; old-format strings are auto-promoted
# to {target, ports=@(443,80)} so older tests stay readable.
function Set-CwcConfig {
    param(
        [bool]$LockdownLan = $true,
        [string[]]$AllowNets = @(),
        [hashtable]$ExtraHosts = @{},
        [hashtable]$Mounts = @{},
        [string[]]$HostDenylist = $null,
        [bool]$HardenEnabled = $false,
        [hashtable]$TrustedFiles = $null,
        [string]$ProjectDir = $null
    )
    if (-not $ProjectDir) {
        $ProjectDir = if ($script:fixtures -and $script:fixtures.workspace) { $script:fixtures.workspace } else { $PWD.Path }
    }
    $hostsOut = @{}
    foreach ($k in $ExtraHosts.Keys) {
        $v = $ExtraHosts[$k]
        if ($v -is [string]) {
            $hostsOut[$k] = @{ target = $v; ports = @(443, 80) }
        } else {
            $hostsOut[$k] = $v
        }
    }
    if ($null -eq $HostDenylist) {
        $HostDenylist = @(
            '*.anthropic.com', 'anthropic.com',
            '*.claude.ai',     'claude.ai',
            '*.claude.com',    'claude.com',
            '*.anthropic.ai',  'anthropic.ai'
        )
    }
    if ($null -eq $TrustedFiles) { $TrustedFiles = @{} }

    # Global: only security policy lives here.
    $globalCfg = @{
        host_denylist = @($HostDenylist)
        defaults      = @{
            lockdown_lan   = $true
            harden_enabled = $false
        }
    }
    $globalPath = Join-Path $env:USERPROFILE '.cwc\config.json'
    $globalDir  = Split-Path -Parent $globalPath
    if (-not (Test-Path $globalDir)) { New-Item -ItemType Directory -Force -Path $globalDir | Out-Null }
    $globalCfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $globalPath

    # Per-project: everything else, keyed by project slug.
    $abs  = (Resolve-Path $ProjectDir).Path
    $slug = Get-CwcSlugForTest $abs
    $projDir  = Join-Path $env:USERPROFILE ".cwc\projects\$slug"
    $projPath = Join-Path $projDir 'config.json'
    if (-not (Test-Path $projDir)) { New-Item -ItemType Directory -Force -Path $projDir | Out-Null }
    $projCfg = @{
        project_path   = $abs
        project_name   = Split-Path -Leaf $abs
        lockdown_lan   = $LockdownLan
        harden_enabled = $HardenEnabled
        allow_nets     = @($AllowNets)
        extra_hosts    = $hostsOut
        mounts         = $Mounts
        trusted_files  = $TrustedFiles
    }
    $projCfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $projPath
}

# Run a cwc subcommand on the HOST (not inside a container). Used for tests of
# host-side commands like 'cwc firewall host-add', 'cwc trust', 'cwc harden status'
# where the behaviour we're checking lives in cwc.ps1 itself, not in the container.
# Returns a hashtable: @{ ExitCode = <int>; Output = <string> }.
#
# Default -WorkDir is the fixture workspace (mirrors Invoke-InContainer). This
# makes Set-CwcConfig's default project (also fixture workspace) line up with
# where cwc.ps1 looks up the per-project config.
function Invoke-CwcOnHost {
    param(
        [Parameter(Mandatory)] [string[]]$Args,
        [string]$WorkDir = $null
    )
    if (-not $WorkDir) {
        $WorkDir = if ($script:fixtures -and $script:fixtures.workspace) { $script:fixtures.workspace } else { $PWD.Path }
    }
    Push-Location $WorkDir
    try {
        # *>&1 captures ALL streams (stdout, stderr, warning, verbose, debug,
        # information). cwc.ps1 prints user-facing output via Write-Host, which
        # goes to the information stream (6) on PS 5.1+. Plain 2>&1 misses that
        # stream and yields empty captures, so we use *>&1.
        $raw = & cwc @Args *>&1
        return @{
            ExitCode = $LASTEXITCODE
            Output   = ($raw | Out-String)
        }
    } finally {
        Pop-Location
    }
}

# Assertions
function Should-Match {
    param([string]$Value, [string]$Pattern, [string]$Because = '')
    if ($Value -notmatch $Pattern) {
        $msg = "Expected match '$Pattern' in:`n$Value"
        if ($Because) { $msg += "`n(because: $Because)" }
        throw $msg
    }
}

function Should-NotMatch {
    param([string]$Value, [string]$Pattern, [string]$Because = '')
    if ($Value -match $Pattern) {
        $msg = "Expected NOT to match '$Pattern' but did, in:`n$Value"
        if ($Because) { $msg += "`n(because: $Because)" }
        throw $msg
    }
}

function Should-BeTrue {
    param($Value, [string]$Because = '')
    if (-not $Value) {
        $msg = if ($Because) { "Expected truthy: $Because" } else { "Expected truthy, got: $Value" }
        throw $msg
    }
}

function Should-Equal {
    param($Actual, $Expected, [string]$Because = '')
    if ($Actual -ne $Expected) {
        $msg = "Expected '$Expected' but got '$Actual'"
        if ($Because) { $msg += " (because: $Because)" }
        throw $msg
    }
}

function Should-NotEqual {
    param($Actual, $Expected, [string]$Because = '')
    if ($Actual -eq $Expected) {
        $msg = "Expected NOT '$Expected' but got '$Actual'"
        if ($Because) { $msg += " (because: $Because)" }
        throw $msg
    }
}
