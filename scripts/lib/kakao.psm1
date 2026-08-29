# daily-english 공통 라이브러리 — 카카오 "나에게 보내기" + 문장 목록/진행상태
# Windows PowerShell 5.1 기준. 외부 의존성 없음 (Invoke-RestMethod 만 쓴다).

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:AuthBase = 'https://kauth.kakao.com'
$script:ApiBase = 'https://kapi.kakao.com'

# ── 시간·로그 ────────────────────────────────────────────────────────────────

function Get-KstNow {
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('Korea Standard Time')
    return [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz)
}

function Write-DeLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'FAIL', 'DONE')][string]$Level = 'INFO',
        [string]$LogDir
    )
    $now = Get-KstNow
    $line = '{0} [{1}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'FAIL'  { Write-Host $line -ForegroundColor Red }
        'DONE'  { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    if ($LogDir) {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $LogDir ('daily-english-{0}.log' -f $now.ToString('yyyy-MM'))) -Value $line -Encoding utf8
    }
}

# ── 설정 / 비밀값 ───────────────────────────────────────────────────────────

function Get-DeConfig {
    param([Parameter(Mandatory = $true)][string]$Root)

    $path = Join-Path $Root 'config.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "설정 파일이 없습니다: $path" }
    $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json

    $dirs = @{}
    foreach ($k in 'data', 'state', 'logs') {
        $full = Join-Path $Root $k
        if (-not (Test-Path -LiteralPath $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
        $dirs[$k] = (Resolve-Path -LiteralPath $full).Path
    }
    $cfg | Add-Member -NotePropertyName 'Root' -NotePropertyValue $Root -Force
    $cfg | Add-Member -NotePropertyName 'Dir' -NotePropertyValue $dirs -Force
    return $cfg
}

function Get-DeEnv {
    # .env 에서 KEY=VALUE 를 읽는다. 값에 = 가 있어도 첫 = 만 기준으로 자른다.
    param([Parameter(Mandatory = $true)][string]$Root)

    $path = Join-Path $Root '.env'
    if (-not (Test-Path -LiteralPath $path)) {
        throw ".env 가 없습니다. .env.example 을 복사해서 카카오 REST API 키를 채우세요: $path"
    }
    $map = @{}
    foreach ($raw in (Get-Content -LiteralPath $path -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $map[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim().Trim('"')
    }
    if (-not $map['KAKAO_REST_API_KEY']) { throw '.env 의 KAKAO_REST_API_KEY 가 비어 있습니다.' }
    if (-not $map['KAKAO_REDIRECT_URI']) { $map['KAKAO_REDIRECT_URI'] = 'http://localhost:8910/callback' }
    # KAKAO_CLIENT_SECRET 은 선택. 앱에서 Client Secret 을 "사용" 으로 켰다면 반드시 필요하다
    # (안 보내면 토큰 발급이 KOE010 / Bad client credentials 로 떨어진다).
    if (-not $map.ContainsKey('KAKAO_CLIENT_SECRET')) { $map['KAKAO_CLIENT_SECRET'] = '' }
    return $map
}

function Add-DeClientSecret {
    # 폼 바디에 client_secret 을 붙인다 (설정돼 있을 때만).
    param(
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)]$Env
    )
    if ($Env['KAKAO_CLIENT_SECRET']) {
        return ($Body + '&client_secret=' + [Uri]::EscapeDataString($Env['KAKAO_CLIENT_SECRET']))
    }
    return $Body
}

# ── 토큰 ────────────────────────────────────────────────────────────────────

function Get-DeHttpErrorDetail {
    # 카카오 API 는 실패 이유를 응답 본문 JSON 에 담아 준다.
    # PS 5.1 의 Invoke-RestMethod 예외에서는 그 본문이 버려지므로 직접 읽어 낸다.
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $detail = $ErrorRecord.Exception.Message
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $bodyText = $reader.ReadToEnd()
            $reader.Close()
            if ($bodyText) { $detail = '{0} / 응답: {1}' -f $detail, $bodyText.Trim() }
        }
    }
    catch { }

    # 자주 나오는 코드에 사람 말 설명을 붙인다.
    $hints = @{
        'KOE006' = 'Redirect URI 불일치 — 앱 설정의 리다이렉트 URI 와 .env 의 KAKAO_REDIRECT_URI 가 글자 단위로 같아야 합니다.'
        'KOE010' = '앱에 Client Secret 이 "사용" 으로 켜져 있습니다 — .env 에 KAKAO_CLIENT_SECRET 을 넣거나, 카카오 로그인 > 보안에서 Client Secret 을 "사용 안 함" 으로 바꾸세요.'
        'KOE101' = 'REST API 키(client_id)가 잘못되었습니다 — 앱 키 화면의 REST API 키인지 확인하세요.'
        'KOE320' = '인증 코드가 이미 사용되었거나 만료되었습니다 — setup.cmd 를 다시 실행해 새 코드를 받으세요.'
        'KOE237' = '요청이 너무 많습니다 — 잠시 후 다시 시도하세요.'
    }
    foreach ($code in $hints.Keys) {
        if ($detail -like ('*' + $code + '*')) { $detail = '{0}  [{1}: {2}]' -f $detail, $code, $hints[$code] }
    }
    if ($detail -like '*insufficient scope*' -or $detail -like '*-402*') {
        $detail = $detail + '  [동의항목 문제: 카카오 로그인 > 동의항목에서 "카카오톡 메시지 전송" 을 선택 동의로 켜고, setup.cmd 로 다시 동의하세요.]'
    }
    return $detail
}

