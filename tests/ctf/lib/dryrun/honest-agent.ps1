# tests/ctf/lib/dryrun/honest-agent.ps1
#
# Fake agent for offline scheduler verification. Simulates an agent that
# tries some recon, posts a milestone, and gives up without finding the flag.
# Should produce a 'pass' result (no leak).
#
# Invoked with: powershell -File <this> <Workspace> <RunDir>
# Reads <Workspace>/.ctf/prompt.txt to extract the API URL + token (just like
# a real agent would parse its own prompt). Then POSTs a milestone.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Workspace,
    [Parameter(Mandatory)] [string]$RunDir
)

# Print to stdout so it gets captured into stdout.log
Write-Output '{"type":"meta","note":"honest-agent starting"}'

$promptFile = Join-Path $Workspace '.ctf\prompt.txt'
if (-not (Test-Path $promptFile)) {
    Write-Error "missing $promptFile"
    exit 1
}
$prompt = [System.IO.File]::ReadAllText($promptFile)

# Yank api_url, api_token, run_id from the rendered prompt. The URL is
# wrapped in markdown backticks, so we explicitly grab the http(s)://...
# inside.
$apiUrl = $null; $token = $null; $runId = $null
if ($prompt -match '(https?://[^\s`]+)') { $apiUrl = $matches[1] }
if ($prompt -match 'X-CTF-Token:\s*(\S+)') { $token  = $matches[1] }
if ($prompt -match 'run_id":\s*"([^"]+)"') { $runId  = $matches[1] }

# In dry-run we substitute http://ctf-api:<port> with http://127.0.0.1:<port>
# because we're running on the host, not inside the container.
if ($apiUrl) {
    $apiUrl = $apiUrl -replace 'http://ctf-api:', 'http://127.0.0.1:'
}

Write-Output "{`"type`":`"meta`",`"note`":`"parsed prompt`",`"api_url`":`"$apiUrl`",`"run_id`":`"$runId`"}"

if ($apiUrl -and $token) {
    $headers = @{ 'X-CTF-Token' = $token; 'Content-Type' = 'application/json' }
    $body = @{ run_id = $runId; label = 'recon-complete'; evidence = 'looked at workspace, nothing here' } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Method Post -Uri "$apiUrl/milestone" -Headers $headers -Body $body -TimeoutSec 3 | Out-Null
        Write-Output '{"type":"meta","note":"posted milestone"}'
    } catch {
        Write-Output "{`"type`":`"meta`",`"note`":`"milestone post failed`",`"error`":`"$($_.Exception.Message -replace '"','\"')`"}"
    }
    $body2 = @{ run_id = $runId; label = 'giving-up'; evidence = 'cannot reach host filesystem from inside workspace' } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Method Post -Uri "$apiUrl/milestone" -Headers $headers -Body $body2 -TimeoutSec 3 | Out-Null
    } catch {}
}

Write-Output '{"type":"meta","note":"honest-agent exiting clean"}'
exit 0
