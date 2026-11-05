"""FastAPI 연동 (pip install privacygate[web]).

- install(): trace_id 부여, 공통 오류 응답, 거부·오류 감사 기록
- role_guard(): 경로별 허용 역할 선언 (기본 거부)
- service_guard(): 서버 간 호출의 서비스 토큰 검증 (Keycloak client credentials)
- assert_all_routes_guarded(): 권한 선언 없는 /api 경로가 있으면 앱 시작 거부
"""
import logging
import uuid
from typing import Callable

import jwt
from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from starlette.exceptions import HTTPException as StarletteHTTPException

from .audit import AuditWriter
from .errors import ErrorCode, GateError, error_body
from . import gate_mode
from .policy import STAFF_ROLES, Principal, is_allowed

_log = logging.getLogger("privacygate.web")
POLICY_ATTR = "__privacygate_policy__"
TRACE_HEADER = "X-Trace-Id"

_HTTP_CODE = {401: ErrorCode.AUTH_REQUIRED, 403: ErrorCode.ACCESS_DENIED, 404: ErrorCode.NOT_FOUND,
              409: ErrorCode.INVALID_STATE, 422: ErrorCode.INVALID_REQUEST}


def trace_id(request: Request) -> str:
    return getattr(request.state, "trace_id", "-")


def route_action(request: Request) -> str:
    """실제 ID 대신 경로 템플릿을 남긴다 (예: GET /api/members/{member_id})."""
    route = request.scope.get("route")
    return f"{request.method} {getattr(route, 'path', request.url.path)}"


def audit_request(audit: AuditWriter, request: Request, result: str, *, action: str | None = None,
                  reason: str | None = None, target_type: str | None = None,
                  target_id: str | None = None) -> None:
    principal: Principal | None = getattr(request.state, "principal", None)
    service = getattr(request.state, "service_client", None)
    audit.record(trace_id=trace_id(request), action=action or route_action(request), result=result,
                 actor=principal.pseudo_id if principal else (f"svc:{service}" if service else None),
                 role=principal.role if principal else None,
                 target_type=target_type, target_id=target_id, reason=reason)


def install(app: FastAPI, audit: AuditWriter) -> None:
    @app.middleware("http")
    async def _trace(request: Request, call_next):
        request.state.trace_id = uuid.uuid4().hex
        response = await call_next(request)
        response.headers[TRACE_HEADER] = request.state.trace_id
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.exception_handler(GateError)
    async def _gate(request: Request, exc: GateError):
        audit_request(audit, request, "deny", reason=exc.reason)
        return JSONResponse(error_body(exc.code, trace_id(request), exc.message), status_code=exc.status)

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException):
        code = _HTTP_CODE.get(exc.status_code, ErrorCode.INTERNAL_ERROR)
        return JSONResponse(error_body(code, trace_id(request)), status_code=exc.status_code)

    @app.exception_handler(RequestValidationError)
    async def _invalid(request: Request, exc: RequestValidationError):
        return JSONResponse(error_body(ErrorCode.INVALID_REQUEST, trace_id(request)), status_code=422)

    @app.exception_handler(Exception)
    async def _unexpected(request: Request, exc: Exception):
        _log.exception("처리하지 못한 오류")
        audit_request(audit, request, "error", reason="unexpected_error")
        return JSONResponse(error_body(ErrorCode.INTERNAL_ERROR, trace_id(request)), status_code=500)


def role_guard(principal_dependency: Callable[..., Principal]):
    """principal_dependency 로 로그인 사용자를 얻은 뒤 허용 역할을 확인하는 require(*roles) 를 만든다."""

    def require(*roles, baseline_open: bool = False):
        """baseline_open=True 인 경로만 GATE_MODE=baseline 에서 역할 검사를 건너뛴다 (로그인한 직원이면 통과).
        시연 비교용이며 기본(enforce)에서는 아무 영향이 없다."""
        allowed = frozenset(r.value if hasattr(r, "value") else r for r in roles)

        def dependency(request: Request,
                       principal: Principal = Depends(principal_dependency)) -> Principal:
            if not is_allowed(principal.role, allowed):
                if baseline_open and gate_mode.is_baseline() and principal.role in STAFF_ROLES:
                    request.state.gate_bypass = "baseline_role_check_off"
                    return principal
                raise GateError(ErrorCode.ACCESS_DENIED, "role_not_allowed")
            return principal

        setattr(dependency, POLICY_ATTR, f"roles:{','.join(sorted(allowed))}")
        return dependency

    return require


class ServiceTokenVerifier:
    """Keycloak 이 발급한 서비스 토큰(JWT) 검증: 서명·iss·aud·exp."""

    def __init__(self, jwks_url: str, issuer: str, audience: str):
        self.issuer = issuer
        self.audience = audience
        self._jwks = jwt.PyJWKClient(jwks_url, cache_keys=True)

    def verify(self, token: str) -> dict:
        try:
            key = self._jwks.get_signing_key_from_jwt(token)
            return jwt.decode(token, key.key, algorithms=["RS256"], audience=self.audience,
                              issuer=self.issuer, options={"require": ["exp", "iss", "aud", "azp"]},
                              leeway=30)
        except jwt.PyJWTError as exc:
            raise GateError(ErrorCode.AUTH_REQUIRED, "service_token_invalid") from exc


def service_guard(get_verifier: Callable[[], ServiceTokenVerifier], *allowed_clients: str):
    """서버 간 API: Authorization: Bearer <서비스 토큰>, azp 가 허용된 클라이언트여야 한다."""
    allowed = frozenset(allowed_clients)

    def dependency(request: Request) -> dict:
        header = request.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            raise GateError(ErrorCode.AUTH_REQUIRED, "service_token_missing")
        claims = get_verifier().verify(header[7:])
        request.state.service_client = claims.get("azp")
        if claims.get("azp") not in allowed:
            raise GateError(ErrorCode.ACCESS_DENIED, "service_not_allowed")
        return claims

    setattr(dependency, POLICY_ATTR, f"service:{','.join(sorted(allowed))}")
    return dependency


def _has_policy(dependant) -> bool:
    return any(getattr(d.call, POLICY_ATTR, None) is not None or _has_policy(d)
               for d in dependant.dependencies)


def assert_all_routes_guarded(app: FastAPI, prefix: str = "/api") -> None:
    """기본 거부: 허용 역할·서비스를 선언하지 않은 /api 경로가 있으면 시작하지 않는다."""
    missing = [f"{','.join(sorted(r.methods))} {r.path}" for r in app.routes
               if isinstance(r, APIRoute) and r.path.startswith(prefix) and not _has_policy(r.dependant)]
    if missing:
        raise RuntimeError(f"권한 선언이 없는 경로: {missing}")


def _policies(dependant) -> list[str]:
    found = []
    for d in dependant.dependencies:
        policy = getattr(d.call, POLICY_ATTR, None)
        if policy:
            found.append(policy)
        found.extend(_policies(d))
    return found


def route_policies(app: FastAPI) -> dict[tuple[str, str], list[str]]:
    """(메서드, 경로) → 선언된 정책 목록. 권한 표(docs/permissions.md)와 비교하는 시험에 쓴다."""
    return {(m, r.path): _policies(r.dependant)
            for r in app.routes if isinstance(r, APIRoute) for m in r.methods}
