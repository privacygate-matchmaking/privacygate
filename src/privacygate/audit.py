"""감사 기록.

정해진 필드만 허용해 회원 이름·연락처·파일 내용·비밀번호·세션 값이 로그에 들어갈 길을 막는다.
한 줄 한 건 JSON 으로 파일에 쓰고(→ Wazuh), 필요하면 DB 기록 함수도 함께 호출한다.
"""
import json
import logging
import threading
from datetime import datetime, timezone
from typing import Callable

FIELDS = ("ts", "service", "trace_id", "actor", "role", "action",
          "target_type", "target_id", "result", "reason")
REQUIRED = ("ts", "service", "trace_id", "action", "result")
RESULTS = frozenset({"allow", "deny", "error"})
MAX_LEN = 128

_log = logging.getLogger("privacygate.audit")


def build_event(**fields) -> dict:
    unknown = set(fields) - set(FIELDS)
    if unknown:
        raise ValueError(f"허용되지 않은 감사 필드: {sorted(unknown)}")
    for name in REQUIRED:
        if not fields.get(name):
            raise ValueError(f"필수 감사 필드 누락: {name}")
    if fields["result"] not in RESULTS:
        raise ValueError(f"result 값 오류: {fields['result']}")
    event = {}
    for name in FIELDS:
        value = fields.get(name)
        if value is not None:
            if not isinstance(value, str):
                raise ValueError(f"감사 필드는 문자열만 허용: {name}")
            if len(value) > MAX_LEN:
                raise ValueError(f"감사 필드가 너무 깁니다: {name}")
        event[name] = value
    return event


def to_json_line(event: dict) -> str:
    """Wazuh JSON 디코더가 읽는 한 줄 한 건 형식."""
    return json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class AuditWriter:
    """서비스별 감사 기록기. db_insert 를 넘기면 DB 에도 기록한다."""

    def __init__(self, service: str, path: str, db_insert: Callable[[dict], None] | None = None):
        self.service = service
        self.path = path
        self.db_insert = db_insert
        self._lock = threading.Lock()

    def record(self, *, trace_id: str, action: str, result: str, actor: str | None = None,
               role: str | None = None, target_type: str | None = None,
               target_id: str | None = None, reason: str | None = None) -> dict:
        event = build_event(ts=now_iso(), service=self.service, trace_id=trace_id, actor=actor,
                            role=role, action=action, target_type=target_type,
                            target_id=target_id, result=result, reason=reason)
        try:
            with self._lock, open(self.path, "a", encoding="utf-8") as f:
                f.write(to_json_line(event))
        except OSError:
            _log.exception("감사 로그 파일 쓰기 실패")
        if self.db_insert is not None:
            try:
                self.db_insert(event)
            except Exception:  # 감사 DB 장애가 차단 결정을 바꾸지 않게 한다
                _log.exception("감사 로그 DB 기록 실패")
        return event
