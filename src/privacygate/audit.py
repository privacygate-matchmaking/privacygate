"""감사 기록.

정해진 필드만 허용해 회원 이름·연락처·파일 내용·비밀번호·세션 값이 로그에 들어갈 길을 막는다.
한 줄 한 건 JSON 으로 파일에 쓰고(→ Wazuh), 필요하면 DB 기록 함수도 함께 호출한다.

공통 형식 (내부·외부·중계·PrivacyGate 동일): 발생 시각·서비스·trace_id·요청자/역할·작업·결과·거부 사유 +
정책 버전(policy_version) + 해당될 때 자료 소유자·수신자 UUID, 동의·승인·파일 ID, 파일 해시.

위변조 탐지: 파일의 각 줄에 seq(일련번호)·prev_hash(앞 줄 해시)·hash(이 줄 해시)를 붙인 해시 체인.
한 줄이라도 고치거나 지우거나 순서를 바꾸면 verify_chain 이 그 위치를 알려 준다.
파일은 0640 으로 만든다. DB audit_log 는 앱 계정에 INSERT 만 주고, 수정·삭제는 DB 트리거가 막는다.
"""
import hashlib
import json
import logging
import os
import threading
from datetime import datetime, timezone
from typing import Callable

POLICY_VERSION = "privacygate-2026.11-r3"   # 판단 규칙이 바뀌면 올린다 (감사 기록마다 남김)

FIELDS = ("ts", "service", "trace_id", "actor", "role", "action",
          "target_type", "target_id", "result", "reason", "policy_version",
          # 자료 제공 관련 표준 필드 (해당될 때만)
          "owner_id", "recipient_id", "consent_id", "approval_id", "file_id", "file_hash")
DETAIL_FIELDS = ("owner_id", "recipient_id", "consent_id", "approval_id", "file_id", "file_hash")
CHAIN_FIELDS = ("seq", "prev_hash", "hash")
GENESIS = "0" * 64
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


def chain_hash(prev_hash: str, event: dict) -> str:
    """hash = sha256(prev_hash + 정렬된 JSON(이벤트, hash 제외))."""
    body = {k: v for k, v in event.items() if k != "hash"}
    canonical = json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256((prev_hash + canonical).encode("utf-8")).hexdigest()


def verify_chain(lines) -> list[str]:
    """감사 파일 줄들을 검사해 문제 목록을 돌려준다 (빈 목록 = 정상).
    서비스 재시작은 앞 줄을 이어 받으므로 체인이 끊기지 않는다. 체인 필드가 없는 예전 줄은 건너뛴다."""
    problems, prev, seq, started = [], None, None, False
    for no, raw in enumerate(lines, 1):
        raw = raw.strip()
        if not raw:
            continue
        try:
            event = json.loads(raw)
        except ValueError:
            problems.append(f"{no}행: JSON 형식 아님")
            prev = hashlib.sha256(raw.encode("utf-8")).hexdigest()
            continue
        if "hash" not in event:
            if started:
                problems.append(f"{no}행: 체인 필드 없음 (삽입 의심)")
            continue
        if event.get("hash") != chain_hash(event.get("prev_hash", ""), event):
            problems.append(f"{no}행(seq {event.get('seq')}): 내용이 바뀜 (해시 불일치)")
        if started and event.get("prev_hash") != prev:
            problems.append(f"{no}행(seq {event.get('seq')}): 앞 줄과 연결이 끊김 (삭제·순서 변경 의심)")
        if started and seq is not None and str(event.get("seq", "")).isdigit() and int(event["seq"]) != seq + 1:
            problems.append(f"{no}행: 일련번호 {seq} 다음이 {event.get('seq')} (누락)")
        started = True
        prev = event.get("hash")
        seq = int(event["seq"]) if str(event.get("seq", "")).isdigit() else None
    return problems


def _tail(path: str) -> tuple[int, str]:
    """파일 마지막 줄에서 (seq, hash) 를 이어 받는다. 없으면 (0, GENESIS)."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 8192))
            lines = [ln for ln in f.read().splitlines() if ln.strip()]
    except OSError:
        return 0, GENESIS
    if not lines:
        return 0, GENESIS
    last = lines[-1]
    try:
        event = json.loads(last)
        if "hash" in event and str(event.get("seq", "")).isdigit():
            return int(event["seq"]), event["hash"]
    except ValueError:
        pass
    # 체인 없는 예전 줄이거나 손상: 마지막 줄 자체의 해시에서 새로 시작 (검사 도구가 경계를 보고함)
    return 0, hashlib.sha256(last).hexdigest()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class AuditWriter:
    """서비스별 감사 기록기. db_insert 를 넘기면 DB 에도 기록한다 (DB 에는 체인 필드를 넣지 않는다)."""

    def __init__(self, service: str, path: str, db_insert: Callable[[dict], None] | None = None):
        self.service = service
        self.path = path
        self.db_insert = db_insert
        self._lock = threading.Lock()
        self._seq, self._prev = _tail(path)

    def record(self, *, trace_id: str, action: str, result: str, actor: str | None = None,
               role: str | None = None, target_type: str | None = None,
               target_id: str | None = None, reason: str | None = None, **detail: str | None) -> dict:
        unknown = set(detail) - set(DETAIL_FIELDS)
        if unknown:
            raise ValueError(f"허용되지 않은 감사 필드: {sorted(unknown)}")
        event = build_event(ts=now_iso(), service=self.service, trace_id=trace_id, actor=actor,
                            role=role, action=action, target_type=target_type,
                            target_id=target_id, result=result, reason=reason,
                            policy_version=POLICY_VERSION, **detail)
        with self._lock:
            self._seq += 1
            line = {k: v for k, v in event.items() if v is not None or k not in DETAIL_FIELDS}
            line["seq"] = str(self._seq)
            line["prev_hash"] = self._prev
            line["hash"] = chain_hash(self._prev, line)
            self._prev = line["hash"]   # 쓰기에 실패해도 체인은 진행 → 다음 줄에서 '누락'으로 드러난다
            try:
                fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
                with os.fdopen(fd, "a", encoding="utf-8") as f:
                    f.write(to_json_line(line))
            except OSError:
                _log.exception("감사 로그 파일 쓰기 실패")
        if self.db_insert is not None:
            try:
                self.db_insert(event)
            except Exception:  # 감사 DB 장애가 차단 결정을 바꾸지 않게 한다
                _log.exception("감사 로그 DB 기록 실패")
        return event
