# tests/ctf/lib/api.ps1 -- milestone HTTP server for CTF runs.
#
# Hosts a tiny HTTP/1.1 server on the test runner that the sandboxed agent
# can POST to from inside its container. Three endpoints:
#
#   GET  /healthz            -> liveness, used by suite startup probe
#   POST /milestone          -> agent self-reports a "I think I made progress"
#   POST /flag               -> agent submits the flag string it believes it found
#
# Both POST endpoints take JSON {run_id, label?, evidence?, flag?} and require
# an X-CTF-Token header. The server logs ALL requests (including bogus tokens
# and 404s) to an append-only JSONL file -- the runner does authn/authz post-
# hoc by matching tokens against the registry it built when launching each run.
# Logging-everything makes it easy to see "agent tried to POST without a token"
# as evidence in the run report.
#
# Why TcpListener and not HttpListener:
#   HttpListener on Windows requires URL ACL registration (netsh http add urlacl)
#   for any non-loopback prefix, which means either elevation or pre-install
#   setup. We need to bind 0.0.0.0 so the Docker container can reach us via
#   host.docker.internal, so HttpListener is out. The 4 endpoints we serve are
#   small enough that hand-rolled HTTP/1.1 parsing is the simpler answer.
#
# Why Start-Job and not Start-ThreadJob or runspaces:
#   Consistency with the watchdog pattern in the rest of the project. PS 5.1
#   ships Start-Job; ThreadJob is a separate module. Each run is on the host
#   so we have PS 7, but uniformity wins.

# Probe TCP ports starting from $PreferredPort until one binds successfully.
# Returns the chosen port. Throws if none of the candidates bind.
function Find-CtfFreePort {
    [CmdletBinding()]
    param(
        [int]$PreferredPort = 17834,
        [int]$Range = 100
    )
    $candidates = @($PreferredPort) + (($PreferredPort + 1)..($PreferredPort + $Range))
    foreach ($p in $candidates) {
        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
            $listener.Start()
            $listener.Stop()
            return $p
        } catch {
            continue
        } finally {
            if ($listener -and $listener.Server -and $listener.Server.IsBound) {
                try { $listener.Stop() } catch {}
            }
        }
    }
    throw "No free port in range $PreferredPort..$($PreferredPort + $Range)"
}

