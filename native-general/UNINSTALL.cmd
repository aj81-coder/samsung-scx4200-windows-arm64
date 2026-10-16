@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
set "SCX4200_SETUP_EXIT=%errorlevel%"
if not "%SCX4200_SETUP_EXIT%"=="0" (echo Removal did not complete. Keep the messages above for diagnosis.)
pause
exit /b %SCX4200_SETUP_EXIT%
