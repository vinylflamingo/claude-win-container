# tests/ctf/lib/transcript.ps1 -- per-run output directory + JSONL append.
#
# Layout (one folder per (scenario, run-index) pair):
#
#   tests/ctf/runs/<suite-stamp>/<scenario>/run-<i>/
#     transcript.jsonl     append-only event log: stdout/stderr/event/meta
#     stdout.log           raw stdout dump (for grep convenience)
#     stderr.log           raw stderr dump
#     plant.log            output of plant.ps1 host-side setup
#     cleanup.log          output of cleanup.ps1 teardown
#     result.json          summary: {leak, leak_evidence, milestones, duration}
#
# transcript.jsonl is the canonical record. The flat .log files exist so a human
# debugging a failed run can grep without a JSON parser. When the runner spawns
# the agent we'll wire process stdout/stderr through here as Stream='stdout' /
# Stream='stderr' events; for now scenarios just use New-CtfRunDir + the JSONL
# appender directly.

# Create (or get) the per-run directory tree and return its absolute path.
function New-CtfRunDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SuiteRoot,
        [Parameter(Mandatory)] [string]$Scenario,
        [Parameter(Mandatory)] [int]$RunIndex
    )
    $dir = Join-Path $SuiteRoot (Join-Path $Scenario "run-$RunIndex")
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    (Resolve-Path $dir).Path
}

# Append one JSONL event to the run's transcript. $Data is freeform -- common
# fields are 'line' (for stdout/stderr) and 'kind' (for events like
# 'spawn', 'timeout', 'flag-detected'). The 'stream' field categorizes the
# entry for filtering.
function Write-CtfTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RunDir,
        [Parameter(Mandatory)] [ValidateSet('stdout','stderr','event','meta')] [string]$Stream,
        [Parameter(Mandatory)] [hashtable]$Data
    )
    $entry = [ordered]@{
        ts     = (Get-Date).ToUniversalTime().ToString('o')
        stream = $Stream
    }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    $line = ($entry | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine
    [System.IO.File]::AppendAllText((Join-Path $RunDir 'transcript.jsonl'), $line)
}

# Read all transcript events back as objects. Used by assertions and the
# leak detector.
function Read-CtfTranscript {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$RunDir)
    $path = Join-Path $RunDir 'transcript.jsonl'
    if (-not (Test-Path $path)) { return @() }
    Get-Content -LiteralPath $path | Where-Object { $_ } | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ }
}
