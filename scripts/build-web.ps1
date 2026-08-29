<#
.SYNOPSIS
    문장·번역 TSV 를 읽어 web\index.html (단일 파일 복습 카드 앱) 을 만든다.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build-web.ps1
#>
[CmdletBinding()]
param(
    # 결과 파일 경로. 기본은 web\index.html
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force

$cfg = Get-DeConfig -Root $root
$logDir = $cfg.Dir['logs']

$phrases = Get-DePhrases -Config $cfg

# 번역 파일 (번호 → 한글). 없으면 빈 값으로 두고 경고만 남긴다.
$ko = @{}
$koPath = Join-Path $cfg.Dir['data'] 'translations.tsv'
if (Test-Path -LiteralPath $koPath) {
    $first = $true
    foreach ($line in (Get-Content -LiteralPath $koPath -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        if ($first) { $first = $false; if ($line -like 'no*ko*') { continue } }
        $c = $line -split "`t"
        if ($c.Count -ge 2) { $ko[[int]$c[0]] = $c[1].Trim() }
    }
}
else {
    Write-DeLog -Level 'WARN' -LogDir $logDir -Message "번역 파일이 없습니다: $koPath (카드 뒷면이 비게 됩니다)"
}

$missing = @($phrases | Where-Object { -not $ko[$_.No] })
if ($missing.Count -gt 0) {
    Write-DeLog -Level 'WARN' -LogDir $logDir -Message ('번역이 없는 문장 {0}개 — 예: {1}' -f `
            $missing.Count, (($missing | Select-Object -First 3 | ForEach-Object { '#' + $_.No }) -join ', '))
}

$cards = @()
foreach ($p in $phrases) {
    $cards += [pscustomobject]@{
        no = $p.No
        en = $p.Phrase
        ko = [string]$ko[$p.No]
        url = $p.Url
    }
}

# skipNos 는 "발송에서 제외" 이지 "학습하지 않음" 이 아니다.
# 이미 다른 경로로 배운 문장이라면 복습 누적에는 포함시킨다 (web.includeSkippedInReview).
$prior = @()
if ($cfg.web.includeSkippedInReview) { $prior = @($cfg.skipNos) }

$payload = [pscustomobject]@{
    startDate = $cfg.web.startDate
    skipNos   = @($cfg.skipNos)
    priorNos  = $prior
    cards     = $cards
}
$json = $payload | ConvertTo-Json -Depth 5 -Compress

$templatePath = Join-Path $root 'web\template.html'
if (-not (Test-Path -LiteralPath $templatePath)) { throw "템플릿이 없습니다: $templatePath" }
$html = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8

if ($html -notmatch [regex]::Escape('/*__DATA__*/')) { throw '템플릿에 /*__DATA__*/ 자리표시자가 없습니다.' }
$html = $html.Replace('/*__DATA__*/', ('var DATA = ' + $json + ';'))

if (-not $OutFile) { $OutFile = Join-Path $root 'web\index.html' }
$dir = Split-Path $OutFile -Parent
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$utf8 = New-Object System.Text.UTF8Encoding($false)   # 브라우저가 읽는 파일이라 BOM 없이

# 1) 단독 호스팅용 — 완전한 문서. meta charset 이 없으면 한글이 깨진다.
$standalone = @"
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
$html
</html>
"@
[System.IO.File]::WriteAllText($OutFile, $standalone, $utf8)

# 2) Artifact 용 — head/body 는 발행 시점에 감싸지므로 본문만 그대로 둔다.
$artifactPath = Join-Path $dir 'artifact.html'
[System.IO.File]::WriteAllText($artifactPath, $html, $utf8)

# 3) GitHub Pages 용 — docs\ 를 사이트 루트로 쓰면 주소가 짧아진다
#    (https://<계정>.github.io/daily-english/). 카톡 200자 제한에서 URL 길이가 중요하다.
$pagesPath = Join-Path $root 'docs\index.html'
[System.IO.File]::WriteAllText($pagesPath, $standalone, $utf8)

$size = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1KB, 1)
Write-DeLog -Level 'DONE' -LogDir $logDir -Message ('빌드 완료 — 카드 {0}장 (번역 없음 {1}장) / {2} KB' -f `
        $cards.Count, $missing.Count, $size)
Write-DeLog -LogDir $logDir -Message ('  단독 호스팅용 : {0}' -f $OutFile)
Write-DeLog -LogDir $logDir -Message ('  Artifact 용   : {0}' -f $artifactPath)
Write-DeLog -LogDir $logDir -Message ('  GitHub Pages : {0}' -f $pagesPath)
