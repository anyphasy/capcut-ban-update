@echo off
setlocal
cd /d "%~dp0"

if not exist "%~dp0capcut_ban_update.ps1" (
    echo [x] capcut_ban_update.ps1 not found next to this bat.
    pause
    exit /b 1
)

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo [*] Elevation required - requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo [*] Blocking CapCut auto-update ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0capcut_ban_update.ps1"

echo.
pause
