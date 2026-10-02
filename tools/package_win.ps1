# Package the game as a portable Windows zip (M8).
#
# ASCII ONLY. Windows PowerShell 5.1 reads a BOM-less .ps1 as GBK; any non-ASCII
# literal here would break the parser (see AGENTS.md "known pits").
#
# What it does:
#   1. checks that the Godot export template is installed;
#   2. writes export_presets.cfg (it is git-ignored, so the script owns it);
#   3. exports a release build into export/ocean-s-king/;
#   4. zips that folder into export/ocean-s-king-v0.5-win64.zip
#
# The export template is NOT in the repository. Installing it needs the user's OK
# (about 130 MB download): open Godot -> Editor -> Manage Export Templates ->
# Download and Install. docs/13 section 12 lists this as a decision the user owns.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools/package_win.ps1

param(
    [string]$Godot = 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe',
    [string]$OutDir = 'export'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Output '=== package_win ==='

if (-not (Test-Path -LiteralPath $Godot)) {
    Write-Output "ERROR: Godot not found at $Godot"
    exit 1
}

# --- 1. export template ------------------------------------------------------
$tplRoot = Join-Path $env:APPDATA 'Godot\export_templates'
$tpl = $null
if (Test-Path -LiteralPath $tplRoot) {
    $tpl = Get-ChildItem -Path $tplRoot -Recurse -Filter 'windows_release_x86_64.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
if ($null -eq $tpl) {
    Write-Output 'ERROR: the Windows export template is not installed.'
    Write-Output "       looked under: $tplRoot"
    Write-Output '       Open Godot -> Editor -> Manage Export Templates -> Download and Install.'
    Write-Output '       (This is a ~130 MB download; docs/13 section 12 says the user decides.)'
    exit 2
}
Write-Output "template: $($tpl.FullName)"

# --- 2. export preset -------------------------------------------------------
$preset = @'
[preset.0]

name="Windows Desktop"
platform="Windows Desktop"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path="export/ocean-s-king/ocean-s-king.exe"
encryption_include_filters=""
encryption_exclude_filters=""
encrypt_pck=false
encrypt_directory=false

[preset.0.options]

custom_template/debug=""
custom_template/release=""
debug/export_console_wrapper=0
binary_format/embed_pck=true
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false
codesign/enable=false
application/modify_resources=false
application/icon=""
application/console_wrapper_icon=""
application/icon_interpolation=4
application/file_version=""
application/product_version=""
application/company_name="ocean-s-king"
application/product_name="ocean-s-king"
application/file_description=""
application/copyright=""
application/trademarks=""
'@
Set-Content -LiteralPath (Join-Path $root 'export_presets.cfg') -Value $preset -Encoding ASCII
Write-Output 'wrote export_presets.cfg'

# --- 3. export --------------------------------------------------------------
$target = Join-Path $root $OutDir
$appDir = Join-Path $target 'ocean-s-king'
if (-not (Test-Path -LiteralPath $appDir)) {
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
}
Write-Output 'exporting (this takes a moment)...'
& $Godot --headless --path $root --export-release 'Windows Desktop' (Join-Path $appDir 'ocean-s-king.exe')
if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: export failed with code $LASTEXITCODE"
    exit 3
}

# --- 3.5 the note that ships WITH the game -----------------------------------
# A friend who only gets the zip has no repository to read, so the zip carries its
# own instructions. The text lives in release/player_readme.txt (UTF-8, Chinese) --
# this script stays pure ASCII on purpose (see the header).
$readmeSrc = Join-Path $root 'release\player_readme.txt'
if (Test-Path -LiteralPath $readmeSrc) {
    # Write it as UTF-8 WITH BOM: the file is Chinese, and an old Notepad reads a
    # BOM-less UTF-8 file as ANSI (mojibake). The BOM costs 3 bytes and fixes that.
    $readmeDst = Join-Path $appDir 'PLAY_ME_FIRST.txt'
    $text = [System.IO.File]::ReadAllText($readmeSrc, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($readmeDst, $text, [System.Text.UTF8Encoding]::new($true))
    Write-Output 'added PLAY_ME_FIRST.txt'
} else {
    Write-Output "WARNING: $readmeSrc not found -- the zip will ship without instructions"
}

# --- 4. zip -----------------------------------------------------------------
$zip = Join-Path $target 'ocean-s-king-v0.5-win64.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
# Name the payload instead of globbing the folder: a stray file in export/ (a debug
# screenshot run drops .shots/ there) must never end up in what players download.
$payload = @(Join-Path $appDir 'ocean-s-king.exe')
$readmeDst = Join-Path $appDir 'PLAY_ME_FIRST.txt'
if (Test-Path -LiteralPath $readmeDst) { $payload += $readmeDst }
$angleSrc = Join-Path $root 'release\run_with_angle.cmd'
if (Test-Path -LiteralPath $angleSrc) {
    # Fallback launcher for machines with no OpenGL 3.3 (VMs, old GPUs):
    # asks Godot for the ANGLE/Direct3D 11 backend instead. Stays pure ASCII.
    $angleDst = Join-Path $appDir 'run_with_angle.cmd'
    Copy-Item -LiteralPath $angleSrc -Destination $angleDst -Force
    $payload += $angleDst
    Write-Output 'added run_with_angle.cmd'
}
Compress-Archive -Path $payload -DestinationPath $zip
$mb = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 2)
Write-Output "OK: $zip ($mb MB)"
Write-Output 'Next: upload it to a GitHub Release (docs/13 M8 card).'
