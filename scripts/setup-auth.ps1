<#
.SYNOPSIS
    카카오 "나에게 보내기" 최초 1회 인증. 브라우저에서 동의한 뒤 주소창 URL 을 붙여넣으면 된다.

.NOTES
    비밀번호는 브라우저(카카오 로그인 화면)에만 입력한다. 이 스크립트는 비밀번호를 받지 않는다.
#>
[CmdletBinding()]
param(
    # 인증 후 테스트 메시지를 보내지 않는다.
    [switch]$NoTestMessage,

    # 요청할 동의항목. 기본값이면 talk_message 를 요청한다.
    [string]$Scope = 'talk_message',

    # 진단용: 동의항목 없이 인증만 시도한다. "앱 관리자 설정 오류" 의 원인이
    # 동의항목 때문인지 가르는 데 쓴다. 이 토큰으로는 발송이 안 된다.
    [switch]$NoScope
)

if ($NoScope) { $Scope = '' }

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\kakao.psm1') -Force

$cfg = Get-DeConfig -Root $root
$kenv = Get-DeEnv -Root $root
$logDir = $cfg.Dir['logs']

$authUrl = '{0}/oauth/authorize?client_id={1}&redirect_uri={2}&response_type=code' -f `
    'https://kauth.kakao.com', `
    [Uri]::EscapeDataString($kenv['KAKAO_REST_API_KEY']), `
    [Uri]::EscapeDataString($kenv['KAKAO_REDIRECT_URI'])

if ($Scope) {
    $authUrl = $authUrl + '&scope=' + [Uri]::EscapeDataString($Scope)
}
else {
    Write-Host ' * 진단 모드: 동의항목(scope) 없이 인증만 시도합니다. 이 토큰으로는 발송이 안 됩니다.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host ' 1) 브라우저가 열리면 카카오 로그인 후 "동의하고 계속하기" 를 누르세요.' -ForegroundColor Cyan
Write-Host ' 2) 빈 페이지나 "연결할 수 없음" 화면이 나오는 것이 정상입니다.' -ForegroundColor Cyan
Write-Host '    주소창 전체를 복사해서 아래에 붙여넣으세요 (code=... 가 들어있는 주소).' -ForegroundColor Cyan
Write-Host ''
Write-Host " 열지 못하면 이 주소를 직접 붙여넣으세요:`n $authUrl" -ForegroundColor DarkGray
Write-Host ''

Start-Process $authUrl | Out-Null

$pasted = (Read-Host ' 주소 붙여넣기').Trim()
if (-not $pasted) { Write-Host ' 입력이 없어 취소했습니다.' -ForegroundColor Yellow; exit 1 }

$code = $pasted
if ($pasted -match '[?&]code=([^&\s]+)') { $code = $Matches[1] }
elseif ($pasted -match '^https?://') { throw '주소에 code= 가 없습니다. 동의를 마친 뒤의 주소를 붙여넣으세요.' }

Write-DeLog -LogDir $logDir -Message '인증 코드 수신 — 토큰 발급 요청'
$tokens = New-DeTokenFromCode -Config $cfg -Env $kenv -Code $code

Write-DeLog -Level 'DONE' -LogDir $logDir -Message ('토큰 저장 완료 — state\tokens.json (access 만료 {0})' -f $tokens.access_expires_utc)

# 발송 권한이 실제로 붙었는지 먼저 확인한다. 선택 동의 항목은 체크하지 않으면 그냥 빠진다.
if ($Scope -like '*talk_message*') {
    $check = Test-DeMessageScope -AccessToken (Get-DeValidAccessToken -Config $cfg -Env $kenv)
    if (-not $check.Ok) {
        Write-DeLog -Level 'FAIL' -LogDir $logDir -Message ('메시지 전송 권한이 없습니다 — {0}' -f $check.Reason)
        Write-Host ''
        Write-Host ' 다시 시도할 때, 동의 화면에서 "카카오톡 메시지 전송" 왼쪽 체크박스를' -ForegroundColor Yellow
        Write-Host ' 반드시 켠 뒤 [동의하고 계속하기] 를 누르세요. (선택 동의는 기본이 꺼짐입니다)' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }
    Write-DeLog -Level 'DONE' -LogDir $logDir -Message '메시지 전송 권한 확인됨 (talk_message 동의)'
}

if (-not $NoTestMessage) {
    $token = Get-DeValidAccessToken -Config $cfg -Env $kenv
    $r = Send-DeKakaoMemo -AccessToken $token -Text "✅ daily-english 설정 완료`n월~금 오전 7시에 오늘의 문장을 보내 드립니다." -ButtonTitle $cfg.buttonTitle
    if ($r.result_code -eq 0) {
        Write-DeLog -Level 'DONE' -LogDir $logDir -Message '테스트 메시지 발송 성공 — 카카오톡 "나와의 채팅" 을 확인하세요.'
    }
    else {
        Write-DeLog -Level 'WARN' -LogDir $logDir -Message ('테스트 메시지 응답이 이상합니다: {0}' -f ($r | ConvertTo-Json -Compress))
    }
}

Write-Host ''
Write-Host ' 이제 register-task.cmd 로 매일 오전 7시 발송을 등록하면 됩니다.' -ForegroundColor Green