function Get-DeTokenPath {
    param([Parameter(Mandatory = $true)]$Config)
    return (Join-Path $Config.Dir['state'] 'tokens.json')
}

function Save-DeTokens {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Response
    )
    $path = Get-DeTokenPath -Config $Config
    $now = (Get-Date).ToUniversalTime()

    $existing = $null
    if (Test-Path -LiteralPath $path) {
        $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    # 갱신 응답에는 refresh_token 이 없을 수 있다 — 그때는 기존 값을 유지한다.
    $refresh = $Response.refresh_token
    if (-not $refresh -and $existing) { $refresh = $existing.refresh_token }
    $refreshExpiresIn = $Response.refresh_token_expires_in
    if (-not $refreshExpiresIn -and $existing) { $refreshExpiresIn = 0 }

    $refreshExpiresUtc = ''
    if ([int]$refreshExpiresIn -gt 0) {
        $refreshExpiresUtc = $now.AddSeconds([int]$refreshExpiresIn).ToString('o')
    }
    elseif ($existing -and $existing.refresh_expires_utc) {
        $refreshExpiresUtc = $existing.refresh_expires_utc
    }

    $data = [pscustomobject]@{
        access_token        = $Response.access_token
        refresh_token       = $refresh
        access_expires_utc  = $now.AddSeconds([int]$Response.expires_in).ToString('o')
        refresh_expires_utc = $refreshExpiresUtc
        saved_utc           = $now.ToString('o')
    }
    $data | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
    return $data
}

function Get-DeTokens {
    param([Parameter(Mandatory = $true)]$Config)
    $path = Get-DeTokenPath -Config $Config
    if (-not (Test-Path -LiteralPath $path)) {
        throw '인증 정보가 없습니다. setup.cmd 를 먼저 한 번 실행하세요.'
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function New-DeTokenFromCode {
    # 최초 1회: 인증 코드를 토큰으로 바꾼다.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Env,
        [Parameter(Mandatory = $true)][string]$Code
    )
    $body = 'grant_type=authorization_code&client_id={0}&redirect_uri={1}&code={2}' -f `
        [Uri]::EscapeDataString($Env['KAKAO_REST_API_KEY']), `
        [Uri]::EscapeDataString($Env['KAKAO_REDIRECT_URI']), `
        [Uri]::EscapeDataString($Code)
    $body = Add-DeClientSecret -Body $body -Env $Env

    try {
        $r = Invoke-RestMethod -Method Post -Uri ($script:AuthBase + '/oauth/token') `
            -ContentType 'application/x-www-form-urlencoded;charset=utf-8' -Body $body
    }
    catch {
        throw ('토큰 발급 실패 — {0}' -f (Get-DeHttpErrorDetail -ErrorRecord $_))
    }
    return (Save-DeTokens -Config $Config -Response $r)
}

