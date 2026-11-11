@echo off
rem Starts the program and opens it in your browser. Data is saved to danni.json in this folder.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0server.ps1"
