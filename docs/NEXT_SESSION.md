# 다음 세션 인계 메모

> 최종 갱신: 2026-10-25

## 지금 상태

- 발송은 **GitHub Actions** 가 한다 (2026-10-24 이관). 로컬 작업 스케줄러는 Disabled.
- 문장 235개 중 **049 까지 나갔다**. 다음은 050, 예약은 10-26(월) 07:00 KST.
- 복습 카드는 GitHub Pages: https://johannespark-1789.github.io/daily-english/
- **2026-10-25 22:55 Actions 첫 발송 성공** (주간 복습 045~049 재발송, run 40199787377).
- Secret 4개 전부 등록됨. **평일 경로의 첫 실전은 10-26(월) 07:00** 이다.

## 끝난 작업 (2026-10-25)

### 1. Secret 두 개 미등록 — ✅ 등록 완료

`KAKAO_REFRESH_TOKEN` 과 `GH_PAT` 이 없다. 전자가 없으면 **발송 자체가 안 된다.**

```powershell
# 갱신 토큰 — 로컬 tokens.json 에서 바로 (값이 화면에 찍히지 않는다)
$t = Get-Content state	okens.json -Raw | ConvertFrom-Json
gh secret set KAKAO_REFRESH_TOKEN --body $t.refresh_token

# GitHub PAT — github.com/settings/tokens 에서 repo 권한으로 발급 후
gh secret set GH_PAT
```

- 로컬 refresh token 은 **2026-12-21 까지 유효**하다. 그 전에 넣으면 이후로는 워크플로가 알아서 회전시킨다.
- `KAKAO_REDIRECT_URI` 가 등록돼 있는데 워크플로는 쓰지 않는다. 지워도 되고 둬도 된다.

### 2. 워크플로 수정분 푸시 — ✅ `5ad4ca9`

인자 전달 버그(아래)를 고쳐 푸시했다. 10-25 재발송으로 동작까지 확인됨.

## 이번에 고친 것 — 다시 밟지 않도록

`$args = @('-Force')` + `@args` 로 스크립트를 부르면 안 된다.
**배열 스플래팅은 값을 위치 인자로 넘기기 때문에** `'-Force'` 가 스위치가 아니라
첫 위치 인자(`-Date`)로 들어간다. 2026-10-24 주간 발송이 이것 때문에 죽었다.
`$args` 가 PowerShell 자동 변수라는 점도 겹친다. **스플래팅은 해시테이블로 한다.**

```powershell
$p = @{ Force = $true }
if ($env:IN_DATE -match '^\d{4}-\d{2}-\d{2}$') { $p['Date'] = $env:IN_DATE }
& ./scripts/send-weekly.ps1 @p
```

## 확인하는 법

```powershell
gh run list --limit 5                    # 최근 실행과 성패
gh run view <id> --log-failed            # 실패 이유
gh workflow run daily.yml                # 즉시 발송 (번호 소진함)
gh workflow run weekly.yml               # 복습 카드 즉시 발송
gh secret list                           # 등록된 Secret
```

`-DryRun` 으로 내용만 보려면 로컬에서:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\send-today.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File scripts\send-weekly.ps1 -DryRun -Force
```

## 아직 안 한 것

- [ ] **10-26(월) 07:00 평일 발송(050)이 실제로 왔는지 확인.** 주간 경로는 확인됐지만
      `daily.yml` 스케줄 실행은 아직 한 번도 성공한 적이 없다 (10-24 이관 후 평일이 없었다)
- [ ] **2026-12-05 10:00 에 예약 작업 `daily-english-token-check` 가 뜬다** — 카카오 토큰이
      자동 갱신됐는지 확인한다. 만료는 12-22, 갱신 실패 시 PC 에서 `setup.cmd` 재인증이 필요하다.
- [ ] 갱신 토큰 회전(`GH_PAT` 경로)은 아직 한 번도 안 돌았다. 카카오가 만료 임박에만 새 토큰을
      주기 때문. refresh token 만료는 2026-12-21 — 그 즈음 로그에서 "갱신 토큰 Secret 갱신함" 확인
- [ ] 번역 검수: `확신도 = 확인필요` 분은 끝났다고 기록돼 있으나(0050960) 전체 재검수는 안 했다
- [ ] 235개를 다 쓰면 멈춘다. 남은 분량 186개 ≈ 37주. `onFinish: "loop"` 를 쓸지 그때 정한다

## 손댈 때 주의

- **Actions 의 cron 은 정시가 아니다.** 10-24 실행은 예약보다 2시간 5분 늦게 떴다.
  GitHub 부하에 따라 밀리거나 드물게 거른다. 고칠 수 없고, 정시가 필요하면 Actions 가 답이 아니다.
- **진행 상태(`state/progress.json`)는 저장소가 원본이다.** 로컬에서 수동 발송했다면
  `git pull` 로 먼저 맞춰야 번호가 어긋나지 않는다.
- 발송 함수는 `Send-DeKakaoMemo` 하나다. 친구톡/알림톡으로 갈 때 여기만 바꾸면 나머지는 재사용된다.
- `send-today.ps1 -No 42` 는 진행 상태를 건드리지 않는다 (특정 문장 재발송용).
- 워크플로 입력은 `${{ inputs.* }}` 로 본문에 박지 말고 `env:` 로 받는다 (따옴표가 섞이면 코드가 된다).
