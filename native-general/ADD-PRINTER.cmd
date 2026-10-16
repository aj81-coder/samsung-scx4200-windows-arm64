@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0queue-setup.ps1" -Action Install
set "SCX4200_QUEUE_EXIT=%errorlevel%"
pause
exit /b %SCX4200_QUEUE_EXIT%
