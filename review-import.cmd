@echo off
chcp 65001 >nul
title daily-english - 검수 결과 반영
echo.
echo  Excel 에서 고친 data\review.csv 를 번역 파일에 반영하고,
echo  카드 페이지를 다시 빌드합니다. (반영 전 백업됩니다)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\import-review.ps1" %*
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-web.ps1"
echo.
echo  변경을 사이트에 올리려면:  git add -A ^&^& git commit -m "번역 검수" ^&^& git push
echo.
pause
