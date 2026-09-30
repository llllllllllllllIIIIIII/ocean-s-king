# Download the Godot 4.7.2 portable build for Windows.
#
# NOTE: this file is deliberately ASCII-only. Windows PowerShell 5.1 reads
# .ps1 files as ANSI (GBK on Chinese Windows) when there is no UTF-8 BOM,
# which corrupts non-ASCII string literals and breaks the parser.
#
# Why not just download directly: a single connection to GitHub is often
# throttled well below 50 KB/s here (82 MB would take ~28 minutes).
# This script uses N parallel range requests, then verifies the result
# against the official SHA512 and refuses to extract on mismatch.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools/fetch_godot.ps1
#   powershell -ExecutionPolicy Bypass -File tools/fetch_godot.ps1 -Dest D:\Godot -Connections 8

param(
    [string]$Dest        = 'D:\Godot',
    [int]   $Connections = 8,
    [string]$WorkDir     = (Join-Path $env:TEMP 'godot_fetch'),
    [string]$Mirror      = ''      # e.g. https://gh-proxy.com/ if direct is blocked
)

$ErrorActionPreference = 'Stop'

$version = '4.7.2-stable'
$file    = 'Godot_v4.7.2-stable_win64.exe.zip'
$url     = "${Mirror}https://github.com/godotengine/godot/releases/download/$version/$file"
$sha512Fallback = '83decd58fdf67b9d657958a1ae6bf1929c20785315a81effe245874cdc57acb709bf868e00778a96984338c1b29dafdb453c6847747694621c6ecf5da2259993'
$size           = 86013866

# Pull the official checksum list rather than trusting a hard-coded constant.
# (A truncated copy-paste of this hash once caused a false failure, so the
# script now self-corrects and only falls back if the list can't be fetched.)
$sha512 = $sha512Fallback
try {
    $sumsUrl  = "${Mirror}https://github.com/godotengine/godot/releases/download/$version/SHA512-SUMS.txt"
    $sumsPath = Join-Path $env:TEMP 'godot_sha512_sums.txt'
    curl.exe -L --max-time 60 -s -o $sumsPath $sumsUrl
    $line = Get-Content -LiteralPath $sumsPath |
            Where-Object { $_ -match [regex]::Escape($file) -and $_ -notmatch 'mono' } |
            Select-Object -First 1
    if ($line) {
        $sha512 = ($line -split '\s+')[0].Trim().ToLower()
        Write-Host "checksum loaded from release SHA512-SUMS.txt"
    }
} catch {
    Write-Host "could not fetch SHA512-SUMS.txt, using built-in checksum"
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
New-Item -ItemType Directory -Path $Dest    -Force | Out-Null

$chunk  = [int][math]::Ceiling($size / $Connections)
$ranges = @()
for ($i = 0; $i -lt $Connections; $i++) {
    $start = $i * $chunk
    $end   = [math]::Min($start + $chunk - 1, $size - 1)
    if ($start -gt $end) { break }
    $ranges += [pscustomobject]@{
        Index    = $i
        Start    = $start
        End      = $end
        Expected = $end - $start + 1
        Path     = (Join-Path $WorkDir ('part{0:D2}.bin' -f $i))
    }
}

function Test-Part($r) {
    (Test-Path -LiteralPath $r.Path) -and
    ((Get-Item -LiteralPath $r.Path).Length -eq $r.Expected)
}

function Start-Chunk($r) {
    $curlArgs = @('-L', '--max-time', '3600', '-s', '--retry', '5', '--retry-all-errors',
                  '--connect-timeout', '20', '-r', "$($r.Start)-$($r.End)", '-o', $r.Path, $url)
    Start-Process -FilePath 'curl.exe' -ArgumentList $curlArgs -PassThru -NoNewWindow
}

# Round 1: parallel. Chunks that already exist and are complete are skipped,
# so re-running this script resumes instead of starting over.
$todo = @($ranges | Where-Object { -not (Test-Part $_) })
Write-Host ("chunks total = {0}, already done = {1}, to fetch = {2}" -f `
            $ranges.Count, ($ranges.Count - $todo.Count), $todo.Count)

if ($todo.Count -gt 0) {
    $procs = @($todo | ForEach-Object { Start-Chunk $_ })
    Write-Host ("started {0} connections, target {1} MB ..." -f `
                $procs.Count, [math]::Round($size / 1MB, 1))
    $procs | ForEach-Object { $_.WaitForExit() }
}

# Retry rounds: parallel runs occasionally get a connection reset, which
# silently yields a short or empty chunk. Fetch those one at a time.
for ($attempt = 1; $attempt -le 6; $attempt++) {
    $bad = @($ranges | Where-Object { -not (Test-Part $_) })
    if ($bad.Count -eq 0) { break }
    Write-Host ("retry {0}: {1} chunk(s) left -> {2}" -f `
                $attempt, $bad.Count, (($bad | ForEach-Object { $_.Index }) -join ', '))
    foreach ($r in $bad) {
        if (Test-Path -LiteralPath $r.Path) { [System.IO.File]::Delete($r.Path) }
        $p = Start-Chunk $r
        $p.WaitForExit()
    }
}

$still = @($ranges | Where-Object { -not (Test-Part $_) })
if ($still.Count -gt 0) {
    throw "chunks failed: $((($still | ForEach-Object { $_.Index }) -join ', '))"
}

# Concatenate
$zip = Join-Path $WorkDir $file
$fs  = [System.IO.File]::Create($zip)
try {
    foreach ($r in $ranges) {
        $bytes = [System.IO.File]::ReadAllBytes($r.Path)
        $fs.Write($bytes, 0, $bytes.Length)
    }
} finally { $fs.Close() }

$got = (Get-FileHash -LiteralPath $zip -Algorithm SHA512).Hash.ToLower()
if ($got -ne $sha512) {
    throw "SHA512 mismatch, aborting (do NOT run this binary): got $got"
}
Write-Host 'SHA512 verified OK'

Expand-Archive -LiteralPath $zip -DestinationPath $Dest -Force
Write-Host "extracted to $Dest"
Get-ChildItem -LiteralPath $Dest | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
