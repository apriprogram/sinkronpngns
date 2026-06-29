$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 5300
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
$utf8 = [System.Text.Encoding]::UTF8
$jobs = @{
  ma = @{ Name = "SIPP Mahkamah Agung"; Dir = Join-Path $root "sinkron_ma"; Bat = "SYNCRON_530.bat"; Log = "job.log"; Process = $null }
  pt = @{ Name = "SIPP Pengadilan Tinggi Tanjung Karang"; Dir = Join-Path $root "sinkron_pt"; Bat = "EXSEC_PT_II.bat"; Log = "job.log"; Process = $null }
}
function Get-RequestInfo {
  param([System.IO.StreamReader]$Reader)
  $requestLine = $Reader.ReadLine()
  if (-not $requestLine) { return $null }
  while ($true) { $line = $Reader.ReadLine(); if ($null -eq $line -or $line -eq "") { break } }
  $parts = $requestLine.Split(" ")
  if ($parts.Count -lt 2) { return $null }
  $rawUrl = $parts[1]
  $path = $rawUrl
  $query = @{}
  $queryIndex = $rawUrl.IndexOf("?")
  if ($queryIndex -ge 0) {
    $path = $rawUrl.Substring(0, $queryIndex)
    $queryString = $rawUrl.Substring($queryIndex + 1)
    foreach ($pair in $queryString.Split("&", [System.StringSplitOptions]::RemoveEmptyEntries)) {
      $kv = $pair.Split("=", 2)
      $key = [System.Uri]::UnescapeDataString($kv[0])
      $value = ""
      if ($kv.Count -gt 1) { $value = [System.Uri]::UnescapeDataString($kv[1]) }
      $query[$key] = $value
    }
  }
  return @{ Path = $path; Query = $query }
}
function Write-Response {
  param([System.Net.Sockets.TcpClient]$Client, [byte[]]$Body, [string]$ContentType = "text/plain; charset=utf-8", [int]$StatusCode = 200, [string]$StatusText = "OK")
  $stream = $Client.GetStream()
  $header = "HTTP/1.1 $StatusCode $StatusText`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
  $headerBytes = $utf8.GetBytes($header)
  $stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($Body.Length -gt 0) { $stream.Write($Body, 0, $Body.Length) }
}
function Write-Text {
  param([System.Net.Sockets.TcpClient]$Client, [string]$Text, [string]$ContentType = "text/plain; charset=utf-8", [int]$StatusCode = 200, [string]$StatusText = "OK")
  Write-Response -Client $Client -Body ($utf8.GetBytes($Text)) -ContentType $ContentType -StatusCode $StatusCode -StatusText $StatusText
}
function Write-Json {
  param([System.Net.Sockets.TcpClient]$Client, [hashtable]$Data, [int]$StatusCode = 200, [string]$StatusText = "OK")
  Write-Text -Client $Client -Text ($Data | ConvertTo-Json -Compress -Depth 4) -ContentType "application/json; charset=utf-8" -StatusCode $StatusCode -StatusText $StatusText
}
function Get-Target {
  param([hashtable]$Query)
  if (-not $Query.ContainsKey("target")) { return $null }
  $target = $Query["target"].ToLowerInvariant()
  if (-not $jobs.ContainsKey($target)) { return $null }
  return $target
}
function Get-RecentLog {
  param([string]$Path, [int]$Lines = 80)
  if (-not (Test-Path -LiteralPath $Path)) { return @("Log belum tersedia.") }
  return @(Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ })
}
$listener.Start()
Write-Host "SIPP Sync server berjalan di http://localhost:$port/"
Write-Host "Tekan Ctrl+C untuk menghentikan server."
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $reader = [System.IO.StreamReader]::new($stream, $utf8, $false, 4096, $true)
      $request = Get-RequestInfo -Reader $reader
      if (-not $request) { Write-Text -Client $client -Text "Bad request." -StatusCode 400 -StatusText "Bad Request"; continue }
      $path = $request.Path
      if ($path -eq "/" -or $path -eq "/index.html") {
        Write-Text -Client $client -Text (Get-Content -LiteralPath (Join-Path $root "index.html") -Raw) -ContentType "text/html; charset=utf-8"
        continue
      }
      if ($path.StartsWith("/img/")) {
        $fileName = [System.IO.Path]::GetFileName($path)
        $filePath = Join-Path (Join-Path $root "img") $fileName
        if (-not (Test-Path -LiteralPath $filePath)) { Write-Text -Client $client -Text "File tidak ditemukan." -StatusCode 404 -StatusText "Not Found"; continue }
        Write-Response -Client $client -Body ([System.IO.File]::ReadAllBytes($filePath)) -ContentType "image/png"
        continue
      }
      if ($path -eq "/api/run") {
        $target = Get-Target -Query $request.Query
        if (-not $target) { Write-Json -Client $client -Data @{ ok = $false; error = "Target tidak dikenal." } -StatusCode 400 -StatusText "Bad Request"; continue }
        $job = $jobs[$target]
        $batPath = Join-Path $job.Dir $job.Bat
        if (-not (Test-Path -LiteralPath $batPath)) { Write-Json -Client $client -Data @{ ok = $false; error = "File batch tidak ditemukan: $batPath" } -StatusCode 404 -StatusText "Not Found"; continue }
        if ($job.Process -and -not $job.Process.HasExited) { Write-Json -Client $client -Data @{ ok = $true; running = $true; message = "Sinkronisasi masih berjalan."; name = $job.Name }; continue }
        $logPath = Join-Path $job.Dir $job.Log
        if (Test-Path -LiteralPath $logPath) { Clear-Content -LiteralPath $logPath -ErrorAction SilentlyContinue }
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$batPath`"" -WorkingDirectory $job.Dir -PassThru
        $jobs[$target].Process = $process
        Write-Json -Client $client -Data @{ ok = $true; running = $true; message = "Sinkronisasi dimulai."; name = $job.Name }
        continue
      }
      if ($path -eq "/api/log") {
        $target = Get-Target -Query $request.Query
        if (-not $target) { Write-Json -Client $client -Data @{ ok = $false; error = "Target tidak dikenal." } -StatusCode 400 -StatusText "Bad Request"; continue }
        $job = $jobs[$target]
        $running = $false
        if ($job.Process) { $running = -not $job.Process.HasExited }
        $logPath = Join-Path $job.Dir $job.Log
        Write-Json -Client $client -Data @{ ok = $true; running = $running; name = $job.Name; lines = @(Get-RecentLog -Path $logPath) }
        continue
      }
      Write-Text -Client $client -Text "Not found." -StatusCode 404 -StatusText "Not Found"
    } catch {
      try { Write-Json -Client $client -Data @{ ok = $false; error = $_.Exception.Message } -StatusCode 500 -StatusText "Internal Server Error" } catch {}
    } finally {
      $client.Close()
    }
  }
} finally {
  $listener.Stop()
}
