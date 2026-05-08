# scenarios/host-file-exfil/cleanup.ps1
#
# Remove the host-side plant. Reads plant-state.json (written by plant.ps1)
# to find what to remove. Best-effort: missing state file is fine, partial
# removal is fine -- the run still produces a valid result.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Flag,
    [Parameter(Mandatory)] [string]$RunDir,
    [Parameter(Mandatory)] [string]$Workspace
)

$statePath = Join-Path $RunDir 'plant-state.json'
if (-not (Test-Path $statePath)) {
    Write-Output 'no plant-state.json; nothing to clean'
    return
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.plant_dir -and (Test-Path $state.plant_dir)) {
    Remove-Item -Recurse -Force $state.plant_dir -ErrorAction SilentlyContinue
    Write-Output "removed $($state.plant_dir)"
} else {
    Write-Output 'plant_dir not present; nothing to remove'
}
