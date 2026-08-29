<#
.SYNOPSIS
    오늘의 문장 하나를 카카오톡 "나에게 보내기" 로 발송한다. 작업 스케줄러가 매일 이걸 부른다.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\send-today.ps1 -DryRun
    powershell -ExecutionPolicy Bypass -File scripts\send-today.ps1 -No 42
#>
[CmdletBinding()]
param(
    # 실제로 보내지 않고 보낼 내용만 보여준다.
    [switch]$DryRun,
    # 특정 번호를 지정해서 보낸다 (진행 상태는 건드리지 않는다).
    [int]$No = 0,
    # 발송 요일 / 중복 발송 검사를 무시한다.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force

$cfg = Get-DeConfig -Root $root
$logDir = $cfg.Dir['logs']

try {
    # 1) 오늘 보낼 날인가
    if (-not $Force -and -not $DryRun -and -not (Test-DeSendDay -Config $cfg)) {
        Write-DeLog -LogDir $logDir -Message ('오늘은 발송 요일이 아닙니다 ({0}) — 건너뜀' -f (Get-KstNow).DayOfWeek)
        exit 0
    }

    $phrases = Get-DePhrases -Config $cfg
    $progress = Get-DeProgress -Config $cfg
    $today = (Get-KstNow).ToString('yyyy-MM-dd')

    # 2) 같은 날 두 번 보내지 않는다 (작업이 중복 실행되는 경우 대비)
    if (-not $Force -and -not $DryRun -and $No -eq 0 -and $progress.lastSentDate -eq $today) {
        Write-DeLog -Level 'WARN' -LogDir $logDir -Message ('오늘({0}) 이미 {1}번을 보냈습니다 — 건너뜀' -f $today, $progress.lastSentNo)
        exit 0
    }

    # 3) 보낼 항목 고르기 — 번호를 직접 준 경우가 아니면 제외 목록을 건너뛰며 순차 선택
    if ($No -gt 0) {
        $item = $phrases | Where-Object { $_.No -eq $No } | Select-Object -First 1
        if (-not $item) {
            Write-DeLog -Level 'FAIL' -LogDir $logDir -Message ('{0}번 문장이 목록에 없습니다' -f $No)
            exit 1
        }
    }
    else {
        $item = Get-DeNextItem -Phrases $phrases -Progress $progress -Config $cfg
        if (-not $item) {
            Write-DeLog -Level 'WARN' -LogDir $logDir -Message (
                '보낼 문장이 없습니다 — 목록 {0}개를 모두 소진했습니다. 문장을 추가하거나 config 의 onFinish 를 "loop" 로 바꾸세요.' -f $phrases.Count)
            exit 0
        }
        if ($item.No -ne [int]$progress.nextNo) {
            Write-DeLog -LogDir $logDir -Message ('{0}번은 제외 목록이라 건너뛰고 {1}번을 보냅니다' -f $progress.nextNo, $item.No)
        }
    }

    $text = Format-DeMessage -Config $cfg -Item $item -Total $phrases.Count

    if ($DryRun) {
        Write-Host ''
        Write-Host ('  [미리보기] {0}자' -f $text.Length) -ForegroundColor DarkGray
        Write-Host '  ─────────────────────────────'
        $text -split "`n" | ForEach-Object { Write-Host ('  ' + $_) }
        Write-Host '  ─────────────────────────────'
        Write-Host ('  버튼: {0} → {1}' -f $cfg.buttonTitle, $item.Url) -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }

    # 4) 발송
    $kenv = Get-DeEnv -Root $root
    $token = Get-DeValidAccessToken -Config $cfg -Env $kenv
    $r = Send-DeKakaoMemo -AccessToken $token -Text $text -Url $item.Url -ButtonTitle $cfg.buttonTitle

    if ($r.result_code -ne 0) {
        throw ('발송 응답이 성공이 아닙니다: {0}' -f ($r | ConvertTo-Json -Compress))
    }
    Write-DeLog -Level 'DONE' -LogDir $logDir -Message ('발송 완료 — {0:d3} {1}' -f $item.No, $item.Phrase)

    # 5) 진행 상태 갱신 (번호를 직접 지정한 경우는 건드리지 않는다)
    if ($No -eq 0) {
        $progress.lastSentNo = $item.No
        $progress.lastSentDate = $today
        $progress.nextNo = $item.No + 1
        $progress.sentNos = @(@($progress.sentNos) + $item.No)
        Save-DeProgress -Config $cfg -Progress $progress

        $peek = Get-DeNextItem -Phrases $phrases -Progress $progress -Config $cfg
        if ($peek) { Write-DeLog -LogDir $logDir -Message ('다음 발송 예정: {0:d3} {1}' -f $peek.No, $peek.Phrase) }
        else { Write-DeLog -Level 'WARN' -LogDir $logDir -Message '남은 문장이 없습니다 — 목록을 늘려 주세요' }
    }
    exit 0
}
catch {
    Write-DeLog -Level 'FAIL' -LogDir $logDir -Message ('발송 실패 — {0}' -f $_.Exception.Message)
    exit 1
}
