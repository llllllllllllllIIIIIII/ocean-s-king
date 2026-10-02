@echo off
REM ============================================================
REM  Ocean's King -- fallback launcher (ANGLE / Direct3D 11)
REM
REM  Use this ONLY if the normal ocean-s-king.exe fails to start or
REM  shows a black screen -- typically inside a virtual machine or on
REM  a GPU whose OpenGL driver is older than 3.3.
REM
REM  The game normally renders with native OpenGL 3.3. This launcher
REM  asks Godot for the ANGLE backend instead, which goes through
REM  Direct3D 11 (and can fall back to the software WARP device).
REM  ANGLE is compiled into the exe -- there is nothing extra to install.
REM
REM  ASCII only on purpose: cmd.exe on a Chinese Windows reads
REM  .cmd/.bat as GBK, and non-ASCII characters corrupt the parser.
REM ============================================================

echo Starting with the ANGLE (Direct3D 11) renderer...
start "" "%~dp0ocean-s-king.exe" --rendering-driver opengl3_angle
