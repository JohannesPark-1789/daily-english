<#
.SYNOPSIS
    검수용 파일을 만든다 — 영어·한글·쇼츠 링크를 한 줄에 모아 Excel 로 연다.

.DESCRIPTION
    data\review.csv 로 내보낸다. Excel 에서 "한글" 열만 고치고 저장한 뒤
    import-review.ps1 로 되돌려 넣으면 된다. 다른 열은 건드리지 않아도 된다.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\export-review.ps1
    powershell -ExecutionPolicy Bypass -File scripts\export-review.ps1 -OnlyCheck
#>
[CmdletBinding()]
param(
    # "확인필요" 로 표시된 것만 내보낸다.
    [switch]$OnlyCheck,
    # 내보낼 경로. 기본은 data\review.csv
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force

$cfg = Get-DeConfig -Root $root
$logDir = $cfg.Dir['logs']
$phrases = Get-DePhrases -Config $cfg

# 번역 파일: no / ko / 확신도 / 검수메모
$ko = @{}
$conf = @{}
$note = @{}
$koPath = Join-Path $cfg.Dir['data'] 'translations.tsv'
$first = $true
foreach ($line in (Get-Content -LiteralPath $koPath -Encoding UTF8)) {
    if (-not $line.Trim()) { continue }
    if ($first) { $first = $false; if ($line -like 'no*ko*') { continue } }
    $c = $line -split "`t"
    if ($c.Count -lt 2) { continue }
    $n = [int]$c[0]
    $ko[$n] = $c[1]
    if ($c.Count -ge 3) { $conf[$n] = $c[2] }
    if ($c.Count -ge 4) { $note[$n] = $c[3] }
}

$rows = @()
foreach ($p in $phrases) {
    if ($OnlyCheck -and $conf[$p.No] -ne '확인필요') { continue }
    $rows += [pscustomobject]@{
        '번호'   = $p.No
        '영어'   = $p.Phrase
        '한글'   = [string]$ko[$p.No]
        '확신도' = [string]$conf[$p.No]
        '검수메모' = [string]$note[$p.No]
        '쇼츠'   = $p.Url
    }
}

if (-not $OutFile) { $OutFile = Join-Path $cfg.Dir['data'] 'review.csv' }
# Excel 이 한글을 제대로 읽도록 BOM 이 있는 UTF-8 로 쓴다 (PS 5.1 의 -Encoding UTF8 이 그렇다)
$rows | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding UTF8

$checkCount = @($rows | Where-Object { $_.확신도 -eq '확인필요' }).Count
Write-DeLog -Level 'DONE' -LogDir $logDir -Message ('검수 파일 생성 — {0}행 (확인필요 {1}행) / {2}' -f $rows.Count, $checkCount, $OutFile)
Write-Host ''
Write-Host ' Excel 에서 "한글" 열만 고치고 저장하세요. 다른 열은 그대로 두면 됩니다.' -ForegroundColor Cyan
Write-Host ' 저장 형식은 CSV(쉼표로 분리) 그대로 유지하세요.' -ForegroundColor Cyan
Write-Host ' 다 고쳤으면 review-import.cmd 를 실행하면 반영됩니다.' -ForegroundColor Cyan
Write-Host ''
