<#
.SYNOPSIS
    ChatGPT 등에서 받은 상세 설명(data\notes\*.md)을 읽어 번호에 붙인다.

.DESCRIPTION
    설명 파일은 자유 서술형이어도 된다. 각 항목이 "영어 문장" 줄로 시작하기만 하면
    목록(phrases.tsv)과 대조해 번호를 스스로 찾는다. 번호를 적어 둘 필요가 없다.

    결과는 data\notes.json 으로 모이고, build-web.ps1 이 카드에 실어 준다.
    첫 번째 "→" 줄은 다듬어진 뜻으로 보고, 기존 번역과 다르면 알려 준다
    (-ApplyMeaning 을 주면 실제로 바꾼다).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\import-notes.ps1
    powershell -ExecutionPolicy Bypass -File scripts\import-notes.ps1 -ApplyMeaning
#>
[CmdletBinding()]
param(
    # 첫 번째 "→" 줄을 translations.tsv 의 뜻으로 반영한다.
    [switch]$ApplyMeaning,
    # 설명 파일이 있는 폴더. 기본은 data\notes
    [string]$NotesDir
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force

$cfg = Get-DeConfig -Root $root
$logDir = $cfg.Dir['logs']
$phrases = Get-DePhrases -Config $cfg

function Get-NormalizedPhrase {
    # 대조용 정규화: 대문자, 스마트 따옴표 통일, 문장부호 제거, 공백 정리
    param([string]$Text)
    $t = $Text
    $t = $t -replace '[‘’ʼ´`]', "'"
    $t = $t -replace '[“”]', '"'
    $t = $t.ToUpperInvariant()
    $t = $t -replace "[^A-Z0-9' ]", ' '
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

# 문장 → 번호 사전 (중복이 있으면 알려 준다)
$lookup = @{}
foreach ($p in $phrases) {
    $key = Get-NormalizedPhrase $p.Phrase
    if ($lookup.ContainsKey($key)) {
        Write-DeLog -Level 'WARN' -LogDir $logDir -Message ('같은 문장이 둘 이상입니다: {0} (#{1}, #{2})' -f $p.Phrase, $lookup[$key], $p.No)
        continue
    }
    $lookup[$key] = $p.No
}

if (-not $NotesDir) { $NotesDir = Join-Path $cfg.Dir['data'] 'notes' }
if (-not (Test-Path -LiteralPath $NotesDir)) {
    New-Item -ItemType Directory -Path $NotesDir -Force | Out-Null
}
$files = @(Get-ChildItem -LiteralPath $NotesDir -Filter '*.md' -File | Sort-Object Name)
if ($files.Count -eq 0) {
    Write-Host ''
    Write-Host (' 설명 파일이 없습니다. ChatGPT 답변을 .md 로 저장해서 여기에 넣으세요:' ) -ForegroundColor Yellow
    Write-Host ('   {0}' -f $NotesDir) -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

# ── 블록 나누기 ─────────────────────────────────────────────────────────────
# 목록에 있는 문장과 일치하는 줄을 만나면 거기서 새 항목이 시작된 것으로 본다.
# 본문 안에서 다른 표현을 인용하는 경우와 섞이지 않도록, 바로 다음 줄이 "→" 로
# 시작하거나 그 줄이 파일/구분선 바로 뒤일 때만 제목으로 인정한다.
$items = @{}
$unmatched = @()

foreach ($f in $files) {
    $lines = Get-Content -LiteralPath $f.FullName -Encoding UTF8
    $curNo = 0
    $buf = New-Object System.Collections.Generic.List[string]
    $prevBlank = $true

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim() -replace '^#+\s*', '' -replace '^\d+\.\s*', ''
        $key = Get-NormalizedPhrase $trimmed

        $isHeading = $false
        if ($key -and $lookup.ContainsKey($key)) {
            # 같은 문장이 본문 안에서 다시 인용되는 일이 많다 (직역 설명, 예시 대화 등).
            # 이미 그 번호를 쓰는 중이면 제목이 아니라 본문으로 본다.
            if ($lookup[$key] -ne $curNo) {
                $next = ''
                for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                    if ($lines[$j].Trim()) { $next = $lines[$j].Trim(); break }
                }
                if ($i -eq 0 -or ($prevBlank -and $next -like '→*')) { $isHeading = $true }
            }
        }

        if ($isHeading) {
            if ($curNo -gt 0) { $items[$curNo] = ($buf -join "`n").Trim() }
            $curNo = $lookup[$key]
            $buf = New-Object System.Collections.Generic.List[string]
            $buf.Add($trimmed)
        }
        elseif ($curNo -gt 0) {
            $buf.Add($line.TrimEnd())
        }
        elseif ($line.Trim()) {
            $unmatched += ('{0}:{1}  {2}' -f $f.Name, ($i + 1), $line.Trim())
        }

        $prevBlank = -not $line.Trim()
    }
    if ($curNo -gt 0) { $items[$curNo] = ($buf -join "`n").Trim() }
}

if ($items.Count -eq 0) {
    Write-Host ''
    Write-Host ' 목록과 짝지어진 설명이 없습니다.' -ForegroundColor Yellow
    Write-Host ' 각 항목이 영어 문장 줄로 시작하는지 확인하세요 (그 다음 줄은 "→" 로 시작).' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

# ── 뜻 후보 뽑기 ────────────────────────────────────────────────────────────
$byNo = @{}
foreach ($p in $phrases) { $byNo[$p.No] = $p }

$notes = @()
$meaningChanges = @()

# 현재 번역 읽기
$koPath = Join-Path $cfg.Dir['data'] 'translations.tsv'
$order = New-Object System.Collections.Generic.List[int]
$ko = @{}; $conf = @{}; $note = @{}
$first = $true
foreach ($line in (Get-Content -LiteralPath $koPath -Encoding UTF8)) {
    if (-not $line.Trim()) { continue }
    if ($first) { $first = $false; if ($line -like 'no*ko*') { continue } }
    $c = $line -split "`t"
    if ($c.Count -lt 2) { continue }
    $n = [int]$c[0]
    $order.Add($n)
    $ko[$n] = $c[1]
    if ($c.Count -ge 3) { $conf[$n] = $c[2] } else { $conf[$n] = '' }
    if ($c.Count -ge 4) { $note[$n] = $c[3] } else { $note[$n] = '' }
}

foreach ($n in ($items.Keys | Sort-Object)) {
    $body = $items[$n]
    $arrows = @()
    foreach ($l in ($body -split "`n")) {
        $t = $l.Trim()
        if ($t -like '→*') { $arrows += $t.Substring(1).Trim() }
    }
    $suggested = ''
    if ($arrows.Count -gt 0) { $suggested = ($arrows[0] -replace '[.]$', '').Trim() }

    # 아침 카톡에 한 줄로 넣을 요약을 찾는다 (카톡은 200자 제한이라 전문은 못 넣는다).
    #   1) "핵심:" 으로 시작하는 줄   2) "핵심" 이 들어간 마지막 줄   3) 마지막 줄
    $hint = ''
    $bodyLines = @($body -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $selfKey = Get-NormalizedPhrase $byNo[$n].Phrase

    # 1) 명시적 마커 — "핵심: ..." / "기억 고리: ..." (프롬프트 판마다 이름이 다르다)
    foreach ($l in $bodyLines) {
        if ($l -match '^(핵심|기억 고리|한 줄 요약|요약)\s*[:：]\s*(.+)$') { $hint = $Matches[2].Trim() }
    }
    # 2) "…핵심을 한 문장으로 기억하면:" 같은 리드인 다음의 실제 문장
    if (-not $hint) {
        for ($k = 0; $k -lt $bodyLines.Count; $k++) {
            if ($bodyLines[$k] -notlike '*핵심*') { continue }
            if ($bodyLines[$k] -notmatch '[:：]\s*$') { continue }
            for ($m = $k + 1; $m -lt $bodyLines.Count; $m++) {
                $cand = $bodyLines[$m]
                if ((Get-NormalizedPhrase $cand) -eq $selfKey) { continue }   # 영어 원문 줄은 건너뛴다
                $hint = $cand
                break
            }
        }
    }
    # 3) 그래도 없으면 마지막 줄
    if (-not $hint -and $bodyLines.Count -gt 0) { $hint = $bodyLines[$bodyLines.Count - 1] }

    $hint = ($hint -replace '^[=＝]\s*', '').Trim()
    # 설명자가 붙이는 흔한 접두어를 떼어 낸다 (프롬프트 판마다 다르게 나온다)
    $hint = ($hint -replace '^(핵심은 한 문장으로|한 문장으로 기억하면|기억 고리|한 줄 요약|요약|정리)\s*[:：]?\s*', '').Trim()
    if ($hint.Length -gt 60) { $hint = '' }   # 너무 길면 아침 메시지에 넣지 않는다

    $notes += [pscustomobject]@{ no = $n; body = $body; hint = $hint }

    if ($suggested -and $ko[$n] -and $suggested -ne $ko[$n]) {
        $meaningChanges += [pscustomobject]@{ No = $n; Old = $ko[$n]; New = $suggested }
    }
}

$notesPath = Join-Path $cfg.Dir['data'] 'notes.json'
($notes | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $notesPath -Encoding utf8

Write-Host ''
Write-Host (' 설명 {0}개를 번호에 붙였습니다 — {1}' -f $notes.Count, $notesPath) -ForegroundColor Green
foreach ($n in ($items.Keys | Sort-Object)) {
    Write-Host ('   {0:d3}  {1}  ({2}자)' -f $n, $byNo[$n].Phrase, $items[$n].Length) -ForegroundColor DarkGray
}
$short = @($notes | Where-Object { $_.body.Length -lt 200 })
if ($short.Count -gt 0) {
    Write-Host ''
    Write-Host (' 설명이 짧은 항목 {0}개 — 블록이 잘렸을 수 있으니 확인하세요: {1}' -f `
            $short.Count, (($short | ForEach-Object { '#' + $_.no }) -join ', ')) -ForegroundColor Yellow
}
if ($unmatched.Count -gt 0) {
    Write-Host ''
    Write-Host (' 어느 문장에도 붙지 못한 줄 {0}개 (첫 5개):' -f $unmatched.Count) -ForegroundColor Yellow
    $unmatched | Select-Object -First 5 | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor Yellow }
}

if ($meaningChanges.Count -gt 0) {
    Write-Host ''
    Write-Host (' 다듬어진 뜻 후보 {0}개' -f $meaningChanges.Count) -ForegroundColor Cyan
    foreach ($c in $meaningChanges) {
        Write-Host ('  {0:d3}' -f $c.No) -NoNewline
        Write-Host ('  - ' + $c.Old) -ForegroundColor DarkGray
        Write-Host '      ' -NoNewline
        Write-Host ('  + ' + $c.New) -ForegroundColor Green
    }
    if (-not $ApplyMeaning) {
        Write-Host ''
        Write-Host ' 반영하려면 -ApplyMeaning 을 붙여 다시 실행하세요.' -ForegroundColor Yellow
    }
    else {
        $backupDir = Join-Path $cfg.Dir['data'] 'backup'
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $stamp = (Get-KstNow).ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $koPath -Destination (Join-Path $backupDir ('translations-{0}.tsv' -f $stamp)) -Force

        foreach ($c in $meaningChanges) { $ko[$c.No] = $c.New; $conf[$c.No] = '검수완료'; $note[$c.No] = '' }
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("no`tko`t확신도`t검수메모")
        foreach ($n in $order) { $out.Add(('{0}{4}{1}{4}{2}{4}{3}' -f $n, $ko[$n], $conf[$n], $note[$n], "`t")) }
        [System.IO.File]::WriteAllLines($koPath, $out, (New-Object System.Text.UTF8Encoding($true)))
        Write-DeLog -Level 'DONE' -LogDir $logDir -Message ('상세 설명에서 뜻 {0}개 반영 (백업 data\backup\translations-{1}.tsv)' -f $meaningChanges.Count, $stamp)
    }
}

Write-Host ''
Write-Host ' 다음: build-web.ps1 을 돌리면 카드에 "자세히" 가 붙습니다.' -ForegroundColor Cyan
Write-Host ''
