"""서비스 간 mTLS 확인 (서비스 컨테이너 안에서 실행). mtls-check.sh 가 부른다.
각 대상에 ① 내 인증서로 ② 인증서 없이 ③ 평문 HTTP 로 접속해 결과를 출력한다. 인증서 내용·키는 출력하지 않는다."""
import os
import ssl
import sys

import httpx
from privacygate import mtls

targets = sys.argv[1:]
ca = os.getenv("MTLS_CA_FILE")
if not mtls.enabled():
    print("mTLS 꺼짐 (MTLS_* 환경 변수 없음) — compose.mtls.yaml 을 composeArgs 에 넣었는지 확인")
    sys.exit(1)


def attempt(label, fn):
    try:
        r = fn()
        return f"{label}: 연결됨 (HTTP {r.status_code})"
    except httpx.HTTPError as exc:
        return f"{label}: 차단 ({type(exc).__name__})"


bad = 0
for host in targets:
    url = f"https://{host}:8000/health"
    with_cert = attempt("내 서비스 인증서", lambda: httpx.get(url, timeout=5, **mtls.client_options()))
    no_cert = attempt("인증서 없이", lambda: httpx.get(url, timeout=5, verify=ssl.create_default_context(cafile=ca)))
    plain = attempt("평문 HTTP", lambda: httpx.get(f"http://{host}:8000/health", timeout=5))
    print(f"[{host}]\n  {with_cert}\n  {no_cert}\n  {plain}")
    if "연결됨" not in with_cert or "연결됨" in no_cert or "연결됨" in plain:
        bad += 1
print("결과:", "정상 — 인증서가 있는 서비스만 연결" if not bad else "확인 필요")
sys.exit(1 if bad else 0)
