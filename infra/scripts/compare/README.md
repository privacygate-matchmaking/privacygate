# 최종 보안 비교 시연 (baseline vs enforce)

같은 요청을 **취약 비교 버전(baseline)**과 **보안 적용 버전(enforce)**에 보내고, 응답·실제 파일·감사 로그·Wazuh 경보를 증거 폴더로 모아 비교 보고서를 만든다. 모든 데이터는 합성 데이터다.

baseline은 공격 ①②가 노리는 통제 2개만 끈다. 로그인·세션·CSRF·승인·동의·만료·무결성 검사는 두 모드 모두 동작한다.

| 시나리오 | 공격 | baseline 기대 | enforce 기대 | Wazuh |
|---|---|---|---|---|
| ① | 상담 직원이 총관리자 전용 "전체 회원 내보내기" 호출 → 파일을 중계에 등록 | 201, 내보내기 파일 생성, 중계 등록(검사 차단 상태) | 403 ×3, 파일 없음 | 100132(허용·우회 기록) / 100110 ×2 → 100112(반복 거부) |
| ② | 승인 자료를 받은 회원이 다운로드 요청의 `file_id`만 ①의 파일로 바꿔치기 | 200, 전체 회원 CSV 반환 | 403 `requested_file_not_approved` | 100131(연결 검사 생략) / 100111(승인 파일 불일치) |

## 파일

| 파일 | 역할 |
|---|---|
| `run-mode.sh baseline\|enforce` | internal-api·transfer-api·external-api만 해당 모드로 다시 띄움 (.env 수정 없음) |
| `attack-console.js` | 브라우저 Console에 붙여 넣는 공격 ①② 요청 코드. 두 모드에서 그대로 사용 |
| `collect-evidence.sh <모드> <since>` | 응답 기록·감사 로그(DB+JSON)·파일 기록·저장소 목록·Wazuh 경보를 `evidence/<시각>-<모드>/`에 모음 |
| `make-report.py <baseline 폴더> <enforce 폴더>` | 비교표 `evidence/report.md` 생성 |

`evidence/`는 Git 제외다. 합성 데이터라도 외부에 올리지 않는다.

## 두 PC 시연 (Tailscale Funnel)

서버는 컴퓨터 1(Mac) 한 대, 공격 ①은 Mac(또는 tailnet 직원 PC)의 counselor_a 탭, 공격 ②는 **외부 PC(Windows, Tailscale 없음)** 브라우저에서 Funnel 공개 주소(`https://<이름>.<tailnet>.ts.net`)로 로그인한 member_001 탭에서 실행한다. 설정은 `../../funnel/README.md`. `.env` 에 `KC_ADMIN_URL` 이 있으면 아래 스크립트들이 `compose.funnel.yaml` 을 자동으로 함께 쓴다.

시연 전에 외부 PC 에서 `check-exposure.ps1` 로 네트워크 분리 증거(`exposure-<시각>.csv`)를 남기고 `evidence/` 로 옮긴다. 공격 ②의 Console 코드는 그대로 쓰되, 외부 PC 브라우저의 회원 탭에서 실행한다.

## 0. Wazuh 켜기 (Mac, 처음 한 번)

matchmaking-external 폴더에서 실행한다. Docker Desktop 설정에서 메모리 8GB 이상, CPU 4개 이상을 배정해야 한다. 최초 설치는 Docker 디스크 여유 50GiB가 필요하다.

```bash
.venv/bin/python -m pip install -r requirements-wazuh.txt
.venv/bin/python scripts/wazuh.py prepare
.venv/bin/python scripts/wazuh.py check
.venv/bin/python scripts/wazuh.py start
```

`vm.max_map_count` 안내가 나오면 다음을 실행하고 `start`를 다시 실행한다.

```bash
docker run --rm --privileged alpine sysctl -w vm.max_map_count=262144
```

몇 분 기다린 뒤 규칙과 수집을 확인한다.

```bash
.venv/bin/python scripts/wazuh.py rules
.venv/bin/python scripts/wazuh.py smoke
```

대시보드는 `https://localhost:8444`(admin / `.local/wazuh/credentials.json`의 `INDEXER_PASSWORD`)이다. 비밀번호는 공유하지 않는다.

## 1. 사전 준비 (enforce 상태에서 한 번)

공격 ②에는 회원이 정상적으로 받은 승인 자료가 1건 필요하다.

1. member_b와 member_001이 매칭을 성립시킨다(시험 결제 → 신청 → 수락).
2. member_b가 "내 공개 범위 설정"에서 학력 등 아무 항목이나 공개 동의한다.
3. counselor_a가 매칭·동의·일정 → 상세에서 그 항목으로 발송 승인 요청을 한다.
4. approver가 승인한다. member_001의 "제공 자료"에 1건이 생기면 준비가 끝난다.

직원 두 명(counselor_a, approver)과 회원은 서로 다른 브라우저나 프로필을 쓴다.

## 2. baseline 시연

privacygate 폴더에서 실행한다.

```bash
./infra/scripts/compare/run-mode.sh baseline     # 마지막 줄의 since 시각을 복사
```

1. counselor_a 탭(https://localhost:8080)에서 Cmd+Shift+R로 새로고침한 뒤 Console(Cmd+Option+J)을 연다. `attack-console.js`의 **공격 ①** 블록을 붙여 넣고 실행한다. 출력된 `file_id`를 복사한다.
2. member_001 탭(https://localhost:8090)에서 새로고침한 뒤 Console을 연다. **공격 ②** 블록의 `FILE_ID` 자리에 그 값을 넣고 실행한다.
3. 증거를 모은다.

```bash
./infra/scripts/compare/collect-evidence.sh baseline <복사한 since 시각>
```

## 3. enforce 시연 (같은 요청)

```bash
./infra/scripts/compare/run-mode.sh enforce
```

1. counselor_a 탭에서 새로고침하고 **공격 ①**을 그대로 실행한다(3회 거부).
2. member_001 탭에서 새로고침하고 **공격 ②**를 baseline 때와 **같은 FILE_ID**로 실행한다.
3. 증거를 모은다.

```bash
./infra/scripts/compare/collect-evidence.sh enforce <since 시각>
```

## 4. 보고서

```bash
python3 infra/scripts/compare/make-report.py evidence/<시각>-baseline evidence/<시각>-enforce
```

`evidence/report.md`에 두 모드의 응답·파일·감사 로그·Wazuh 경보·판정이 한 표로 정리된다.

판정은 API 응답과 실제로 생성·반환된 파일로 한다. Wazuh 경보는 탐지 증거이며, 경보만으로 차단 성공을 판정하지 않는다.

## 5. 끝나면

- 모드가 enforce인지 다시 확인한다. `run-mode.sh enforce`의 출력에 세 서비스 모두 `GATE_MODE=enforce`로 나와야 한다.
- baseline 시연으로 생긴 내보내기 파일과 중계 파일은 시험 기록이다. 필요하면 시연 기록 정리 명령으로 지운다.
