@echo off
cd /d "%~dp0"
netstat -ano | find ":5300" >nul
if errorlevel 1 (
  start "SIPP Sync Server" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
  timeout /t 1 /nobreak >nul
)
start "" "http://localhost:5300/"