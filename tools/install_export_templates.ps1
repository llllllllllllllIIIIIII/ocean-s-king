# Download and install the Godot export templates (the prerequisite for M8 packaging).
#
# ASCII ONLY. Windows PowerShell 5.1 reads a BOM-less .ps1 as GBK; any non-ASCII
# literal here would break the parser (see AGENTS.md "known pits").
#
# Why a script and not "open the editor and click Download":
#   * the .tpz is ~1.2 GB and github.com:443 is flaky on this line, so the download
#     must be RESUMABLE and RETRYING (curl -C - in a loop);
#   * we only need the Windows templates, so we pull just those members out of the
#     zip instead of expanding the whole thing.
#
# What it does:
#   1. downloads Godot_v<Version>_export_templates.tpz to %TEMP% (resumable, retrying);
#   2. extracts templates/windows_release_x86_64.exe, windows_debug_x86_64.exe
#      and templates/version.txt;
#   3. installs them into %APPDATA%\Godot\export_templates\<dotted version>\
#      (that is where the editor looks, e.g. 4.7.2.stable).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools/install_export_templates.ps1

param(
    [string]$Version = '4.7.2-stable',
    [string]$Url = '',
    [string]$Tpz = '',
    [switch]$DownloadOnly
)

$ErrorActionPreference = 'Stop'

if ($Url -eq '') {
    $Url = 'https://github.com/godotengine/godot/releases/download/' + $Version +
        '/Godot_v' + $Version + '_export_templates.tpz'
}
if ($Tpz -eq '') {
    $Tpz = Join-Path $env:TEMP 'godot_export_templates.tpz'
}

Write-Output '=== install_export_templates ==='
Write-Output "url: $Url"
Write-Output "file: $Tpz"

# --- 1. download (resume + retry) -------------------------------------------
$tries = 0
while ($true) {
    $tries += 1
    $size = 0
    if (Test-Path -LiteralPath $Tpz) { $size = (Get-Item -LiteralPath $Tpz).Length }
    Write-Output ('[tpl] attempt {0}: resuming at {1:N1} MB' -f $tries, ($size / 1MB))
    & curl.exe -L -C - --retry 3 --retry-delay 5 --connect-timeout 25 -o $Tpz $Url
    $code = $LASTEXITCODE
    if ($code -eq 0) { break }
    if ($code -eq 33) {
        # 33 = the server cannot resume. Start over from zero (delete the partial).
        Write-Output '[tpl] server refused to resume; starting over'
        Remove-Item -LiteralPath $Tpz -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 45
}
$total = (Get-Item -LiteralPath $Tpz).Length
Write-Output ('[tpl] downloaded {0:N1} MB' -f ($total / 1MB))
if ($DownloadOnly) { exit 0 }

# --- 2. pull just the Windows templates -------------------------------------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($Tpz)
$want = @{}
foreach ($e in $zip.Entries) {
    if ($e.FullName -match '^templates/(version\.txt|windows_(release|debug)_x86_64\.exe)$') {
        $want[$e.FullName] = $e
    }
}
if ($want.Count -lt 2) {
    $zip.Dispose()
    Write-Output "ERROR: the .tpz does not look like Godot's template pack (found $($want.Count) members)."
    exit 2
}

# --- 3. install into %APPDATA%\Godot\export_templates\<dotted version> -------
$dotted = ($Version -replace '-', '.')
$dest = Join-Path (Join-Path $env:APPDATA 'Godot\export_templates') $dotted
if (-not (Test-Path -LiteralPath $dest)) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
}
foreach ($name in $want.Keys) {
    $short = Split-Path $name -Leaf
    $out = Join-Path $dest $short
    $src = $want[$name].Open()
    $dst = [System.IO.File]::Create($out)
    $src.CopyTo($dst)
    $dst.Close()
    $src.Close()
    Write-Output ('[tpl] installed {0} ({1:N1} MB)' -f $short, ((Get-Item -LiteralPath $out).Length / 1MB))
}
$zip.Dispose()
Write-Output "OK: templates installed into $dest"
Write-Output 'Next: powershell -ExecutionPolicy Bypass -File tools/package_win.ps1'
