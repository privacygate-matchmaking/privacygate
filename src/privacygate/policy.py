"""권한 판단.

- 기본 거부: 허용 역할을 선언하지 않았거나 모르는 역할이면 거부한다.
- 역할은 서버가 매 요청 확인한 값만 쓴다 (토큰 claim·클라이언트 값 불신).
- 신청자와 승인자는 달라야 한다 (직무 분리).
"""
from dataclasses import dataclass
from enum import Enum
from typing import Iterable


class Role(str, Enum):
    COUNSELOR = "counselor"      # 회원 상담 담당자
    DATA_ADMIN = "data_admin"    # 데이터 관리자
    APPROVER = "approver"        # 반출 승인 담당자
    MEMBER = "member"            # 외부 회원


KNOWN_ROLES = frozenset(r.value for r in Role)
STAFF_ROLES = frozenset({Role.COUNSELOR.value, Role.DATA_ADMIN.value, Role.APPROVER.value})


@dataclass(frozen=True)
class Principal:
    user_id: str      # 로그인 사용자 식별자 (Keycloak sub)
    pseudo_id: str    # 로그·화면용 가명 ID
    role: str


def _values(items: Iterable) -> frozenset:
    return frozenset(i.value if isinstance(i, Enum) else i for i in items)


def is_allowed(role: str | None, allowed: Iterable) -> bool:
    allowed = _values(allowed)
    if not allowed:
        return False                      # 선언 없음 → 거부
    if role not in KNOWN_ROLES:
        return False                      # 모르는 역할 → 거부
    return role in allowed


def can_decide_request(approver: Principal, requester_id: str) -> bool:
    """반출 신청 승인·거절은 승인 담당자이면서 신청자 본인이 아니어야 한다."""
    return approver.role == Role.APPROVER.value and approver.user_id != requester_id


def role_from_claims(claims: dict) -> str | None:
    """Keycloak 토큰의 realm_access.roles 에서 업무 역할 하나를 고른다.

    업무 역할이 없거나 둘 이상이면 None (권한 없음으로 처리). transfer-api 처럼
    업무 DB 에 접근하지 않는 서버가 서명된 토큰만으로 역할을 확인할 때 쓴다.
    """
    roles = (claims.get("realm_access") or {}).get("roles") or []
    found = [r for r in roles if r in KNOWN_ROLES]
    return found[0] if len(found) == 1 else None
