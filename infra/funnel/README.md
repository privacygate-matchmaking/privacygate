# Tailscale Funnel 배포 (무료, 컴퓨터 1 = Mac 서버)

Mac 한 대에서 지금의 Docker Compose 전체를 그대로 실행하고, **회원 화면과 회원 로그인만 인터넷에 공개**한다. 직원 화면·Keycloak 관리·Wazuh 는 **Tailscale 에 로그인한 팀원 기기(tailnet)에서만** 열린다. 서비스 사이의 Docker 내부 네트워크 분리는 그대로다.

```
[외부 PC · Windows]  Tailscale 미설치, 아무 인터넷(휴대폰 핫스팟 등)
        │ HTTPS (인터넷 → Tailscale Funnel 중계)
        ▼
https://<이름>.<tailnet>.ts.net        Funnel 443  → external-web (회원 화면)
https://<이름>.<tailnet>.ts.net:8443   Funnel 8443 → auth-gateway → Keycloak (/realms/matchmaking, /resources 만)
        │
[컴퓨터 1 · Mac]  Docker Compose 전체 (+ Wazuh)
        │ tailnet 전용 (tailscale serve)
        ├─ :8080 직원 화면 (internal-web)
        ├─ :8081 Keycloak 관리자 화면
        └─ :8444 Wazuh 대시보드
        ▲
[직원 PC]  Tailscale 에 로그인한 팀원 노트북 (또는 Mac 자체)
```

| 경계 | 무엇이 막나 |
|---|---|
| Funnel 공개 범위 | 인터넷에는 443(회원 화면)·8443(회원 로그인 경로)만 열림 |
| auth-gateway | 8443 에서도 `/admin`, master realm, 계정 콘솔은 404 |
| tailnet | 직원 화면·Keycloak 관리·Wazuh 는 팀원 기기만 |
| Docker 내부망 | external-api 는 업무 DB·증빙 저장소·internal-api 와 망을 공유하지 않음 |

## 0. 준비 (처음 한 번)

1. **Tailscale 계정**: https://login.tailscale.com 에서 무료 가입 (Google·GitHub 계정 로그인).
2. **Mac 에 설치**: https://tailscale.com/download/mac 에서 **Standalone(다운로드판)** 을 설치하고 로그인한다. 메뉴 막대 아이콘이 Connected 면 된다.
3. **기기 이름**: 관리 콘솔 Machines → Mac 의 `…` → Edit machine name → `ieum` 처럼 짧게. 공개 주소가 `ieum.<tailnet>.ts.net` 이 된다.
4. **MagicDNS·HTTPS 켜기**: 관리 콘솔 DNS 탭 → MagicDNS **Enable**, 아래 HTTPS Certificates **Enable**.
5. **직원 PC**: 직원 화면을 다른 노트북에서 쓸 팀원은 같은 Tailscale 계정(또는 초대받은 계정)으로 Tailscale 을 설치·로그인한다. **외부 PC(공격자 역할 회원)에는 설치하지 않는다.**
6. **잠자기 끄기**: 시연하는 동안 Mac 은 전원 연결, 시스템 설정 → 배터리 → "디스플레이가 꺼져 있을 때 자동으로 잠자기 방지" 켜기.

터미널에서 `tailscale` 명령이 없으면 한 번 실행한다.

```bash
alias tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
tailscale status
```

## 1. 주소 정하기

privacygate 폴더에서:

```bash
./infra/scripts/funnel.sh urls
```

출력된 4줄(`KC_PUBLIC_URL`, `KC_ADMIN_URL`, `INTERNAL_BASE_URL`, `EXTERNAL_BASE_URL`)을 **privacygate/.env** 에 넣는다(같은 이름이 있으면 바꾼다). 공개 주소라 비밀값은 아니지만 .env 는 커밋하지 않는다.

로컬(localhost)로 되돌릴 때는 이 4줄을 지우거나 주석 처리하면 된다.

## 2. 서비스 다시 시작

matchmaking-external 폴더에서 (composeArgs 에 `compose.funnel.yaml` 추가):

