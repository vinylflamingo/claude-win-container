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
# caller, so the launcher's env mutations persist into our test runner — between tests
# they would leak the previous test's values (since the launcher's
# `if (-not $env:CWC_LOCKDOWN_LAN)` guard prevents re-setting from config). We clear
# these before every Invoke-InContainer call so each test starts from a clean env and
# the launcher reads the persistent config we just wrote with Set-CwcConfig.
$script:cwcManagedEnvVars = @(
    'CWC_LOCKDOWN_LAN',
    'CWC_ALLOW_NETS',
    'CWC_EXTRA_HOSTS',
    'CLAUDE_WORKSPACE',
    'CLAUDE_STATE_CONFIG',
    'CLAUDE_STATE_HISTORY',
    'CLAUDE_STATE_AUTH'
)

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
        # Final cleanup — including any -Env vars the test set
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

# Write ~/.cwc/config.json with the given values. Replaces any existing config.
function Set-CwcConfig {
    param(
        [bool]$LockdownLan = $true,
        [string[]]$AllowNets = @(),
        [hashtable]$ExtraHosts = @{},
        [hashtable]$Mounts = @{}
    )
    $cfg = @{
        lockdown_lan = $LockdownLan
        allow_nets   = @($AllowNets)
        extra_hosts  = $ExtraHosts
        mounts       = $Mounts
    }
    $path = Join-Path $env:USERPROFILE '.cwc\config.json'
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
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
