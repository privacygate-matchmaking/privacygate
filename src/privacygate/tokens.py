"""난수 토큰·PKCE·해시."""
import base64
import hashlib
import hmac
import secrets


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def random_token(nbytes: int = 32) -> str:
    """세션 ID·state·nonce·CSRF 토큰용 무작위 값."""
    return b64url(secrets.token_bytes(nbytes))


def new_code_verifier() -> str:
    """RFC 7636: 43~128자. 32바이트 → 43자."""
    return b64url(secrets.token_bytes(32))


def code_challenge_s256(verifier: str) -> str:
    return b64url(hashlib.sha256(verifier.encode("ascii")).digest())


def token_hash(token: str) -> bytes:
    """세션 ID 등은 해시만 DB 에 저장한다."""
    return hashlib.sha256(token.encode("utf-8")).digest()


def same(a: str | bytes | None, b: str | bytes | None) -> bool:
    """타이밍 공격을 피하는 비교."""
    if a is None or b is None:
        return False
    if isinstance(a, str):
        a = a.encode("utf-8")
    if isinstance(b, str):
        b = b.encode("utf-8")
    return hmac.compare_digest(a, b)
