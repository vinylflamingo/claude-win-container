# tests/ctf/lib/config.ps1 -- write per-project cwc config for a CTF run.
#
# Each CTF run uses its own workspace directory on the host as the cwc
# project. cwc looks up per-project state by slugging the project's absolute
# path, so we must:
#   1. Compute the slug for the run workspace
#   2. Write ~/.cwc/projects/<slug>/config.json with sandbox settings BEFORE
#      launching cwc, otherwise the auto-setup wizard prompts interactively
#      and the agent run blocks forever
#
# We DO NOT touch ~/.cwc/config.json (the global denylist). The suite
# orchestrator snapshot/restores that at the suite boundary if needed.

# Mirrors cwc.ps1's Get-ProjectSlug exactly. Duplicated by design (same
# rationale as the existing tests/lib/harness.ps1 mirror): the launcher reads
# a config keyed by this hash, so we have to compute it the same way.
function Get-CtfProjectSlug {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    $abs = (Resolve-Path -LiteralPath $Path).Path.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($abs)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($bytes)
    } finally {
        $sha1.Dispose()
    }
    $hex = [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    $base = Split-Path -Leaf $abs
    $base = ($base -replace '[^a-z0-9._-]', '-')
    "$base-$($hex.Substring(0,12))"
}

# Get the absolute path to the per-project config file for a workspace.
function Get-CtfProjectConfigPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Workspace)
    $slug = Get-CtfProjectSlug -Path $Workspace
    Join-Path $env:USERPROFILE ".cwc\projects\$slug\config.json"
}

# Write a minimal sandbox-active per-project config for a run workspace.
# $ExtraHosts is the cwc-format hashtable: { name = @{ target=...; ports=@(...) } }.
# Existence of this file is what tells cwc to skip the auto-setup wizard.
function Set-CtfRunConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Workspace,
        [bool]$LockdownLan = $true,
        [bool]$HardenEnabled = $false,
        [string[]]$AllowNets = @(),
        [hashtable]$ExtraHosts = @{},
        [hashtable]$Mounts = @{}
    )
    $abs = (Resolve-Path -LiteralPath $Workspace).Path
    $cfgPath = Get-CtfProjectConfigPath -Workspace $abs
    $cfgDir  = Split-Path -Parent $cfgPath
    if (-not (Test-Path $cfgDir)) {
        New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    }

    $cfg = @{
        project_path   = $abs
        project_name   = Split-Path -Leaf $abs
        lockdown_lan   = $LockdownLan
        harden_enabled = $HardenEnabled
        allow_nets     = @($AllowNets)
        extra_hosts    = $ExtraHosts
        mounts         = $Mounts
        trusted_files  = @{}
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cfgPath
    $cfgPath
}

# Remove a per-project config (used during cleanup so we don't litter the
# user's ~/.cwc/projects tree with one-shot CTF run state).
function Remove-CtfRunConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Workspace)
    $cfgPath = Get-CtfProjectConfigPath -Workspace $Workspace
    $cfgDir  = Split-Path -Parent $cfgPath
    if (Test-Path $cfgDir) {
        Remove-Item -Recurse -Force $cfgDir -ErrorAction SilentlyContinue
    }
}
