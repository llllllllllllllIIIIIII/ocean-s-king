@echo off
REM ============================================================
REM  Ocean's King  --  open the layered ship debug view
REM  Just double-click this file.
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

echo Launching ship debug view...
start "" "%GODOT%" --path "%~dp0" res://scenes/ship_debug.tscn
