# tests/ctf/run.ps1 -- CTF suite entry point.
#
# Orchestrates a full red-team run:
#   1. Discover scenarios under tests/ctf/scenarios/
#   2. Print a cost estimate
#   3. Start the milestone API server
#   4. Build the work queue (k_runs per scenario)
#   5. Dispatch through the parallel scheduler
#   6. Aggregate per-scenario verdicts
#   7. Write summary.json + print a human-readable summary
#   8. Stop the API server
#
# Usage:
#   .\tests\ctf\run.ps1                              # full suite, default settings
#   .\tests\ctf\run.ps1 -Filter host-file            # only matching scenarios
#   .\tests\ctf\run.ps1 -Parallel 2                  # concurrency cap (default 4)
#   .\tests\ctf\run.ps1 -MaxSuiteMinutes 30          # suite-wide deadline
#   .\tests\ctf\run.ps1 -KeepArtifacts               # don't delete run workspaces
#   .\tests\ctf\run.ps1 -DryRunAgent <path-to-ps1>   # substitute fake agent (no API spend)
#   .\tests\ctf\run.ps1 -Image my/img:tag            # override CWC_IMAGE
#
# Exit codes:
#   0 = all scenarios passed (no leaks)
#   1 = at least one scenario had a leak
#   2 = suite errored (infra problem)

[CmdletBinding()]
param(
    [string]$Filter = '',
    [int]$Parallel = 4,
    [int]$MaxSuiteMinutes = 90,
    [int]$MaxRunSecondsOverride = 0,    # 0 = use scenario.psd1 value
    [switch]$KeepArtifacts,
    [string]$DryRunAgent = $null,
    [string]$Image = '',
    [string]$ApiBindAddress = '0.0.0.0'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --- Lib loading ---
$libDir = Join-Path $here 'lib'
. (Join-Path $libDir 'flags.ps1')
. (Join-Path $libDir 'api.ps1')
. (Join-Path $libDir 'transcript.ps1')
. (Join-Path $libDir 'leak.ps1')
. (Join-Path $libDir 'config.ps1')
. (Join-Path $libDir 'runner.ps1')
. (Join-Path $libDir 'sched.ps1')

# --- Resolve cwc launcher ---
$repoRoot   = Split-Path -Parent (Split-Path -Parent $here)
$cwcLauncher = Join-Path $repoRoot 'cwc.ps1'
if (-not (Test-Path $cwcLauncher)) {
    Write-Host "ERROR: cwc.ps1 not found at $cwcLauncher" -ForegroundColor Red
    exit 2
}

# --- Image override ---
$savedImage = $env:CWC_IMAGE
if ($Image) { $env:CWC_IMAGE = $Image }

# --- Suite directories ---
$suiteStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$suiteRoot  = Join-Path $here "runs\$suiteStamp"
New-Item -ItemType Directory -Force -Path $suiteRoot | Out-Null
$milestoneLog = Join-Path $suiteRoot 'milestones.jsonl'
$apiStop      = Join-Path $suiteRoot '.api-stop'
[System.IO.File]::WriteAllText($milestoneLog, '')

# --- Scenario discovery ---
$scenariosRoot = Join-Path $here 'scenarios'
if (-not (Test-Path $scenariosRoot)) {
    Write-Host "ERROR: $scenariosRoot does not exist" -ForegroundColor Red
    exit 2
}
$allScenarios = Get-ChildItem -Path $scenariosRoot -Directory | ForEach-Object {
    $psd = Join-Path $_.FullName 'scenario.psd1'
    if (Test-Path $psd) { $_.FullName }
} | Where-Object { $_ }

if (-not $allScenarios) {
    Write-Host "No scenarios found under $scenariosRoot" -ForegroundColor Yellow
    exit 2
}

if ($Filter) {
    $allScenarios = @($allScenarios | Where-Object { $_ -match [regex]::Escape($Filter) -or
                                                     (Split-Path -Leaf $_) -match $Filter })
    if (-not $allScenarios) {
        Write-Host "No scenarios match filter '$Filter'" -ForegroundColor Yellow
        exit 2
    }
}

# --- Build queue + cost estimate ---
$queue = @(Get-CtfWorkQueue -ScenarioDirs $allScenarios)
if ($MaxRunSecondsOverride -gt 0) {
    foreach ($q in $queue) { $q.max_seconds = $MaxRunSecondsOverride }
}
$totalRuns    = $queue.Count
$totalMaxMin  = ([math]::Ceiling((($queue | Measure-Object -Property max_seconds -Sum).Sum) / 60.0))
$walltimeBest = [math]::Ceiling($totalMaxMin / [math]::Max($Parallel, 1))

# Rough cost per run-minute, for "did the user mean to do this" awareness.
# Tool-heavy reasoning at Opus rates is ~$0.08-0.20 per minute. Take the
# high end as the worst-case estimate. This is an order-of-magnitude
# warning, not an accounting figure.
$costLow  = [math]::Round(($queue | Measure-Object -Property max_seconds -Sum).Sum / 60.0 * 0.08, 2)
$costHigh = [math]::Round(($queue | Measure-Object -Property max_seconds -Sum).Sum / 60.0 * 0.20, 2)

Write-Host ""
Write-Host ("=" * 64) -ForegroundColor Cyan
Write-Host "CTF suite ($suiteStamp)" -ForegroundColor Cyan
Write-Host ("=" * 64) -ForegroundColor Cyan
Write-Host "  scenarios       : $($allScenarios.Count)"
Write-Host "  total runs      : $totalRuns"
Write-Host "  parallel        : $Parallel"
Write-Host "  max suite       : $MaxSuiteMinutes min"
Write-Host "  worst wall-time : $walltimeBest min (if every run hits its deadline)"
if ($DryRunAgent) {
    Write-Host "  agent           : DRY-RUN ($DryRunAgent)" -ForegroundColor Yellow
    Write-Host "  est. API cost   : `$0 (no real agent)"
} else {
    Write-Host "  agent           : claude (live)"
    Write-Host "  est. API cost   : `$$costLow - `$$costHigh (rough order-of-magnitude)"
}
Write-Host "  artifacts at    : $suiteRoot"
Write-Host ""

# --- Start API server ---
$apiPort = Find-CtfFreePort -PreferredPort 17834
$apiUrl  = "http://127.0.0.1:$apiPort"
$apiJob  = Start-CtfApiServer -Port $apiPort -LogPath $milestoneLog -StopSignalPath $apiStop -BindAddress $ApiBindAddress
Write-Host "API: $apiUrl (bind=$ApiBindAddress, log=$milestoneLog)" -ForegroundColor DarkGray

# Health probe.
$apiReady = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 100
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$apiPort/healthz" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $apiReady = $true; break }
    } catch {}
}
if (-not $apiReady) {
    Write-Host "ERROR: API server did not come up in 6 seconds" -ForegroundColor Red
    Stop-CtfApiServer -Job $apiJob -StopSignalPath $apiStop
    exit 2
}

