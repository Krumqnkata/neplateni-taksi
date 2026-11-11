# Tiny local server for Neplateni.html - serves the page and saves the data to danni.json.
# Started by Start.bat. Listens only on this computer (127.0.0.1).
# Stops by itself about 10 minutes after the page is closed.
param([switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
$port    = 47123
$url     = "http://127.0.0.1:$port/"
$dir     = $PSScriptRoot
$page    = Join-Path $dir 'Neplateni.html'
$data    = Join-Path $dir 'danni.json'
$archive = Join-Path $dir 'arhiv'
$latin1  = [Text.Encoding]::GetEncoding(28591)

try {
    $listener = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, $port)
    $listener.Start()
} catch {
    # Already running - just open the page.
    if (-not $NoBrowser) { Start-Process $url }
    exit
}
if (-not $NoBrowser) { Start-Process $url }

function Send-Response($stream, [int]$code, [string]$type, [byte[]]$body) {
    if ($null -eq $body) { $body = [byte[]]@() }
    $reason = @{ 200 = 'OK'; 204 = 'No Content'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Server Error' }[$code]
    $head = "HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $h = [Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($h, 0, $h.Length)
    if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
}

function Save-Data([byte[]]$body) {
    if (Test-Path -LiteralPath $data) {
        # Keep one copy per day (the state before the first change of the day).
        if (-not (Test-Path -LiteralPath $archive)) { New-Item -ItemType Directory -Path $archive | Out-Null }
        $daily = Join-Path $archive ('danni-' + (Get-Date -Format 'yyyy-MM-dd') + '.json')
        if (-not (Test-Path -LiteralPath $daily)) { Copy-Item -LiteralPath $data -Destination $daily }
    }
    $tmp = "$data.tmp"
    [IO.File]::WriteAllBytes($tmp, $body)
    if (Test-Path -LiteralPath $data) { [IO.File]::Replace($tmp, $data, [NullString]::Value) } else { [IO.File]::Move($tmp, $data) }
}

function Handle-Client($client) {
    $stream = $client.GetStream()
    try {
        $ms  = New-Object IO.MemoryStream
        $buf = New-Object byte[] 65536
        $headerEnd = -1
        while ($headerEnd -lt 0) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { return }
            $ms.Write($buf, 0, $n)
            $headerEnd = $latin1.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
        }
        $lines = $latin1.GetString($ms.ToArray(), 0, $headerEnd) -split "`r`n"
        $parts = $lines[0].Split(' ')
        $method = $parts[0]
        $path = $parts[1].Split('?')[0]
        $headers = @{}
        foreach ($l in ($lines | Select-Object -Skip 1)) {
            $i = $l.IndexOf(':')
            if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLower()] = $l.Substring($i + 1).Trim() }
        }
        $len = 0
        if ($headers['content-length']) { $len = [int]$headers['content-length'] }
        if ($len -gt 20MB) { Send-Response $stream 400 'text/plain' $null; return }
        $bodyStart = $headerEnd + 4
        while ($ms.Length -lt $bodyStart + $len) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        $raw  = $ms.ToArray()
        $body = New-Object byte[] $len
        [Array]::Copy($raw, $bodyStart, $body, 0, [Math]::Min($len, $raw.Length - $bodyStart))

        # Only answer requests addressed to this server (blocks other websites).
        if (@("127.0.0.1:$port", "localhost:$port") -notcontains $headers['host']) {
            Send-Response $stream 403 'text/plain' $null
        } elseif ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/Neplateni.html')) {
            Send-Response $stream 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($page))
        } elseif ($method -eq 'GET' -and $path -eq '/api/data') {
            if (Test-Path -LiteralPath $data) { $b = [IO.File]::ReadAllBytes($data) } else { $b = [Text.Encoding]::ASCII.GetBytes('null') }
            Send-Response $stream 200 'application/json; charset=utf-8' $b
        } elseif ($method -eq 'POST' -and $path -eq '/api/data') {
            if ($headers['x-neplateni'] -ne '1' -or $len -lt 2 -or $body[0] -ne 123) {
                Send-Response $stream 400 'text/plain' $null
            } else {
                Save-Data $body
                Send-Response $stream 204 'text/plain' $null
            }
        } elseif ($path -eq '/api/ping') {
            Send-Response $stream 204 'text/plain' $null
        } else {
            Send-Response $stream 404 'text/plain' $null
        }
    } catch {
        try { Send-Response $stream 500 'text/plain' $null } catch {}
    }
}

$clients  = New-Object System.Collections.ArrayList
$lastSeen = Get-Date
while ($true) {
    while ($listener.Pending()) {
        $c = $listener.AcceptTcpClient()
        $c.ReceiveTimeout = 3000
        [void]$clients.Add([pscustomobject]@{ c = $c; t = Get-Date })
        $lastSeen = Get-Date
    }
    $busy = $false
    foreach ($e in @($clients)) {
        if ($e.c.Available -gt 0) {
            Handle-Client $e.c
            $e.c.Close(); $clients.Remove($e); $busy = $true
        } elseif (((Get-Date) - $e.t).TotalSeconds -gt 10) {
            $e.c.Close(); $clients.Remove($e)
        }
    }
    if (-not $busy) {
        if ($clients.Count -eq 0 -and ((Get-Date) - $lastSeen).TotalMinutes -ge 10) { break }
        Start-Sleep -Milliseconds 30
    }
}
$listener.Stop()
