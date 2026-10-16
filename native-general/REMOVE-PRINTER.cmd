@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0queue-setup.ps1" -Action Remove
set "SCX4200_QUEUE_EXIT=%errorlevel%"
pause
exit /b %SCX4200_QUEUE_EXIT%