function Get-DeValidAccessToken {
    # 만료 10분 전이면 미리 갱신한다. refresh_token 은 갱신 시 함께 내려올 때만 교체된다.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Env
    )
    $t = Get-DeTokens -Config $Config
    $now = (Get-Date).ToUniversalTime()

    $needsRefresh = $true
    if ($t.access_expires_utc) {
        $exp = [DateTime]::Parse($t.access_expires_utc).ToUniversalTime()
        if ($exp -gt $now.AddMinutes(10)) { $needsRefresh = $false }
    }
    if (-not $needsRefresh) { return $t.access_token }

    if (-not $t.refresh_token) {
        throw '갱신 토큰이 없습니다. setup.cmd 로 다시 인증하세요.'
    }
    $body = 'grant_type=refresh_token&client_id={0}&refresh_token={1}' -f `
        [Uri]::EscapeDataString($Env['KAKAO_REST_API_KEY']), `
        [Uri]::EscapeDataString($t.refresh_token)
    $body = Add-DeClientSecret -Body $body -Env $Env

    try {
        $r = Invoke-RestMethod -Method Post -Uri ($script:AuthBase + '/oauth/token') `
            -ContentType 'application/x-www-form-urlencoded;charset=utf-8' -Body $body
    }
    catch {
        throw ('토큰 갱신 실패 (setup.cmd 재실행이 필요할 수 있습니다) — {0}' -f (Get-DeHttpErrorDetail -ErrorRecord $_))
    }
    $saved = Save-DeTokens -Config $Config -Response $r
    return $saved.access_token
}

# ── 발송 ────────────────────────────────────────────────────────────────────

function Get-DeScopes {
    # 이 토큰이 실제로 어떤 동의항목을 받았는지 조회한다.
    # 앱에 항목이 있어도(using=true) 사용자가 체크하지 않으면 agreed=false 다.
    param([Parameter(Mandatory = $true)][string]$AccessToken)

    try {
        $r = Invoke-RestMethod -Method Get -Uri ($script:ApiBase + '/v2/user/scopes') `
            -Headers @{ Authorization = ('Bearer ' + $AccessToken) }
        return $r.scopes
    }
    catch {
        throw ('동의항목 조회 실패 — {0}' -f (Get-DeHttpErrorDetail -ErrorRecord $_))
    }
}

function Test-DeMessageScope {
    # talk_message 에 동의했는지. 발송 전에 확인해서 -402 를 사람 말로 바꿔 준다.
    param([Parameter(Mandatory = $true)][string]$AccessToken)

    $scopes = Get-DeScopes -AccessToken $AccessToken
    $tm = $scopes | Where-Object { $_.id -eq 'talk_message' } | Select-Object -First 1
    if (-not $tm) {
        return [pscustomobject]@{ Ok = $false; Reason = 'talk_message 동의항목이 앱에 설정되어 있지 않습니다 (카카오 로그인 > 동의항목).' }
    }
    if (-not $tm.agreed) {
        return [pscustomobject]@{ Ok = $false; Reason = '동의 화면에서 "카카오톡 메시지 전송" 에 체크하지 않았습니다. setup.cmd 를 다시 실행해 체크박스를 켜고 동의하세요.' }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Send-DeKakaoMemo {
    # 카카오톡 "나에게 보내기" — 텍스트 템플릿 + 링크 버튼.
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Url,
        [string]$ButtonTitle = '쇼츠 보기'
    )
    if ($Text.Length -gt 200) { $Text = $Text.Substring(0, 197) + '...' }   # 텍스트 템플릿 상한 200자

    $template = @{ object_type = 'text'; text = $Text }
    if ($Url) {
        $template['link'] = @{ web_url = $Url; mobile_web_url = $Url }
        $template['button_title'] = $ButtonTitle
    }
    else {
        $template['link'] = @{}
    }

    $json = $template | ConvertTo-Json -Depth 5 -Compress
    $body = 'template_object=' + [Uri]::EscapeDataString($json)

    return Invoke-RestMethod -Method Post -Uri ($script:ApiBase + '/v2/api/talk/memo/default/send') `
        -Headers @{ Authorization = ('Bearer ' + $AccessToken) } `
        -ContentType 'application/x-www-form-urlencoded;charset=utf-8' -Body $body
}

# ── 문장 목록 / 진행 상태 ───────────────────────────────────────────────────

function Get-DePhrases {
    param([Parameter(Mandatory = $true)]$Config)

    $path = Join-Path $Config.Dir['data'] $Config.phraseFile
    if (-not (Test-Path -LiteralPath $path)) { throw "문장 목록이 없습니다: $path" }

    $items = New-Object System.Collections.Generic.List[object]
    $first = $true
    foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        if ($first) { $first = $false; if ($line -like 'no*phrase*') { continue } }
        $c = $line -split "`t"
        if ($c.Count -lt 3) { continue }
        $items.Add([pscustomobject]@{ No = [int]$c[0]; Phrase = $c[1].Trim(); Url = $c[2].Trim() })
    }
    # @($items) 는 PS 5.1 에서 List[object] 를 감쌀 때 터진다 — ToArray() 로 넘긴다.
    return $items.ToArray()
}

