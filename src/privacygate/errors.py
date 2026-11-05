"""공통 오류 응답.

응답에는 공개해도 되는 오류 코드·문구만 담고, 판단 근거(reason)는 감사 로그에만 남긴다.
응답 형식: {"error": {"code": "...", "message": "...", "trace_id": "..."}}
"""
from enum import Enum


class ErrorCode(str, Enum):
    AUTH_REQUIRED = "AUTH_REQUIRED"          # 401 로그인하지 않음
    ACCESS_DENIED = "ACCESS_DENIED"          # 403 기능 실행·자료 접근 권한 없음
    APPROVAL_MISMATCH = "APPROVAL_MISMATCH"  # 403 승인 파일·수신자 조건 불일치
    APPROVAL_EXPIRED = "APPROVAL_EXPIRED"    # 403 승인 만료
    CONSENT_INVALID = "CONSENT_INVALID"      # 403 동의 철회·만료
    INVALID_STATE = "INVALID_STATE"          # 409 현재 상태에서 처리 불가
    NOT_FOUND = "NOT_FOUND"                  # 404 자원 없음 또는 존재를 공개하지 않음
    INVALID_REQUEST = "INVALID_REQUEST"      # 422 요청 형식·필수 값 오류
    INTERNAL_ERROR = "INTERNAL_ERROR"        # 500 예상하지 못한 서버 오류


STATUS = {
    ErrorCode.AUTH_REQUIRED: 401,
    ErrorCode.ACCESS_DENIED: 403,
    ErrorCode.APPROVAL_MISMATCH: 403,
    ErrorCode.APPROVAL_EXPIRED: 403,
    ErrorCode.CONSENT_INVALID: 403,
    ErrorCode.INVALID_STATE: 409,
    ErrorCode.NOT_FOUND: 404,
    ErrorCode.INVALID_REQUEST: 422,
    ErrorCode.INTERNAL_ERROR: 500,
}

MESSAGES = {
    ErrorCode.AUTH_REQUIRED: "로그인이 필요합니다.",
    ErrorCode.ACCESS_DENIED: "권한이 없습니다.",
    ErrorCode.APPROVAL_MISMATCH: "승인된 자료가 아닙니다.",
    ErrorCode.APPROVAL_EXPIRED: "승인 기간이 지났습니다.",
    ErrorCode.CONSENT_INVALID: "동의가 유효하지 않습니다.",
    ErrorCode.INVALID_STATE: "현재 상태에서는 처리할 수 없습니다.",
    ErrorCode.NOT_FOUND: "찾을 수 없습니다.",
    ErrorCode.INVALID_REQUEST: "요청 형식이 올바르지 않습니다.",
    ErrorCode.INTERNAL_ERROR: "서버 오류가 발생했습니다.",
}


class GateError(Exception):
    """거부·오류. reason 은 감사 로그용 내부 사유 코드이며 응답에 넣지 않는다."""

    def __init__(self, code: ErrorCode, reason: str | None = None, message: str | None = None):
        super().__init__(code.value)
        self.code = code
        self.status = STATUS[code]
        self.reason = reason or code.value.lower()
        self.message = message or MESSAGES[code]


def error_body(code: ErrorCode, trace_id: str, message: str | None = None) -> dict:
    return {"error": {"code": code.value, "message": message or MESSAGES[code], "trace_id": trace_id}}
