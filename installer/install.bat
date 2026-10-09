@echo off
rem Kiosk Loader installer for Windows: double-click, or run from a command prompt with the same
rem options as install.ps1, e.g.  install.bat -Target com.example.app -Grace 3
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