function Get-DeProgress {
    param([Parameter(Mandatory = $true)]$Config)
    $path = Join-Path $Config.Dir['state'] 'progress.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ nextNo = [int]$Config.startNo; lastSentNo = 0; lastSentDate = ''; sentNos = @() }
    }
    $p = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    # 옛 파일에는 sentNos 가 없다. JSON 배열은 1개일 때 스칼라로 오므로 @() 로 감싼다.
    if (-not ($p.PSObject.Properties.Name -contains 'sentNos')) {
        $p | Add-Member -NotePropertyName 'sentNos' -NotePropertyValue @() -Force
    }
    else {
        $p.sentNos = @($p.sentNos)
    }
    return $p
}

function Get-DeNextItem {
    # 다음에 보낼 문장을 고른다. nextNo 이상에서 제외 목록에 없는 첫 번호.
    #  - config.skipNos  : 이미 다른 경로로 보낸 것 등, 영구히 건너뛸 번호
    #  - progress.sentNos: 이 도구가 보낸 번호 (중복 방지)
    param(
        [Parameter(Mandatory = $true)]$Phrases,
        [Parameter(Mandatory = $true)]$Progress,
        [Parameter(Mandatory = $true)]$Config
    )
    $skip = New-Object System.Collections.Generic.HashSet[int]
    foreach ($n in @($Config.skipNos)) { if ($n) { [void]$skip.Add([int]$n) } }
    foreach ($n in @($Progress.sentNos)) { if ($n) { [void]$skip.Add([int]$n) } }

    $candidates = $Phrases | Where-Object { $_.No -ge [int]$Progress.nextNo -and -not $skip.Contains([int]$_.No) } | Sort-Object No
    $item = $candidates | Select-Object -First 1
    if ($item) { return $item }

    # 뒤쪽이 다 걸렀다면(=한 바퀴 끝) loop 설정일 때만 앞에서 다시 찾는다.
    if ($Config.onFinish -eq 'loop') {
        $again = $Phrases | Where-Object { -not $skip.Contains([int]$_.No) } | Sort-Object No | Select-Object -First 1
        if ($again) { return $again }
    }
    return $null
}

function Save-DeProgress {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Progress
    )
    $path = Join-Path $Config.Dir['state'] 'progress.json'
    $Progress | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
}

function Format-DeMessage {
    # config.messageTemplate 의 {no} {phrase} {url} {total} 을 치환한다.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Item,
        [int]$Total = 0
    )
    $text = $Config.messageTemplate -join "`n"
    $text = $text.Replace('{no}', ('{0:d3}' -f $Item.No))
    $text = $text.Replace('{phrase}', $Item.Phrase)
    $text = $text.Replace('{url}', $Item.Url)
    $text = $text.Replace('{total}', [string]$Total)
    return $text
}

function Test-DeSendDay {
    # 오늘이 발송 요일인지 (KST 기준).
    param([Parameter(Mandatory = $true)]$Config)
    $today = (Get-KstNow).DayOfWeek.ToString().Substring(0, 3)   # Mon, Tue, ...
    return ($Config.weekdays -contains $today)
}

Export-ModuleMember -Function `
    Get-KstNow, Write-DeLog, Get-DeConfig, Get-DeEnv, Get-DeHttpErrorDetail, `
    Get-DeTokens, Save-DeTokens, New-DeTokenFromCode, Get-DeValidAccessToken, `
    Get-DeScopes, Test-DeMessageScope, `
    Send-DeKakaoMemo, Get-DePhrases, Get-DeProgress, Save-DeProgress, Get-DeNextItem, `
    Format-DeMessage, Test-DeSendDay
