@echo off
chcp 65001 >nul
title daily-english - 번역 검수 파일 만들기
echo.
echo  data\review.csv 를 만들고 Excel 로 엽니다.
echo  "한글" 열만 고치고 저장하세요 (CSV 형식 유지).
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\export-review.ps1" %*
if exist "%~dp0data\review.csv" start "" "%~dp0data\review.csv"
echo.
pause
