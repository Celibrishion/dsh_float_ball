@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-apply.ps1"
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
  echo   [OK] Patch applied. You may start DSH now.
  echo   Test: close DSH to tray, then click the floating ball.
) else (
  echo   [FAILED] exit %RC% ^- see messages above.
  echo   Nothing was left half-modified; you can run this again.
)
echo.
echo   Note: DSH nightly updates overwrite app.asar; re-run this after each update.
echo.
pause
endlocal