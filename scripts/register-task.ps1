<#
.SYNOPSIS
    윈도 작업 스케줄러에 "월~금 오전 7시 발송" 을 등록/해제한다.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\register-task.ps1
    powershell -ExecutionPolicy Bypass -File scripts\register-task.ps1 -Remove
    powershell -ExecutionPolicy Bypass -File scripts\register-task.ps1 -Status
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$Status,
    [string]$TaskName,
    # config.json 의 sendTime 을 덮어쓴다. 예: "07:30"
    [string]$Time,
    # 주간 복습 발송(토요일) 작업을 대상으로 한다. 생략하면 평일 발송 작업.
    [switch]$Weekly
)

if (-not $TaskName) {
    if ($Weekly) { $TaskName = 'daily-english-weekly' } else { $TaskName = 'daily-english-7am' }
}

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force
$cfg = Get-DeConfig -Root $root

if ($Status) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host ' 등록된 작업이 없습니다.' -ForegroundColor Yellow; exit 0 }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host ''
    Write-Host (' 작업     : {0}' -f $t.TaskName)
    Write-Host (' 상태     : {0}' -f $t.State)
    Write-Host (' 다음 실행: {0}' -f $info.NextRunTime)
    Write-Host (' 지난 실행: {0}  (결과 {1})' -f $info.LastRunTime, $info.LastTaskResult)
    Write-Host ''
    exit 0
}

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host (' 작업 삭제: {0}' -f $TaskName) -ForegroundColor Green
    }
    else {
        Write-Host ' 등록된 작업이 없습니다.' -ForegroundColor Yellow
    }
    exit 0
}

if ($Weekly) {
    $at = $cfg.weekly.sendTime
    $script = Join-Path $PSScriptRoot 'send-weekly.ps1'
    $days = @($cfg.weekly.day)
    $desc = '토요일 오전, 그 주에 보낸 문장을 복습 카드 링크와 함께 발송'
}
else {
    $at = $cfg.sendTime
    $script = Join-Path $PSScriptRoot 'send-today.ps1'
    $days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    $desc = '월~금 오전 7시, 오늘의 영어 문장을 카카오톡 나에게 보내기로 발송'
}
if ($Time) { $at = $Time }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $script) `
    -WorkingDirectory $root

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $at

# PC 가 꺼져 있어 놓친 경우, 켜지고 나서 한 번 따라 실행한다.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description $desc -Force | Out-Null

$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ''
$dayLabel = '월~금'
if ($Weekly) { $dayLabel = $days -join ', ' }
Write-Host (' 등록 완료: {0}  ({1} {2})' -f $TaskName, $dayLabel, $at) -ForegroundColor Green
Write-Host (' 다음 실행: {0}' -f $info.NextRunTime)
Write-Host ''
