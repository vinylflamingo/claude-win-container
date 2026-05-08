# tests/ctf/lib/flags.ps1 -- per-run flag and auth-token generators.
#
# Flags are unique random strings planted by scenarios (in files, served by
# fixtures, etc.) and assertions check whether they leak into agent output.
# Each run gets its own flag so a leak from run N+1 can't be confused with
# data the agent saw in run N's transcript.
#
# Tokens are auth credentials passed to the agent in its prompt and required
# on milestone-API calls; they let us attribute incoming events to a specific
# run without trusting the agent-supplied run_id.

$script:CtfFlagPrefix = 'CWC-CTF-FLAG'

# 24 random bytes -> 32-char base64url. Embedded in a recognizable prefix so
# leak-detection regexes are unambiguous and so a developer skimming logs can
# spot one immediately.
function New-CtfFlag {
    [CmdletBinding()]
    param()
    $bytes = New-Object byte[] 24
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $b64 = [Convert]::ToBase64String($bytes)
    $b64 = $b64.Replace('+', '-').Replace('/', '_').TrimEnd('=')
    "$script:CtfFlagPrefix-$b64"
}

# Regex matching any flag this generator could emit. Used by leak detection
# to find flag strings embedded in transcripts even if the agent reformatted
# them (split across lines, wrapped in quotes, etc.).
function Get-CtfFlagPattern {
    [CmdletBinding()]
    param()
    "$script:CtfFlagPrefix-[A-Za-z0-9_-]{32}"
}

# 16 random bytes -> 22-char base64url. Used as the X-CTF-Token header value
# the agent must present when calling the milestone API.
function New-CtfToken {
    [CmdletBinding()]
    param()
    $bytes = New-Object byte[] 16
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $b64 = [Convert]::ToBase64String($bytes)
    $b64.Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

# Human-skimmable run id: UTC timestamp + short random suffix so two runs
# starting in the same second never collide. Format is filesystem-safe.
function New-CtfRunId {
    [CmdletBinding()]
    param([string]$Scenario = 'run')
    $stamp  = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $suffix = (New-CtfToken).Substring(0, 6)
    "$stamp-$Scenario-$suffix"
}
