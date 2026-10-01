@echo off
REM ============================================================
REM  Ocean's King  --  start a voyage (the playable scene)
REM  Just double-click this file.
REM
REM  Controls:
REM    left click  set target point / lead the party ashore
REM    X anchor   1/2/3 sail level   +/- hands on sails
REM    L land / return to ship      .  fast-forward one minute
REM    Tab sail panel   C crew panel   wheel zoom
REM
REM  ASCII only on purpose: cmd.exe on a Chinese Windows reads
REM  .cmd/.bat as GBK, and non-ASCII characters corrupt the parser.
REM ============================================================

set "GODOT=D:\Godot\Godot_v4.7.2-stable_win64.exe"

if not exist "%GODOT%" (
    echo [ERROR] Godot not found at "%GODOT%"
    echo Edit this file and point GODOT at your Godot executable.
    pause
    exit /b 1
)

echo Starting a voyage...
start "" "%GODOT%" --path "%~dp0" res://scenes/sea_debug.tscn