# Start the API server in a background job. Returns the job object; the caller
# stops it via Stop-CtfApiServer. Bind address is 0.0.0.0 so the Docker
# container can reach us via host.docker.internal.
function Start-CtfApiServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Port,
        [Parameter(Mandatory)] [string]$LogPath,
        [Parameter(Mandatory)] [string]$StopSignalPath,
        [string]$BindAddress = '0.0.0.0'
    )

    # Make sure log file exists so the smoke test's first read doesn't race.
    if (-not (Test-Path $LogPath)) {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        }
        [System.IO.File]::WriteAllText($LogPath, '')
    }

    $job = Start-Job -ScriptBlock {
        param($Port, $LogPath, $StopSignalPath, $BindAddress)

        $bind = [System.Net.IPAddress]::Parse($BindAddress)
        $listener = [System.Net.Sockets.TcpListener]::new($bind, $Port)
        $listener.Start()

        # Append a JSON line, retrying briefly on transient sharing violations.
        # The runner reads this file at suite end so we don't need a full
        # write-through, but we do need durability against process crash.
        $writeJsonl = {
            param($obj, $path)
            $json = ($obj | ConvertTo-Json -Compress -Depth 10)
            $line = $json + [Environment]::NewLine
            for ($i = 0; $i -lt 5; $i++) {
                try {
                    [System.IO.File]::AppendAllText($path, $line)
                    return
                } catch {
                    Start-Sleep -Milliseconds 50
                }
            }
        }

        try {
            while (-not (Test-Path $StopSignalPath)) {
                if (-not $listener.Pending()) {
                    Start-Sleep -Milliseconds 100
                    continue
                }
                $client = $null
                try {
                    $client = $listener.AcceptTcpClient()
                    $client.ReceiveTimeout = 5000
                    $client.SendTimeout    = 5000
                    $stream = $client.GetStream()

                    # Read raw bytes until end of headers (CRLF CRLF), then read
                    # exactly Content-Length bytes for the body. Parsing in two
                    # phases (text headers, byte body) keeps multibyte payloads
                    # honest.
                    $headerBytes = New-Object 'System.Collections.Generic.List[byte]'
                    $buf = New-Object byte[] 1
                    $found = $false
                    while ($headerBytes.Count -lt 16384) {
                        $n = $stream.Read($buf, 0, 1)
                        if ($n -le 0) { break }
                        $headerBytes.Add($buf[0])
                        if ($headerBytes.Count -ge 4) {
                            $c = $headerBytes.Count
                            if ($headerBytes[$c-4] -eq 13 -and $headerBytes[$c-3] -eq 10 -and
                                $headerBytes[$c-2] -eq 13 -and $headerBytes[$c-1] -eq 10) {
                                $found = $true
                                break
                            }
                        }
                    }
                    if (-not $found) {
                        # Malformed; ignore and close.
                        continue
                    }

                    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
                    $headerLines = $headerText -split "`r`n"
                    $requestLine = $headerLines[0]
                    $parts = $requestLine -split ' '
                    if ($parts.Length -lt 2) { continue }
                    $method = $parts[0]
                    $path   = $parts[1]

                    $headers = @{}
                    for ($i = 1; $i -lt $headerLines.Length; $i++) {
                        $h = $headerLines[$i]
                        if ([string]::IsNullOrWhiteSpace($h)) { continue }
                        $idx = $h.IndexOf(':')
                        if ($idx -le 0) { continue }
                        $key = $h.Substring(0, $idx).Trim().ToLowerInvariant()
                        $val = $h.Substring($idx + 1).Trim()
                        $headers[$key] = $val
                    }

                    $contentLength = 0
                    if ($headers.ContainsKey('content-length')) {
                        [int]::TryParse($headers['content-length'], [ref]$contentLength) | Out-Null
                    }

                    $body = ''
                    if ($contentLength -gt 0 -and $contentLength -lt 1048576) {
                        $bodyBuf = New-Object byte[] $contentLength
                        $read = 0
                        while ($read -lt $contentLength) {
                            $r = $stream.Read($bodyBuf, $read, $contentLength - $read)
                            if ($r -le 0) { break }
                            $read += $r
                        }
                        if ($read -gt 0) {
                            $body = [System.Text.Encoding]::UTF8.GetString($bodyBuf, 0, $read)
                        }
                    }

                    # Routing.
                    $status = '200 OK'
                    $respBody = '{"ok":true}'

                    if ($method -eq 'GET' -and $path -eq '/healthz') {
                        $respBody = '{"status":"ok"}'
                    } elseif ($method -eq 'POST' -and ($path -eq '/milestone' -or $path -eq '/flag')) {
                        $event = [ordered]@{
                            received_at = (Get-Date).ToUniversalTime().ToString('o')
                            endpoint    = $path.TrimStart('/')
                            method      = $method
                            token       = if ($headers.ContainsKey('x-ctf-token')) { $headers['x-ctf-token'] } else { $null }
                            client      = $client.Client.RemoteEndPoint.ToString()
                            body_raw    = $body
                        }
                        try {
                            $parsed = $body | ConvertFrom-Json -ErrorAction Stop
                            $event['parsed'] = $parsed
                        } catch {
                            $event['parse_error'] = $_.Exception.Message
                        }
                        & $writeJsonl $event $LogPath
                    } else {
                        $status = '404 Not Found'
                        $respBody = '{"error":"not_found"}'
                        # Log the unrecognized hit too -- useful evidence if the
                        # agent probes endpoints we didn't expect.
                        $event = [ordered]@{
                            received_at = (Get-Date).ToUniversalTime().ToString('o')
                            endpoint    = '_other'
                            method      = $method
                            path        = $path
                            client      = $client.Client.RemoteEndPoint.ToString()
                        }
                        & $writeJsonl $event $LogPath
                    }

                    $respBytes  = [System.Text.Encoding]::UTF8.GetBytes($respBody)
                    $headerStr  = "HTTP/1.1 $status`r`n"
                    $headerStr += "Content-Type: application/json`r`n"
                    $headerStr += "Content-Length: $($respBytes.Length)`r`n"
                    $headerStr += "Connection: close`r`n`r`n"
                    $headerOut  = [System.Text.Encoding]::ASCII.GetBytes($headerStr)
                    $stream.Write($headerOut, 0, $headerOut.Length)
                    $stream.Write($respBytes, 0, $respBytes.Length)
                    $stream.Flush()
                } catch {
                    # Single bad request shouldn't kill the listener.
                    $errEvent = [ordered]@{
                        received_at = (Get-Date).ToUniversalTime().ToString('o')
                        endpoint    = '_error'
                        error       = $_.Exception.Message
                    }
                    try { & $writeJsonl $errEvent $LogPath } catch {}
                } finally {
                    if ($client) { try { $client.Close() } catch {} }
                }
            }
        } finally {
            try { $listener.Stop() } catch {}
        }
    } -ArgumentList $Port, $LogPath, $StopSignalPath, $BindAddress

    return $job
}

# Stop the API server cleanly: drop the stop-signal file (which the job's
# accept loop polls between connections), wait briefly for graceful exit,
# then force-stop if it's still running.
function Stop-CtfApiServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Job,
        [Parameter(Mandatory)] [string]$StopSignalPath
    )
    [System.IO.File]::WriteAllText($StopSignalPath, 'stop')
    Wait-Job -Job $Job -Timeout 3 | Out-Null
    if ($Job.State -eq 'Running') {
        Stop-Job -Job $Job -ErrorAction SilentlyContinue
    }
    # Drain any output (mostly errors from the job) so Remove-Job doesn't warn.
    Receive-Job -Job $Job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
}
