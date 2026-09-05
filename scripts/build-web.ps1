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

# 번역 파일 (번호 → 한글 / 확신도). 없으면 빈 값으로 두고 경고만 남긴다.
$ko = @{}
$conf = @{}
$koPath = Join-Path $cfg.Dir['data'] 'translations.tsv'
if (Test-Path -LiteralPath $koPath) {
    $first = $true
    foreach ($line in (Get-Content -LiteralPath $koPath -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        if ($first) { $first = $false; if ($line -like 'no*ko*') { continue } }
        $c = $line -split "`t"
        if ($c.Count -lt 2) { continue }
        $n = [int]$c[0]
        $ko[$n] = $c[1].Trim()
        if ($c.Count -ge 3) { $conf[$n] = $c[2].Trim() } else { $conf[$n] = '' }
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

# 4) 사람이 읽는 전체 목록 — 영어·한글·상태를 한 표에 모은다 (GitHub/폰에서 그냥 읽힌다)
$progress = Get-DeProgress -Config $cfg
$sent = @{}
foreach ($n in @($progress.sentNos)) { if ($n) { $sent[[int]$n] = $true } }
$skip = @{}
foreach ($n in @($cfg.skipNos)) { if ($n) { $skip[[int]$n] = $true } }

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# 듣보잡 영어 — 전체 문장 목록')
$md.Add('')
$md.Add(('> 총 {0}개 · {1} 기준 (KST) · 이 파일은 `build-web.ps1` 이 만든다. 고칠 때는 `data\*.tsv` 를 고친다.' -f `
            $cards.Count, (Get-KstNow).ToString('yyyy-MM-dd HH:mm')))
$md.Add('')
$md.Add(('- **보냄** {0}개 · **이전 학습** {1}개 · **예정** {2}개' -f `
            $sent.Count, $skip.Count, ($cards.Count - $sent.Count - $skip.Count)))
$md.Add(('- 번역 **확인필요** {0}개 · **검수완료** {1}개' -f `
        (@($conf.Values | Where-Object { $_ -eq '확인필요' }).Count),
        (@($conf.Values | Where-Object { $_ -eq '검수완료' }).Count)))
$md.Add('- 상태: ✅ 보냄 · 🔁 이전에 학습(발송 제외) · ⬜ 예정 / 검수: ⚠️ 확인필요 · ✔ 검수완료')
$md.Add('')
$md.Add('| # | 표현 | 뜻 | 상태 | 검수 | 쇼츠 |')
$md.Add('|---:|---|---|:--:|:--:|:--:|')

foreach ($c in $cards) {
    $st = '⬜'
    if ($sent[$c.no]) { $st = '✅' }
    elseif ($skip[$c.no]) { $st = '🔁' }

    $rv = ''
    if ($conf[$c.no] -eq '확인필요') { $rv = '⚠️' }
    elseif ($conf[$c.no] -eq '검수완료') { $rv = '✔' }

    # 표를 깨뜨리지 않도록 파이프만 막는다
    $en = $c.en -replace '\|', '\|'
    $ko = $c.ko -replace '\|', '\|'
    $md.Add(('| {0:d3} | {1} | {2} | {3} | {4} | [▶]({5}) |' -f $c.no, $en, $ko, $st, $rv, $c.url))
}

$mdPath = Join-Path $root 'docs\PHRASES.md'
[System.IO.File]::WriteAllText($mdPath, (($md -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

$size = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1KB, 1)
Write-DeLog -Level 'DONE' -LogDir $logDir -Message ('빌드 완료 — 카드 {0}장 (번역 없음 {1}장) / {2} KB' -f `
        $cards.Count, $missing.Count, $size)
Write-DeLog -LogDir $logDir -Message ('  단독 호스팅용 : {0}' -f $OutFile)
Write-DeLog -LogDir $logDir -Message ('  Artifact 용   : {0}' -f $artifactPath)
Write-DeLog -LogDir $logDir -Message ('  GitHub Pages : {0}' -f $pagesPath)
Write-DeLog -LogDir $logDir -Message ('  전체 목록 md : {0}' -f $mdPath)
