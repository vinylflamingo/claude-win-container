# tests/ctf/lib/sched.ps1 -- parallel scheduler with concurrency cap and
# suite-wide deadline.
#
# Inputs: a list of work items, each = @{ scenario_dir, run_index }.
# For each item, the scheduler launches a Start-Job that calls Invoke-CtfRun
# (from lib/runner.ps1). At most $Parallel jobs run concurrently. The whole
# suite is bounded by $MaxSuiteMinutes; on suite deadline, in-flight jobs
# are stopped and remaining items are skipped.
#
# Each job runs in its own runspace, so we have to dot-source the libraries
# inside the job's scriptblock -- they don't inherit from the caller.

# Build the full work queue from a list of scenarios. For each scenario
# pulls k_runs from its scenario.psd1.
function Get-CtfWorkQueue {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]]$ScenarioDirs)

    $queue = @()
    foreach ($dir in $ScenarioDirs) {
        $psd = Join-Path $dir 'scenario.psd1'
        if (-not (Test-Path $psd)) { continue }
        $meta = Import-PowerShellDataFile -Path $psd
        $k = if ($meta.k_runs) { [int]$meta.k_runs } else { 3 }
        for ($i = 0; $i -lt $k; $i++) {
            $queue += @{
                scenario_dir = (Resolve-Path -LiteralPath $dir).Path
                scenario_id  = $meta.id
                run_index    = $i
                max_seconds  = if ($meta.max_seconds) { [int]$meta.max_seconds } else { 900 }
            }
        }
    }
    $queue
}

# Scriptblock executed inside each job's runspace. Dot-sources the libraries
# from $LibDir, then calls Invoke-CtfRun. All output (the result hashtable)
# is returned to the scheduler via Receive-Job.
$script:CtfJobScriptBlock = {
    param(
        $LibDir, $ScenarioDir, $RunIndex, $SuiteRoot, $ApiUrl, $ApiPort,
        $MilestoneLogPath, $CwcLauncher, $MaxSeconds, $KeepArtifacts,
        $AgentCommandOverride
    )
    . (Join-Path $LibDir 'flags.ps1')
    . (Join-Path $LibDir 'transcript.ps1')
    . (Join-Path $LibDir 'leak.ps1')
    . (Join-Path $LibDir 'config.ps1')
    . (Join-Path $LibDir 'runner.ps1')

    $params = @{
        ScenarioDir          = $ScenarioDir
        RunIndex             = $RunIndex
        SuiteRoot            = $SuiteRoot
        ApiUrl               = $ApiUrl
        ApiPort              = $ApiPort
        MilestoneLogPath     = $MilestoneLogPath
        CwcLauncher          = $CwcLauncher
        MaxSeconds           = $MaxSeconds
    }
    if ($KeepArtifacts) { $params['KeepArtifacts'] = $true }
    if ($AgentCommandOverride) { $params['AgentCommandOverride'] = $AgentCommandOverride }

    Invoke-CtfRun @params
}

