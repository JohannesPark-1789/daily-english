@echo off
chcp 65001 >nul
title daily-english - 매일 오전 7시 등록
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\register-task.ps1" %*
echo.
pause
