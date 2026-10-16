@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-rollback.ps1"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo   [OK] Rolled back. You may start DSH.) else (echo   [FAILED] exit %RC% - see messages above.)
echo.
pause
endlocal