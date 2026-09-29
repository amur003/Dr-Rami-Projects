@echo off
start "" http://localhost:8787/
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