# --- Run scheduler ---
$progress = {
    param($msg)
    Write-Host "  $msg" -ForegroundColor DarkGray
}

$results = @()
$suiteStartedAt = Get-Date
try {
    $results = @(Invoke-CtfScheduler `
        -Queue $queue `
        -LibDir $libDir `
        -SuiteRoot $suiteRoot `
        -ApiUrl $apiUrl `
        -ApiPort $apiPort `
        -MilestoneLogPath $milestoneLog `
        -CwcLauncher $cwcLauncher `
        -Parallel $Parallel `
        -MaxSuiteMinutes $MaxSuiteMinutes `
        -KeepArtifacts:$KeepArtifacts `
        -AgentCommandOverride $DryRunAgent `
        -OnProgress $progress)
} finally {
    Stop-CtfApiServer -Job $apiJob -StopSignalPath $apiStop
    if ($null -ne $savedImage) { $env:CWC_IMAGE = $savedImage } else { Remove-Item Env:CWC_IMAGE -ErrorAction SilentlyContinue }
}
$suiteElapsed = (Get-Date) - $suiteStartedAt

# --- Aggregate ---
$verdicts = Get-CtfScenarioVerdicts -Results $results
$suiteFailed = ($verdicts.Values | Where-Object { $_.verdict -eq 'fail' }).Count
$suiteErrored = ($verdicts.Values | Where-Object { $_.verdict -eq 'error' }).Count

# --- Summary file ---
$summary = [ordered]@{
    suite_stamp     = $suiteStamp
    started_at      = $suiteStartedAt.ToUniversalTime().ToString('o')
    duration_seconds = [math]::Round($suiteElapsed.TotalSeconds, 1)
    parallel        = $Parallel
    max_suite_min   = $MaxSuiteMinutes
    dry_run         = [bool]$DryRunAgent
    scenarios       = @{}
    runs            = $results
}
foreach ($id in $verdicts.Keys) {
    $v = $verdicts[$id]
    $summary.scenarios[$id] = @{
        verdict       = $v.verdict
        leak_count    = $v.leak_count
        pass_count    = $v.pass_count
        fail_count    = $v.fail_count
        timeout_count = $v.timeout_count
        error_count   = $v.error_count
        skipped_count = $v.skipped_count
    }
}
($summary | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $suiteRoot 'summary.json')

# --- Print summary ---
Write-Host ""
Write-Host ("=" * 64) -ForegroundColor Cyan
Write-Host ("Suite results ({0:N0}s elapsed)" -f $suiteElapsed.TotalSeconds) -ForegroundColor Cyan
Write-Host ("=" * 64) -ForegroundColor Cyan
foreach ($id in ($verdicts.Keys | Sort-Object)) {
    $v = $verdicts[$id]
    $color = switch ($v.verdict) {
        'pass'    { 'Green' }
        'fail'    { 'Red' }
        'error'   { 'Magenta' }
        'timeout' { 'Yellow' }
        default   { 'DarkGray' }
    }
    $detail = "pass=$($v.pass_count) fail=$($v.fail_count) timeout=$($v.timeout_count) error=$($v.error_count)"
    Write-Host ("  [{0,-7}] {1}  ({2})" -f $v.verdict.ToUpperInvariant(), $id, $detail) -ForegroundColor $color
}
Write-Host ""
Write-Host "  summary.json : $(Join-Path $suiteRoot 'summary.json')" -ForegroundColor DarkGray
Write-Host "  milestones   : $milestoneLog" -ForegroundColor DarkGray
Write-Host ""

if ($suiteFailed -gt 0) { exit 1 }
elseif ($suiteErrored -gt 0) { exit 2 }
else { exit 0 }
