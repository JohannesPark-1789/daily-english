@echo off
chcp 65001 >nul
title daily-english - 설명 반영하기
echo.
echo  data\notes\*.md 의 설명을 읽어 번호에 붙이고, 카드와 목록을 다시 만든 뒤
echo  사이트에 올립니다.
echo.
echo  [1/3] 설명 읽기
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\import-notes.ps1" %*
if errorlevel 1 goto :fail

echo  [2/3] 카드 빌드
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-web.ps1"
if errorlevel 1 goto :fail

echo  [3/3] 사이트 반영
pushd "%~dp0"
git add -A
git diff --cached --quiet && (echo   바뀐 것이 없어 커밋하지 않았습니다.) || (
  git commit -q -m "docs(daily-english): 상세 설명 갱신" && git push -q origin main && echo   푸시 완료
)
popd
echo.
echo  끝났습니다. 반영에 1~2분 걸립니다:
echo    https://johannespark-1789.github.io/daily-english/
echo.
pause
exit /b 0

:fail
echo.
echo  중간에 실패했습니다. 위 메시지를 확인하세요.
echo.
pause
exit /b 1
