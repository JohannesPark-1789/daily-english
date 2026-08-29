@echo off
chcp 65001 >nul
title daily-english - 카카오 인증 (최초 1회)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-auth.ps1"
echo.
pause
