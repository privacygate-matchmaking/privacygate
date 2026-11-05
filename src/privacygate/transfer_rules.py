"""반출 제공 판단 (transfer-api 에서 사용).

검사 통과와 제공 승인은 별개다. 검사 완료 파일이어도 수신자·동의·승인·만료 조건이 맞아야 제공한다.
다운로드는 delivery_id 로만 요청받고, 제공할 파일은 서버가 승인 기록에서 고른다.
요청에 다른 file_id 가 끼어 있으면 거부한다 (공격 ② 차단).
"""
from dataclasses import dataclass
from datetime import datetime

from .errors import ErrorCode


@dataclass(frozen=True)
class ApprovedDelivery:
    """서버가 DB 에서 읽은 제공 건 (delivery → approval → request → file)."""
    delivery_id: str
    recipient_id: str
    request_status: str          # pending / approved / rejected / revoked / expired
    expires_at: datetime
    approved_file_id: str
    approved_file_version: int
    approved_file_hash: str
    consent_valid: bool          # 내부 시스템에 확인한 관계·동의 결과


@dataclass(frozen=True)
class StoredFile:
    """반출 저장 영역의 실제 파일 상태."""
    file_id: str
    file_version: int
    file_hash: str
    scan_status: str             # pending / passed / blocked / error


def delivery_problem(d: ApprovedDelivery, stored: StoredFile | None, *, requester_id: str,
                     now: datetime, requested_file_id: str | None = None) -> tuple[ErrorCode, str] | None:
    """제공할 수 없으면 (오류 코드, 감사용 사유), 제공 가능하면 None."""
    if requester_id != d.recipient_id:
        return ErrorCode.APPROVAL_MISMATCH, "recipient_mismatch"
    if requested_file_id is not None and requested_file_id != d.approved_file_id:
        return ErrorCode.APPROVAL_MISMATCH, "requested_file_not_approved"
    if d.request_status in ("revoked", "rejected", "pending"):
        return ErrorCode.ACCESS_DENIED, f"request_{d.request_status}"
    if d.request_status == "expired" or now >= d.expires_at:
        return ErrorCode.APPROVAL_EXPIRED, "approval_expired"
    if not d.consent_valid:
        return ErrorCode.CONSENT_INVALID, "consent_invalid"
    if stored is None:
        return ErrorCode.APPROVAL_MISMATCH, "approved_file_missing"
    if (stored.file_id, stored.file_version) != (d.approved_file_id, d.approved_file_version):
        return ErrorCode.APPROVAL_MISMATCH, "file_version_mismatch"
    if stored.file_hash != d.approved_file_hash:
        return ErrorCode.APPROVAL_MISMATCH, "file_hash_mismatch"
    if stored.scan_status != "passed":
        return ErrorCode.ACCESS_DENIED, f"scan_{stored.scan_status}"
    return None
