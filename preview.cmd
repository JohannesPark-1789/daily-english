@echo off
chcp 65001 >nul
title daily-english - 미리보기 (발송 안 함)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\send-today.ps1" -DryRun %*
echo.
pause
