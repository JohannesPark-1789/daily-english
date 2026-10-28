<#
.SYNOPSIS
    목표 시각(KST)까지 기다렸다가 "지금 보내라"고 알려 준다. GitHub Actions 전용.

.DESCRIPTION
    GitHub 의 cron 은 "그 시각에 깨운다"는 보장이 없다. 이 저장소 실측으로는 매번
    1~3시간 늦게 깨어났고, 분을 0 에서 53 으로 옮겨도 그대로였다. 깨어난 시각을
    발송 시각으로 쓰는 한 정시 도착은 안 된다.

    그래서 예약을 목표보다 훨씬 앞에 여러 번 걸어 두고, 깨어난 쪽이 목표 시각까지
    기다렸다가 보낸다. 발송 시각을 정하는 것은 cron 이 아니라 이 대기다.

      · 목표를 이미 지났다      → 바로 보낸다 (늦더라도 거르는 것보다 낫다)
      · 남은 시간 ≤ 대기 한도   → 그만큼 자고 나서 보낸다
      · 남은 시간 > 대기 한도   → 보내지 않고 끝낸다. 뒤에 걸린 예약이 맡는다
      · 예약이 아닌 수동 실행   → 기다리지 않고 바로 보낸다

    판단 결과는 GITHUB_OUTPUT 에 send=yes|no 로 넘긴다.

.EXAMPLE
    pwsh ./scripts/wait-for-send-time.ps1 -Target 07:00 -MaxWaitMinutes 100

.EXAMPLE
    # 기다리지 않고 판단만 확인한다 (대기 한도 바깥이라 no 가 나와야 한다)
    pwsh ./scripts/wait-for-send-time.ps1 -Now '2026-10-29 03:30' -NoSleep
#>
[CmdletBinding()]
param(
    # 목표 발송 시각 (KST, HH:mm).
    [string]$Target = '07:00',
    # 여기까지는 기다린다. 더 남았으면 이 run 은 보내지 않는다.
    [int]$MaxWaitMinutes = 100,
    # 테스트용 — 지금이 이 시각(KST)인 셈 친다.
    [string]$Now = '',
    # 테스트용 — 실제로 자지 않는다.
    [switch]$NoSleep
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force

function Write-Decision {
    param([ValidateSet('yes', 'no')][string]$Send, [string]$Reason)
    Write-Host $Reason
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value ('send={0}' -f $Send)
    }
}

function Get-Now {
    if ($Now) { return [DateTime]::Parse($Now) }
    return Get-KstNow
}

# 수동 실행(workflow_dispatch)은 "지금 보내 달라"는 뜻이다 — 기다리지 않는다.
if ($env:GITHUB_EVENT_NAME -and $env:GITHUB_EVENT_NAME -ne 'schedule') {
    Write-Decision -Send 'yes' -Reason ('예약이 아닌 {0} 실행 — 기다리지 않고 바로 보냅니다' -f $env:GITHUB_EVENT_NAME)
    exit 0
}

$hhmm = [DateTime]::ParseExact($Target, 'HH\:mm', $null)
$kst = Get-Now
$targetAt = $kst.Date.AddHours($hhmm.Hour).AddMinutes($hhmm.Minute)
$leftMin = ($targetAt - $kst).TotalMinutes

Write-Host ('지금 {0:yyyy-MM-dd HH:mm:ss} KST · 목표 {1:HH:mm} · 남은 시간 {2:n1}분 · 대기 한도 {3}분' -f `
        $kst, $targetAt, $leftMin, $MaxWaitMinutes)

if ($leftMin -le 0) {
    Write-Decision -Send 'yes' -Reason (
        '예약이 목표보다 {0:n0}분 늦게 깨어났습니다 — 기다리지 않고 바로 보냅니다' -f (-$leftMin))
    exit 0
}

if ($leftMin -gt $MaxWaitMinutes) {
    Write-Decision -Send 'no' -Reason (
        '목표까지 {0:n0}분 남아 이 run 은 보내지 않습니다 — 뒤에 걸린 예약이 맡습니다' -f $leftMin)
    exit 0
}

if ($NoSleep) {
    Write-Decision -Send 'yes' -Reason ('[NoSleep] {0:n0}분 기다릴 자리입니다' -f $leftMin)
    exit 0
}

# 한 번에 길게 자지 않는다 — 중간중간 다시 재서 어긋남을 줄이고, 로그에 진행을 남긴다.
while ($true) {
    $kst = Get-Now
    $leftSec = ($targetAt - $kst).TotalSeconds
    if ($leftSec -le 0) { break }
    if ($leftSec -gt 300) { Write-Host ('  … {0:n0}분 남음' -f ($leftSec / 60)) }
    Start-Sleep -Seconds ([int][Math]::Min(60, [Math]::Ceiling($leftSec)))
}

Write-Decision -Send 'yes' -Reason ('{0:HH:mm:ss} KST — 목표 시각이 되었습니다' -f (Get-Now))
exit 0
