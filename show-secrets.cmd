@echo off
chcp 65001 >nul
title daily-english - GitHub Secrets 에 넣을 값 보기
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\show-secrets.ps1"
pause
