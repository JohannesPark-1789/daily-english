<#
.SYNOPSIS
    GitHub Secrets 에 넣을 값을 이 PC 화면에만 보여 준다.

.DESCRIPTION
    .env 와 state\tokens.json 에서 값을 읽어 그대로 출력한다. 어디로도 전송하지 않는다.
    출력된 값은 화면 캡처·채팅에 올리지 말 것.
#>
[CmdletBinding()]
param(
    # 값을 가리지 않고 전체를 보여 준다 (복사해야 하므로 기본이 전체 표시).
    [switch]$Mask
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force
$cfg = Get-DeConfig -Root $root
$kenv = Get-DeEnv -Root $root
$tokens = Get-DeTokens -Config $cfg

function Show([string]$name, [string]$value) {
    if (-not $value) {
        Write-Host ("  {0,-22} (없음)" -f $name) -ForegroundColor Yellow
        return
    }
    $shown = $value
    if ($Mask -and $value.Length -gt 8) {
        $shown = $value.Substring(0, 4) + ('*' * ($value.Length - 8)) + $value.Substring($value.Length - 4)
    }
    Write-Host ("  {0,-22} " -f $name) -NoNewline
    Write-Host $shown -ForegroundColor Green
}

Write-Host ''
Write-Host ' GitHub 저장소 Settings → Secrets and variables → Actions → New repository secret' -ForegroundColor Cyan
Write-Host ' 아래 세 개를 그대로 등록하세요. (이름도 그대로)' -ForegroundColor Cyan
Write-Host ''
Show 'KAKAO_REST_API_KEY'  $kenv['KAKAO_REST_API_KEY']
Show 'KAKAO_CLIENT_SECRET' $kenv['KAKAO_CLIENT_SECRET']
Show 'KAKAO_REFRESH_TOKEN' $tokens.refresh_token
Write-Host ''
Write-Host ' 네 번째 GH_PAT 는 GitHub 에서 새로 만듭니다 (아래 안내 참고).' -ForegroundColor Cyan
Write-Host ''
Write-Host ' 이 값들은 이 창에만 표시됩니다. 채팅·스크린샷으로 공유하지 마세요.' -ForegroundColor DarkGray
Write-Host ''

if ($tokens.refresh_expires_utc) {
    $exp = [DateTime]::Parse($tokens.refresh_expires_utc).ToUniversalTime()
    $left = [int]($exp - [DateTime]::UtcNow).TotalDays
    Write-Host (' 참고: 지금 갱신 토큰은 {0} 일 뒤 만료 예정입니다. 등록 후 Actions 가 알아서 갱신합니다.' -f $left) -ForegroundColor DarkGray
    Write-Host ''
}
