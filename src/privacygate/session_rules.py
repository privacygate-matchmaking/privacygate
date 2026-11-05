"""세션 만료·CSRF 판단."""
from datetime import datetime, timedelta
from urllib.parse import urlsplit

from .tokens import same


def session_problem(now: datetime, last_seen_at: datetime, absolute_expires_at: datetime,
                    idle_seconds: int) -> str | None:
    """세션을 쓸 수 없으면 사유 코드를, 쓸 수 있으면 None 을 돌려준다."""
    if now >= absolute_expires_at:
        return "session_max_expired"
    if now - last_seen_at >= timedelta(seconds=idle_seconds):
        return "session_idle_expired"
    return None


def origin_of(url: str) -> str:
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}"


def csrf_problem(expected_token: str | None, sent_token: str | None,
                 origin_header: str | None, app_base_url: str) -> str | None:
    """상태를 바꾸는 요청: Origin 이 우리 화면이고, 세션별 CSRF 토큰이 맞아야 한다."""
    if not origin_header or origin_header != origin_of(app_base_url):
        return "bad_origin"
    if not same(expected_token, sent_token):
        return "bad_csrf_token"
    return None
