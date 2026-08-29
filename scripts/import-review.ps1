<#
.SYNOPSIS
    Excel 에서 고친 검수 파일(data\review.csv)을 translations.tsv 에 되돌려 넣는다.

.DESCRIPTION
    바뀐 줄만 반영하고, 무엇이 어떻게 바뀌었는지 보여준다.
    되돌려 넣기 전에 기존 파일을 backup 폴더에 복사한다.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\import-review.ps1 -WhatIfOnly
    powershell -ExecutionPolicy Bypass -File scripts\import-review.ps1
#>
[CmdletBinding()]
param(
    # 반영하지 않고 무엇이 바뀔지만 보여준다.
    [switch]$WhatIfOnly,
    # 읽어올 경로. 기본은 data\review.csv
    [string]$InFile
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force

$cfg = Get-DeConfig -Root $root
$logDir = $cfg.Dir['logs']

if (-not $InFile) { $InFile = Join-Path $cfg.Dir['data'] 'review.csv' }
if (-not (Test-Path -LiteralPath $InFile)) {
    throw "검수 파일이 없습니다: $InFile  (먼저 review-export.cmd 를 실행하세요)"
}

$edited = @(Import-Csv -LiteralPath $InFile -Encoding UTF8)
if ($edited.Count -eq 0) { throw '검수 파일이 비어 있습니다.' }
foreach ($col in '번호', '한글') {
    if (-not ($edited[0].PSObject.Properties.Name -contains $col)) {
        throw ("검수 파일에 '{0}' 열이 없습니다 — 열 이름을 바꾸지 마세요." -f $col)
    }
}

# 현재 번역 파일 읽기
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

# 바뀐 것 추리기
$changes = @()
$skipped = 0
foreach ($row in $edited) {
    $n = 0
    if (-not [int]::TryParse(([string]$row.번호).Trim(), [ref]$n)) { $skipped++; continue }
    if (-not $ko.ContainsKey($n)) { $skipped++; continue }

    $new = ([string]$row.한글).Trim()
    if (-not $new) { $skipped++; continue }          # 빈 칸은 무시 (실수로 지운 경우 보호)
    if ($new -eq $ko[$n]) { continue }

    $changes += [pscustomobject]@{ No = $n; Old = $ko[$n]; New = $new }
}

if ($changes.Count -eq 0) {
    Write-Host ''
    Write-Host ' 바뀐 번역이 없습니다.' -ForegroundColor Yellow
    if ($skipped -gt 0) { Write-Host (' (빈 칸이나 알 수 없는 번호 {0}행은 건너뜀)' -f $skipped) -ForegroundColor DarkGray }
    Write-Host ''
    exit 0
}

Write-Host ''
Write-Host (' 바뀐 번역 {0}개' -f $changes.Count) -ForegroundColor Cyan
foreach ($c in $changes) {
    Write-Host ('  {0:d3}' -f $c.No) -NoNewline
    Write-Host ('  - ' + $c.Old) -ForegroundColor DarkGray
    Write-Host '      ' -NoNewline
    Write-Host ('  + ' + $c.New) -ForegroundColor Green
}
Write-Host ''

if ($WhatIfOnly) {
    Write-Host ' -WhatIfOnly 라서 반영하지 않았습니다.' -ForegroundColor Yellow
    exit 0
}

# 백업 후 반영. 검수한 줄은 확신도를 '검수완료' 로 바꾼다.
$backupDir = Join-Path $cfg.Dir['data'] 'backup'
if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
$stamp = (Get-KstNow).ToString('yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $koPath -Destination (Join-Path $backupDir ('translations-{0}.tsv' -f $stamp)) -Force

foreach ($c in $changes) {
    $ko[$c.No] = $c.New
    $conf[$c.No] = '검수완료'
    $note[$c.No] = ''
}

$out = New-Object System.Collections.Generic.List[string]
$out.Add("no`tko`t확신도`t검수메모")
foreach ($n in $order) {
    $out.Add(('{0}{4}{1}{4}{2}{4}{3}' -f $n, $ko[$n], $conf[$n], $note[$n], "`t"))
}
[System.IO.File]::WriteAllLines($koPath, $out, (New-Object System.Text.UTF8Encoding($true)))

Write-DeLog -Level 'DONE' -LogDir $logDir -Message ('번역 {0}개 수정 반영 (백업: data\backup\translations-{1}.tsv)' -f $changes.Count, $stamp)
Write-Host ' 이제 build-web.ps1 을 돌리고 git push 하면 카드에 반영됩니다.' -ForegroundColor Cyan
Write-Host ''
