@echo off
chcp 65001 >nul
title daily-english - 지금 보내기
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\send-today.ps1" -Force %*
echo.
pause
