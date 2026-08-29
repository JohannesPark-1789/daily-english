@echo off
chcp 65001 >nul
title daily-english - 진단 (동의항목 없이 인증만)
echo.
echo  동의항목(scope) 없이 인증만 시도합니다.
echo  이게 통과하면 "앱 관리자 설정 오류" 의 원인은 talk_message 동의항목입니다.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-auth.ps1" -NoScope -NoTestMessage
echo.
pause
