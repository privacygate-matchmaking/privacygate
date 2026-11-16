# 네트워크 분리 증거 (외부 PC = 컴퓨터 2, Windows PowerShell 에서 실행)
# 외부 PC 는 Tailscale 에 연결하지 않은 상태여야 한다.
#
#   powershell -ExecutionPolicy Bypass -File .\check-exposure.ps1 -Target ieum.<tailnet>.ts.net
#
# 기대 결과
#   회원 화면(443)·회원 로그인 경로(8443 /realms/matchmaking)   → 성공
#   Keycloak /admin·master realm (8443)                       → 404 (문지기가 차단)
#   직원 화면(8080)·Keycloak 관리(8081)·Wazuh(8444)·DB(5432)    → 연결 실패 (tailnet 전용 또는 비공개)
# 결과는 화면과 exposure-<시각>.csv 로 남긴다 (evidence 폴더로 옮겨 보고서에 사용).
param([Parameter(Mandatory = $true)][string]$Target)

$ErrorActionPreference = 'Stop'
$results = @()

function Test-Http($name, $url, $expect) {
    $status = ''
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -MaximumRedirection 0
        $status = [string][int]$r.StatusCode
    } catch {
        $resp = $_.Exception.Response
        if ($resp) { $status = [string][int]$resp.StatusCode } else { $status = 'connect_failed' }
    }
    $ok = switch ($expect) {
        'success' { $status -match '^(2|3)\d\d$' }
        '404'     { $status -eq '404' }
        'blocked' { $status -eq 'connect_failed' }
    }
    $script:results += [pscustomobject]@{ 항목 = $name; 주소 = $url; 결과 = $status; 기대 = $expect; 판정 = $(if ($ok) { 'PASS' } else { 'FAIL' }) }
}

function Test-Tcp($name, $port) {
    $client = New-Object System.Net.Sockets.TcpClient
    $open = $false
    try { $open = $client.ConnectAsync($Target, $port).Wait(5000) -and $client.Connected } catch { $open = $false } finally { $client.Close() }
    $script:results += [pscustomobject]@{ 항목 = $name; 주소 = "${Target}:$port"; 결과 = $(if ($open) { 'open' } else { 'connect_failed' }); 기대 = 'blocked'; 판정 = $(if ($open) { 'FAIL' } else { 'PASS' }) }
}

$ts = Get-Command tailscale -ErrorAction SilentlyContinue
if ($ts) {
    $state = (& tailscale status 2>$null | Select-Object -First 1)
    if ($state -and $state -notmatch 'stopped|Logged out') { Write-Warning '이 PC 가 Tailscale 에 연결되어 있습니다. 외부 PC 시험은 Tailscale 연결을 끊고 실행하세요.' }
}

# TLS 1.2 (Windows PowerShell 5.1 기본값 보완)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Test-Http '회원 화면'            "https://$Target/"                                                     'success'
Test-Http '회원 로그인(OIDC)'    "https://${Target}:8443/realms/matchmaking/.well-known/openid-configuration" 'success'
Test-Http 'Keycloak 관리 API'    "https://${Target}:8443/admin/"                                       '404'
Test-Http 'master realm'         "https://${Target}:8443/realms/master/"                               '404'
Test-Http '계정 콘솔'            "https://${Target}:8443/realms/matchmaking/account/"                  '404'
Test-Http '직원 화면'            "https://${Target}:8080/"                                             'blocked'
Test-Http 'Keycloak 관리 화면'   "https://${Target}:8081/admin/"                                       'blocked'
Test-Http 'Wazuh 대시보드'       "https://${Target}:8444/"                                             'blocked'
Test-Tcp  '업무 DB(PostgreSQL)'  5432
Test-Tcp  'internal-api'         8000

$results | Format-Table -AutoSize
$file = "exposure-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
$results | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
$fail = @($results | Where-Object { $_.판정 -eq 'FAIL' }).Count
Write-Host ("저장: {0}  (PASS {1} / FAIL {2})" -f $file, ($results.Count - $fail), $fail)
