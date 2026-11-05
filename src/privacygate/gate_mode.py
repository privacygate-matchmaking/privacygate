"""PrivacyGate 동작 모드 (.env 의 GATE_MODE).

- enforce (기본): 모든 통제 적용.
- baseline: 시연용 비교 모드. 공격 ①②가 노리는 두 통제만 끈다.
    ① 관리자 내보내기의 역할 검사 → 로그인한 직원이면 누구나 통과
    ② 다운로드의 승인 파일 검증 → 수신자만 확인하고 요청한 file_id 를 그대로 제공
  로그인·세션·CSRF·감사 로그는 baseline 에서도 그대로 동작한다.
잘못된 값이면 서버가 시작하지 않는다.
"""
import os

ENFORCE = "enforce"
BASELINE = "baseline"
MODES = (ENFORCE, BASELINE)


def current(env=None) -> str:
    value = (env if env is not None else os.environ).get("GATE_MODE", ENFORCE).strip().lower()
    if value not in MODES:
        raise RuntimeError(f"GATE_MODE 는 {MODES} 중 하나여야 합니다: {value!r}")
    return value


def is_baseline(env=None) -> bool:
    return current(env) == BASELINE