# Run the work queue. Returns an array of result hashtables (one per item).
# Items skipped due to suite deadline get a synthetic result with status='skipped'.
function Invoke-CtfScheduler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array]$Queue,
        [Parameter(Mandatory)] [string]$LibDir,
        [Parameter(Mandatory)] [string]$SuiteRoot,
        [Parameter(Mandatory)] [string]$ApiUrl,
        [Parameter(Mandatory)] [int]$ApiPort,
        [Parameter(Mandatory)] [string]$MilestoneLogPath,
        [Parameter(Mandatory)] [string]$CwcLauncher,
        [int]$Parallel = 4,
        [int]$MaxSuiteMinutes = 90,
        [switch]$KeepArtifacts,
        [string]$AgentCommandOverride = $null,
        [scriptblock]$OnProgress = $null
    )

    $deadline = (Get-Date).AddMinutes($MaxSuiteMinutes)
    $pending  = [System.Collections.Generic.Queue[object]]::new()
    foreach ($item in $Queue) { $pending.Enqueue($item) }

    $running = @{}    # job-id -> @{ job; item; started_at }
    $results = @()

    $emit = {
        param($msg)
        if ($OnProgress) { & $OnProgress $msg }
    }

    & $emit "scheduler: queue=$($Queue.Count) parallel=$Parallel deadline=$($deadline.ToString('HH:mm:ss'))"

    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        # Suite deadline: stop accepting new work and kill in-flight.
        if ((Get-Date) -ge $deadline) {
            & $emit "scheduler: suite deadline hit, stopping in-flight ($($running.Count)) and skipping pending ($($pending.Count))"
            foreach ($entry in $running.Values) {
                try { Stop-Job -Job $entry.job -ErrorAction SilentlyContinue } catch {}
            }
            # Drain stopped jobs as 'timeout' results.
            foreach ($entry in $running.Values) {
                $r = $null
                try { $r = Receive-Job -Job $entry.job -ErrorAction SilentlyContinue 2>&1 } catch {}
                Remove-Job -Job $entry.job -Force -ErrorAction SilentlyContinue
                $results += @{
                    scenario  = $entry.item.scenario_id
                    run_index = $entry.item.run_index
                    status    = 'timeout'
                    leaked    = $false
                    error     = 'suite deadline reached'
                    duration_seconds = ((Get-Date) - $entry.started_at).TotalSeconds
                }
            }
            $running.Clear()
            while ($pending.Count -gt 0) {
                $item = $pending.Dequeue()
                $results += @{
                    scenario  = $item.scenario_id
                    run_index = $item.run_index
                    status    = 'skipped'
                    leaked    = $false
                    error     = 'suite deadline reached before start'
                }
            }
            break
        }

        # Dispatch up to Parallel concurrent jobs.
        while ($pending.Count -gt 0 -and $running.Count -lt $Parallel) {
            $item = $pending.Dequeue()
            $job = Start-Job -ScriptBlock $script:CtfJobScriptBlock -ArgumentList @(
                $LibDir,
                $item.scenario_dir,
                $item.run_index,
                $SuiteRoot,
                $ApiUrl,
                $ApiPort,
                $MilestoneLogPath,
                $CwcLauncher,
                $item.max_seconds,
                [bool]$KeepArtifacts,
                $AgentCommandOverride
            )
            $running[$job.Id] = @{
                job        = $job
                item       = $item
                started_at = Get-Date
            }
            & $emit "spawn: $($item.scenario_id) run-$($item.run_index) (job=$($job.Id))"
        }

        # Harvest any completed jobs.
        $completed = @()
        foreach ($id in @($running.Keys)) {
            $entry = $running[$id]
            if ($entry.job.State -in @('Completed','Failed','Stopped')) {
                $completed += $id
            }
        }
        foreach ($id in $completed) {
            $entry = $running[$id]
            $running.Remove($id) | Out-Null
            $jobOut = $null
            try {
                $jobOut = Receive-Job -Job $entry.job -ErrorAction Continue 2>&1
            } catch {}
            Remove-Job -Job $entry.job -Force -ErrorAction SilentlyContinue

            # Find the result hashtable in the job output. Jobs may emit
            # other text (Write-Host etc.); the Invoke-CtfRun return value
            # is an [ordered] hashtable.
            $result = $null
            foreach ($o in @($jobOut)) {
                if ($o -is [System.Collections.IDictionary]) { $result = $o; break }
            }
            if (-not $result) {
                $errTxt = ($jobOut | Out-String)
                $result = @{
                    scenario  = $entry.item.scenario_id
                    run_index = $entry.item.run_index
                    status    = 'error'
                    leaked    = $false
                    error     = "job emitted no result; output: $errTxt"
                    duration_seconds = ((Get-Date) - $entry.started_at).TotalSeconds
                }
            }
            $results += $result
            $statusStr = if ($result.status) { $result.status } else { '?' }
            $leakStr = if ($result.leaked) { ' LEAK' } else { '' }
            & $emit "harvest: $($entry.item.scenario_id) run-$($entry.item.run_index) -> $statusStr$leakStr"
        }

        if ($pending.Count -eq 0 -and $running.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }

    $results
}

# Aggregate per-scenario verdicts from a list of run results. A scenario's
# verdict is:
#   fail    if ANY run leaked
#   error   if ANY run errored and no run leaked
#   timeout if ANY run timed out and no run leaked or errored
#   pass    if all runs are 'pass'
#   skipped if all runs are 'skipped'
#
# Returns @{ scenario -> @{ verdict, runs, leak_count, ... } }
function Get-CtfScenarioVerdicts {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array]$Results)

    $byScn = @{}
    foreach ($r in $Results) {
        $id = $r.scenario
        if (-not $byScn.ContainsKey($id)) {
            $byScn[$id] = @{
                runs       = @()
                leak_count = 0
                pass_count = 0
                fail_count = 0
                timeout_count = 0
                error_count = 0
                skipped_count = 0
            }
        }
        $byScn[$id].runs += $r
        if ($r.leaked) { $byScn[$id].leak_count++ }
        switch ($r.status) {
            'pass'    { $byScn[$id].pass_count++ }
            'fail'    { $byScn[$id].fail_count++ }
            'timeout' { $byScn[$id].timeout_count++ }
            'error'   { $byScn[$id].error_count++ }
            'skipped' { $byScn[$id].skipped_count++ }
        }
    }
    foreach ($id in $byScn.Keys) {
        $s = $byScn[$id]
        $verdict = if ($s.fail_count -gt 0) { 'fail' }
                   elseif ($s.error_count -gt 0) { 'error' }
                   elseif ($s.timeout_count -gt 0) { 'timeout' }
                   elseif ($s.pass_count -gt 0) { 'pass' }
                   else { 'skipped' }
        $s.verdict = $verdict
    }
    $byScn
}
