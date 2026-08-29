<#
.SYNOPSIS
    그 주에 보낸 문장을 모아 복습 카드 링크와 함께 카카오톡으로 보낸다 (토요일 07:00).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\send-weekly.ps1 -DryRun
#>
[CmdletBinding()]
param(
    # 보내지 않고 내용만 확인한다.
    [switch]$DryRun,
    # 요일 검사를 무시한다.
    [switch]$Force,
    # 기준 날짜(KST, yyyy-MM-dd). 생략하면 오늘. 지난 주를 다시 뽑을 때 쓴다.
    [string]$Date
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force

$cfg = Get-DeConfig -Root $root
$logDir = $cfg.Dir['logs']

try {
    $today = Get-KstNow
    if ($Date) { $today = [DateTime]::ParseExact($Date, 'yyyy-MM-dd', $null) }

    if (-not $Force -and -not $DryRun -and $today.DayOfWeek.ToString() -ne $cfg.weekly.day) {
        Write-DeLog -LogDir $logDir -Message ('오늘은 주간 발송일이 아닙니다 ({0}) — 건너뜀' -f $today.DayOfWeek)
        exit 0
    }

    # 이번 주 월요일 00:00 부터 오늘까지 로그에서 실제 발송분을 뽑는다.
    # (progress.sentNos 는 누적이라 주 단위로 자르려면 로그가 정확하다)
    $monday = $today.Date.AddDays(-(([int]$today.DayOfWeek + 6) % 7))
    $phrases = Get-DePhrases -Config $cfg
    $byNo = @{}
    foreach ($p in $phrases) { $byNo[$p.No] = $p }

    $nos = New-Object System.Collections.Generic.List[int]
    foreach ($f in (Get-ChildItem -LiteralPath $logDir -Filter 'daily-english-*.log' -ErrorAction SilentlyContinue)) {
        foreach ($line in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
            $m = [regex]::Match($line, '^(\d{4}-\d{2}-\d{2}) .*\[DONE\] 발송 완료 — (\d{3}) ')
            if (-not $m.Success) { continue }
            $when = [DateTime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $null)
            if ($when -lt $monday -or $when -gt $today.Date) { continue }
            $n = [int]$m.Groups[2].Value
            if (-not $nos.Contains($n)) { $nos.Add($n) }
        }
    }
    $weekNos = @($nos | Sort-Object)

    if ($weekNos.Count -eq 0) {
        Write-DeLog -Level 'WARN' -LogDir $logDir -Message ('{0:yyyy-MM-dd} 주간: 이번 주 발송 기록이 없어 보내지 않습니다' -f $monday)
        exit 0
    }

    # 본문 — 문장 목록 + 카드 링크
    $lines = @()
    foreach ($n in $weekNos) {
        if ($byNo[$n]) { $lines += ('{0:d3}  {1}' -f $n, $byNo[$n].Phrase) }
    }
    $url = $cfg.web.baseUrl
    if ($url) {
        $sep = '?'
        if ($url.Contains('?')) { $sep = '&' }
        # 쉼표는 카톡 자동 링크에서 잘릴 수 있어 밑줄로 잇는다 (페이지가 둘 다 받는다)
        $url = '{0}{1}w={2}' -f $url, $sep, ($weekNos -join '_')
    }

    # 본문에 URL 을 넣어야 카톡이 자동 링크로 만들어 준다
    # (버튼 링크는 앱에 등록된 도메인만 동작하므로 본문 링크를 주 경로로 쓴다).
    # 텍스트 템플릿은 200자 제한이라, 넘치면 링크가 아니라 문장 목록이 잘리게 한다.
    $frame = ($cfg.weekly.messageTemplate -join "`n")
    $frame = $frame.Replace('{count}', [string]$weekNos.Count)
    $frame = $frame.Replace('{range}', ('{0:MM.dd}~{1:MM.dd}' -f $monday, $today))
    $frame = $frame.Replace('{url}', $url)
    # {nos} 는 번호만 압축한 것 — 길이가 짧아 항상 살아남는다
    $frame = $frame.Replace('{nos}', (($weekNos | ForEach-Object { '{0:d3}' -f $_ }) -join ' '))

    $limit = 200
    $base = $frame.Replace('{list}', '')
    $room = $limit - $base.Length
    $kept = @()
    foreach ($l in $lines) {
        $need = $l.Length + 1
        if ($kept.Count -eq 0) { $need = $l.Length }
        if ($room - $need -lt 0) { break }
        $kept += $l
        $room -= $need
    }
    # 목록을 쓰는 템플릿일 때만 잘림을 알린다 ({nos} 만 쓰면 잘릴 일이 없다)
    if ($frame.Contains('{list}') -and $kept.Count -lt $lines.Count) {
        Write-DeLog -Level 'WARN' -LogDir $logDir -Message (
            '200자 제한으로 문장 {0}/{1}개만 본문에 담았습니다 (링크는 유지)' -f $kept.Count, $lines.Count)
    }
    $text = $frame.Replace('{list}', ($kept -join "`n")).TrimEnd()

    if ($DryRun) {
        Write-Host ''
        Write-Host ('  [미리보기] {0}자 / 링크: {1}' -f $text.Length, $(if ($url) { $url } else { '(web.baseUrl 미설정)' })) -ForegroundColor DarkGray
        Write-Host '  ─────────────────────────────'
        $text -split "`n" | ForEach-Object { Write-Host ('  ' + $_) }
        Write-Host '  ─────────────────────────────'
        Write-Host ''
        exit 0
    }

    if (-not $url) {
        Write-DeLog -Level 'WARN' -LogDir $logDir -Message 'config.json 의 web.baseUrl 이 비어 있습니다 — 카드 링크 없이 문장만 보냅니다'
    }

    $kenv = Get-DeEnv -Root $root
    $token = Get-DeValidAccessToken -Config $cfg -Env $kenv
    $r = Send-DeKakaoMemo -AccessToken $token -Text $text -Url $url -ButtonTitle $cfg.weekly.buttonTitle
    if ($r.result_code -ne 0) { throw ('발송 응답이 성공이 아닙니다: {0}' -f ($r | ConvertTo-Json -Compress)) }

    Write-DeLog -Level 'DONE' -LogDir $logDir -Message ('주간 복습 발송 완료 — {0}문장 ({1})' -f $weekNos.Count, ($weekNos -join ', '))
    exit 0
}
catch {
    Write-DeLog -Level 'FAIL' -LogDir $logDir -Message ('주간 발송 실패 — {0}' -f $_.Exception.Message)
    exit 1
}
