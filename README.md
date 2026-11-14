# privacygate

PrivacyGate 공통 보안 모듈(Python 패키지)과 전체 실행 환경 (가상 결혼정보회사 '이음').

```
privacygate/
├─ src/privacygate/     공통 보안 패키지 (internal-api, transfer-api 가 설치해서 사용)
├─ tests/               패키지 단위 시험 + 실행 환경 시험(망 분리, 스키마, 비밀값 제외)
├─ compose.yaml         전체 서비스 실행 (../matchmaking-internal, ../matchmaking-external 함께 빌드)
├─ .env.example         환경변수 목록 (.env 는 Git 제외)
└─ infra/
   ├─ db/business/      matchmaking_business 스키마·앱 계정·합성 시험 데이터 (business-db)
   ├─ db/transfer/      matchmaking_transfer 스키마·앱 계정 (transfer-db)
   ├─ keycloak/         realm matchmaking (client, 역할, 시험 계정)
   ├─ wazuh/            탐지 규칙 초안
   ├─ scripts/          init-env.sh (.env·증빙 키 생성)
   └─ secrets/          증빙 암호화 키 (Git 제외)
```

## 실행

세 레포를 같은 상위 폴더에 clone 한 뒤 이 폴더에서:

```bash
./infra/scripts/init-env.sh
docker compose up -d --build                     # 내부만 (keycloak, internal-web, internal-api, business-db)
# docker compose --profile external up -d --build  # 외부·중계까지 (../matchmaking-external 필요)
```

| 주소 | 용도 |
| --- | --- |
| https://localhost:8080 | 직원 화면 |
| https://localhost:8081 | Keycloak (관리 콘솔 `/admin`, 계정 infra_admin) |
| https://localhost:8090 | 회원 화면 |

HTTPS 인증서는 `init-env.sh` 가 만든다. [mkcert](https://github.com/FiloSottile/mkcert) 가 설치돼 있으면(`mkcert -install` 한 번) 브라우저 경고가 없고, 없으면 자체 서명이라 처음 한 번 '계속 진행'이 필요하다.

시험 계정 `counselor_a`, `counselor_b`, `data_admin`(총관리자), `approver`, `member_b` — 비밀번호는 `.env` 의 `KC_TEST_PASSWORD`.

합성 회원 추가: `./infra/scripts/add-member.sh 5` — 회원 코드는 자동 발급, 담당 상담 직원은 DB 트리거가 무작위로 배정한다 (시드 회원 20명은 counselor_a·counselor_b 에 10명씩 고정 배정).

코드 규칙 (관리자 화면·감사 로그 전용, 회원 화면에는 표시하지 않음)
- 직원: `<A~Z>-<역할><2자리>` — 역할 C=상담, D=총관리자(data_admin), P=승인 (예: `A-C01`, `A-D01`, `A-P01`)
- 회원: `<A~Z>-<3자리>` — `A-001` … `A-999` 다음 `B-001` (DB 가 자동 발급)

시험 데이터를 처음 상태로 되돌리기 (업무 DB·중계 DB·Keycloak·증빙 저장소 모두 초기화): `docker compose ... down -v` 후 다시 `up -d --build`
서비스 이미지에는 이 레포의 `pyproject.toml`·`README.md`·`src/` 만 복사된다 (`.env`·`infra/` 는 들어가지 않음).

## 패키지

| 모듈 | 내용 |
| --- | --- |
| `privacygate.policy` | 역할 코드(`counselor`, `data_admin`, `approver`, `member`), 기본 거부, 신청자≠승인자, 토큰 realm 역할 해석 |
| `privacygate.session_rules` | 세션 유휴·최대 만료, CSRF 토큰·Origin 검사 |
| `privacygate.tokens` | 무작위 토큰, PKCE(S256), 세션 ID 해시 |
| `privacygate.audit` | 감사 기록: 허용 필드만, 한 줄 한 건 JSON (`trace_id` 포함) |
| `privacygate.errors` | 공통 오류 코드·응답 형식 (`AUTH_REQUIRED`, `ACCESS_DENIED`, `APPROVAL_MISMATCH` …) |
| `privacygate.transfer_rules` | 제공 판단: 수신자·승인 상태·만료·동의·파일 버전·해시·검사 결과 (공격 ② 차단) |
| `privacygate.web` | FastAPI 연동: trace_id, 오류 처리, 역할·서비스 토큰 가드, 권한 선언 누락 검사 |

## 사용

로컬 개발·시험:

```bash
pip install -e ".[web]"
python -m unittest discover -s tests -v   # 실행 환경 시험은 PyYAML 필요
```

## 원칙

- 판단 근거(reason)는 응답에 넣지 않고 감사 로그에만 남긴다.
- 감사 로그에는 정해진 필드만 들어간다. 이름·연락처·파일 내용·비밀번호·세션 값은 넣을 수 없다.
- 이 레포를 고치면 내부·외부 담당 모두 PR 리뷰한다.
- `.env`, `infra/secrets/` 는 절대 커밋하지 않는다. 커밋 전 `git status` 확인.
