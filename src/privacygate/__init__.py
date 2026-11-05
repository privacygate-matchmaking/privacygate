"""PrivacyGate 공통 보안 모듈.

내부 백엔드(internal-api)와 반출 중계 백엔드(transfer-api)가 같은 규칙으로 통제하도록
권한·세션·감사·오류 형식·승인 파일 검증을 한곳에 모은다.

- 순수 로직 (표준 라이브러리만): tokens, policy, session_rules, audit, errors, transfer_rules
- FastAPI 연동 (선택 설치 `privacygate[web]`): web
"""

__version__ = "0.1.0"
