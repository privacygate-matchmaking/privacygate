"""감사 로그 해시 체인 검사 (internal-api 컨테이너 안에서 root 로 실행). audit-verify.sh 가 부른다.

- /var/log/matchmaking/{internal-api,transfer-api,external-api}.json 의 체인을 검사한다 (수정·삭제·순서 변경·누락).
- 결과를 같은 폴더의 audit-verifier.json 에 한 줄로 남긴다 → Wazuh 규칙 100160(체인 손상)·100161(파일 없음/수집 중단 의심).
- 회원 정보는 다루지 않는다 (줄 번호·일련번호·문제 종류만 출력).
"""
import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

from privacygate.audit import POLICY_VERSION, verify_chain

DIR = "/var/log/matchmaking"
SERVICES = ("internal-api", "transfer-api", "external-api")
IDLE_HOURS = float(os.environ.get("AUDIT_IDLE_HOURS", "0"))   # 0 이면 수집 중단(오래 기록 없음) 검사 안 함


def emit(result, reason, target, detail=""):
    event = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"), "service": "audit-verifier",
             "trace_id": uuid.uuid4().hex, "actor": "system", "role": None, "action": "audit.chain_verify",
             "target_type": "audit_file", "target_id": target, "result": result, "reason": reason,
             "policy_version": POLICY_VERSION}
    if detail:
        event["detail"] = detail[:120]
    fd = os.open(os.path.join(DIR, "audit-verifier.json"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")


bad = 0
for svc in SERVICES:
    path = os.path.join(DIR, svc + ".json")
    if not os.path.exists(path):
        print(f"[없음] {svc}.json")
        emit("error", "audit_file_missing", svc + ".json")
        bad += 1
        continue
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    problems = verify_chain(lines)
    chained = sum(1 for ln in lines if '"hash"' in ln)
    stale = ""
    if IDLE_HOURS and lines:
        try:
            last = datetime.fromisoformat(json.loads(lines[-1])["ts"])
            if datetime.now(timezone.utc) - last > timedelta(hours=IDLE_HOURS):
                stale = f"마지막 기록 {last.isoformat()}"
        except Exception:
            pass
    if problems:
        bad += 1
        print(f"[손상] {svc}.json — {len(problems)}건")
        for p in problems[:10]:
            print("   -", p)
        emit("error", "audit_chain_broken", svc + ".json", f"{len(problems)} problems; first: {problems[0]}")
    elif stale:
        bad += 1
        print(f"[중단 의심] {svc}.json — {stale}")
        emit("error", "audit_collection_stale", svc + ".json", stale)
    else:
        print(f"[정상] {svc}.json — 전체 {len(lines)}줄, 체인 {chained}줄")
        emit("allow", "audit_chain_ok", svc + ".json")
sys.exit(1 if bad else 0)