```bash
composeArgs=(--project-directory ../privacygate --env-file ../privacygate/.env --env-file ./.local/internal-admin.env -f ../privacygate/compose.yaml -f ../privacygate/compose.funnel.yaml -f ./compose.external.yaml -f ./compose.member-lifecycle.yaml --profile external)
docker compose "${composeArgs[@]}" up -d keycloak auth-gateway
docker compose "${composeArgs[@]}" up keycloak-setup
docker compose "${composeArgs[@]}" up -d --force-recreate internal-api transfer-api external-api internal-web external-web
```

- `keycloak-setup` 출력에 `internal-web: https://ieum.…:8080 (+ https://localhost:8080)`, `external-web: https://ieum.… (+ https://localhost:8090)` 가 나오면 로그인 후 돌아올 주소가 맞춰진 것이다.
- 새 터미널마다 위 `composeArgs=(...)` 줄을 다시 실행한다.

## 3. 공개 시작

privacygate 폴더에서:

```bash
./infra/scripts/funnel.sh up
```

처음 실행하면 Funnel 사용 허락 링크가 나올 수 있다. 링크를 열어 허용한 뒤 다시 실행한다. 끝에 공개 주소 목록과 `tailscale funnel status` 가 나온다.

## 4. 확인

**Mac(또는 직원 PC, tailnet 연결)**
1. `https://ieum.<tailnet>.ts.net:8080` → 직원 로그인 → counselor_a 로그인 성공
2. `https://ieum.<tailnet>.ts.net:8444` → Wazuh 대시보드 (Wazuh 를 켠 경우)

**외부 PC(Windows, Tailscale 없음, 가능하면 휴대폰 핫스팟)**
1. `https://ieum.<tailnet>.ts.net` → 회원 로그인·회원가입 정상
2. 네트워크 분리 증거: `privacygate/infra/scripts/compare/check-exposure.ps1` 을 외부 PC 로 복사해 PowerShell 에서

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\check-exposure.ps1 -Target ieum.<tailnet>.ts.net
   ```

   회원 화면·로그인은 성공, `/admin`·master realm·계정 콘솔은 404, 직원 화면·Keycloak 관리·Wazuh·DB 는 연결 실패여야 하며 모두 PASS 로 나온다. 생성된 `exposure-<시각>.csv` 를 증거로 보관한다.

## 5. 끝나면

```bash
./infra/scripts/funnel.sh down
```

Funnel·serve 가 꺼져 인터넷·tailnet 공개가 모두 사라진다(Docker 서비스는 그대로). 공개 주소의 `.ts.net` 이름은 인증서 기록으로 외부에 보일 수 있으므로 시연할 때만 켠다.

## 문제 해결

| 증상 | 확인 |
|---|---|
| 로그인 후 "Invalid redirect uri" | `.env` 주소 4줄 확인 → `up keycloak-setup` 다시 실행 |
| 로그인 화면이 안 열림 (8443) | `docker compose … ps auth-gateway` 가 실행 중인지, `funnel.sh status` 에 8443 이 있는지 |
| 로그인은 되는데 401·세션 끊김 | API 3개를 `--force-recreate` 로 다시 시작했는지 (APP_BASE_URL 반영) |
| Keycloak 관리자 화면이 공개 주소로 넘어감 | `KC_ADMIN_URL` 이 .env 에 있는지, keycloak 을 다시 시작했는지 |
| 외부 PC 에서 직원 화면이 열림 | 외부 PC 가 Tailscale 에 연결돼 있지 않은지 확인 (연결돼 있으면 끊고 다시 시험) |

## 보안 메모

- 인터넷에 열리는 것은 회원 화면과 회원 로그인 경로뿐이며, 나머지는 tailnet 또는 127.0.0.1 에만 있다.
- 로그인 전 요청(회원가입·직원 가입 신청)의 요청 횟수 제한은 Tailscale 이 전달한 실제 접속 주소 기준이다(nginx `real_ip`).
- 모든 데이터는 합성 데이터다. 실제 개인정보·비밀번호는 넣지 않는다. Keycloak 관리자 비밀번호(.env)는 공유하지 않는다.
- `GATE_MODE` 는 시연 때도 기본 `enforce`, 비교 촬영 때만 `baseline` (compare/README.md).
