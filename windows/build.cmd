@echo off
rem Runs build.ps1 without changing the PC's script policy; arguments pass through (e.g. build.cmd -Test).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
if errorlevel 1 (echo Build failed.) else (echo Done: %~dp0dist\CleanUpMusic-win-x64.zip)
if "%~1"=="" pause
