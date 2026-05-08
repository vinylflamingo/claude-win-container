# tests/ctf/smoke.ps1 -- foundation smoke test for the CTF suite.
#
# Exercises the host-side primitives end-to-end with NO Docker:
#   * Find-CtfFreePort + Start-CtfApiServer come up cleanly
#   * GET /healthz returns 200
#   * POST /milestone and POST /flag are recorded with correct token/body
#   * 404s are logged as evidence
#   * Stop-CtfApiServer shuts down without leaking the job
#   * New-CtfRunDir + Write-CtfTranscript + Read-CtfTranscript round-trip
#
# Usage:  .\tests\ctf\smoke.ps1
#         .\tests\ctf\smoke.ps1 -KeepArtifacts   # don't delete tmp run dir on pass
#
# Exits 0 on pass, 1 on fail. Prints a one-line summary at the end.

[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

. (Join-Path $here 'lib\flags.ps1')
. (Join-Path $here 'lib\api.ps1')
. (Join-Path $here 'lib\transcript.ps1')

# Set up an isolated tmp run dir so smoke artifacts don't pollute the main
# tests/ctf/runs/ tree.
$smokeRoot = Join-Path $env:TEMP "cwc-ctf-smoke-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $smokeRoot | Out-Null

$logPath  = Join-Path $smokeRoot 'milestones.jsonl'
$stopPath = Join-Path $smokeRoot '.api-stop'

$failures = @()
$apiJob   = $null

function Assert-That {
    param([Parameter(Mandatory)] [bool]$Cond, [Parameter(Mandatory)] [string]$Message)
    if (-not $Cond) { throw "ASSERT: $Message" }
}

try {
    # --- flags.ps1 sanity ---
    $flag1 = New-CtfFlag
    $flag2 = New-CtfFlag
    Assert-That ($flag1 -ne $flag2) 'two flags should not collide'
    Assert-That ($flag1 -match (Get-CtfFlagPattern)) "flag should match its own pattern: $flag1"
    $tok = New-CtfToken
    Assert-That ($tok.Length -ge 16) "token too short: $tok"
    $rid = New-CtfRunId -Scenario 'smoke'
    Assert-That ($rid -match '^\d{8}-\d{6}-smoke-') "run id format: $rid"
    Write-Host "[smoke] flags/tokens OK"

    # --- api.ps1 lifecycle ---
    $port = Find-CtfFreePort -PreferredPort 17834
    Write-Host "[smoke] starting API on port $port"
    $apiJob = Start-CtfApiServer -Port $port -LogPath $logPath -StopSignalPath $stopPath -BindAddress '127.0.0.1'

    # Health probe: poll up to 6 seconds for the listener to come up.
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 100
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/healthz" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    if (-not $ready) {
        # Surface job errors before bailing -- usually it's a binding failure.
        $errs = Receive-Job -Job $apiJob -Keep -ErrorAction SilentlyContinue 2>&1 | Out-String
        throw "API didn't come up. Job state=$($apiJob.State). Output:`n$errs"
    }
    Write-Host "[smoke] API up"

    # --- POST a couple of milestones and a flag ---
    $headers = @{ 'X-CTF-Token' = $tok; 'Content-Type' = 'application/json' }
    $fakeRunId = 'smoke-fake-run'

    $body1 = @{ run_id = $fakeRunId; label = 'recon'; evidence = 'listed C:\' } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/milestone" -Headers $headers -Body $body1 | Out-Null

    $body2 = @{ run_id = $fakeRunId; label = 'found candidate'; evidence = 'C:\Users\someone\flag.txt' } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/milestone" -Headers $headers -Body $body2 | Out-Null

    $body3 = @{ run_id = $fakeRunId; flag = $flag1 } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/flag" -Headers $headers -Body $body3 | Out-Null

    # 404 hit -- should still be logged as _other for evidence trail.
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$port/admin/secret" -UseBasicParsing -TimeoutSec 2 | Out-Null
    } catch { } # 404 throws on Invoke-WebRequest; we expect it.

    Write-Host "[smoke] posted 3 events + 1 probe"

    # Give the server a moment to flush the last write before we stop it.
    Start-Sleep -Milliseconds 200

    Stop-CtfApiServer -Job $apiJob -StopSignalPath $stopPath
    $apiJob = $null
    Write-Host "[smoke] API stopped"

    # --- verify the JSONL log ---
    Assert-That (Test-Path $logPath) "log file should exist: $logPath"
    $lines = @(Get-Content $logPath | Where-Object { $_ })
    Assert-That ($lines.Count -ge 4) "expected >=4 events, got $($lines.Count)"

    $events = $lines | ForEach-Object { $_ | ConvertFrom-Json }
    $milestoneEvents = @($events | Where-Object { $_.endpoint -eq 'milestone' })
    $flagEvents      = @($events | Where-Object { $_.endpoint -eq 'flag' })
    $otherEvents     = @($events | Where-Object { $_.endpoint -eq '_other' })

    Assert-That ($milestoneEvents.Count -eq 2) "expected 2 milestone events, got $($milestoneEvents.Count)"
    Assert-That ($flagEvents.Count -eq 1)      "expected 1 flag event, got $($flagEvents.Count)"
    Assert-That ($otherEvents.Count -eq 1)     "expected 1 _other event for 404 probe, got $($otherEvents.Count)"

    # Token authn round-trip.
    foreach ($e in $milestoneEvents + $flagEvents) {
        Assert-That ($e.token -eq $tok) "token mismatch on $($e.endpoint): expected $tok, got $($e.token)"
    }

    # Flag round-trip on /flag.
    Assert-That ($flagEvents[0].parsed.flag -eq $flag1) "flag round-trip: expected $flag1, got $($flagEvents[0].parsed.flag)"

    # Milestone label round-trip.
    $labels = $milestoneEvents | ForEach-Object { $_.parsed.label }
    Assert-That (($labels -contains 'recon') -and ($labels -contains 'found candidate')) "milestone labels: $($labels -join ', ')"

    Write-Host "[smoke] API events OK ($($events.Count) total)"

    # --- transcript.ps1 round-trip ---
    $runDir = New-CtfRunDir -SuiteRoot $smokeRoot -Scenario 'smoke-scenario' -RunIndex 0
    Write-CtfTranscript -RunDir $runDir -Stream 'meta'   -Data @{ kind = 'spawn'; pid = 1234 }
    Write-CtfTranscript -RunDir $runDir -Stream 'stdout' -Data @{ line = 'hello from agent' }
    Write-CtfTranscript -RunDir $runDir -Stream 'stderr' -Data @{ line = 'a warning' }
    Write-CtfTranscript -RunDir $runDir -Stream 'event'  -Data @{ kind = 'milestone-emitted'; label = 'recon' }
    $transcript = @(Read-CtfTranscript -RunDir $runDir)
    Assert-That ($transcript.Count -eq 4) "transcript round-trip: expected 4 entries, got $($transcript.Count)"
    Assert-That ($transcript[1].stream -eq 'stdout' -and $transcript[1].line -eq 'hello from agent') 'transcript content shape'

    Write-Host "[smoke] transcript OK"
    Write-Host ""
    Write-Host "[smoke] PASS" -ForegroundColor Green
} catch {
    $failures += $_.Exception.Message
    Write-Host ""
    Write-Host "[smoke] FAIL: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($apiJob) {
        try { Stop-CtfApiServer -Job $apiJob -StopSignalPath $stopPath } catch {}
    }
    if ($KeepArtifacts -or $failures.Count -gt 0) {
        Write-Host "[smoke] artifacts kept at $smokeRoot" -ForegroundColor Yellow
    } else {
        Remove-Item -Recurse -Force $smokeRoot -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) { exit 1 } else { exit 0 }
