"""서비스 간 mTLS (상호 TLS) 클라이언트 설정.

compose.mtls.yaml 을 켜면 internal-api·transfer-api 가 사설 CA 가 서명한 클라이언트 인증서가 있는 연결만 받는다
(uvicorn --ssl-cert-reqs 2). 호출하는 쪽(internal-api·transfer-api·external-api)은 아래 환경 변수로 자기 인증서를 낸다.
  MTLS_CA_FILE   : 상대 서버 인증서를 검증할 CA
  MTLS_CERT_FILE : 내 인증서,  MTLS_KEY_FILE : 내 개인키
값이 없으면 기존처럼 평문 HTTP (내부 망 + 서비스 토큰). 서비스 토큰 검사는 mTLS 와 별개로 계속한다.
"""
import os
import ssl


def enabled() -> bool:
    return all(os.getenv(k) for k in ("MTLS_CA_FILE", "MTLS_CERT_FILE", "MTLS_KEY_FILE"))


def client_context() -> ssl.SSLContext | None:
    if not enabled():
        return None
    ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=os.environ["MTLS_CA_FILE"])
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.environ["MTLS_CERT_FILE"], os.environ["MTLS_KEY_FILE"])
    return ctx


def client_options() -> dict:
    """httpx.Client(...)/httpx.request(...) 에 펼쳐 넣는 인자. mTLS 가 꺼져 있으면 빈 dict."""
    ctx = client_context()
    return {"verify": ctx} if ctx else {}
