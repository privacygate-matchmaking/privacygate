"""privacygate.web.install 의 거부 후속 훅(on_deny) 시험. fastapi 가 없으면 건너뛴다.

- 거부 응답 전에 훅이 (사유 코드와 함께) 한 번 불린다
- 훅이 실패해도 거부 응답(상태·오류 코드)은 그대로다 → 사후 대응 장애가 차단 결정을 바꾸지 않는다
- 감사 기록 파일을 쓸 수 없어도 거부 응답은 그대로다 (Wazuh 수집 중단 대비)
"""
import tempfile
import unittest
from pathlib import Path

try:
    from fastapi import Depends, FastAPI, Request
    from fastapi.testclient import TestClient
except ImportError:
    FastAPI = None


@unittest.skipIf(FastAPI is None, "fastapi 필요")
class OnDenyHook(unittest.TestCase):
    def make(self, hook, audit_path=None):
        from privacygate.audit import AuditWriter
        from privacygate.policy import Principal
        from privacygate.web import install, role_guard

        tmp = tempfile.mkdtemp()
        app = FastAPI()
        install(app, AuditWriter("test", audit_path or str(Path(tmp) / "audit.json")), on_deny=hook)

        def who(request: Request) -> Principal:
            p = Principal("u1", "A-C01", "counselor")
            request.state.principal = p
            return p

        require = role_guard(who)

        @app.post("/api/admin/x")
        def admin_only(p=Depends(require("data_admin"))):
            return {"ok": True}

        @app.get("/api/ok")
        def ok(p=Depends(require("counselor"))):
            return {"ok": True}

        return TestClient(app), Path(tmp)

    def test_hook_called_with_reason(self):
        seen = []
        c, _ = self.make(lambda request, exc: seen.append((exc.reason, request.state.principal.pseudo_id)))
        r = c.post("/api/admin/x")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(seen, [("role_not_allowed", "A-C01")])
        self.assertEqual(c.get("/api/ok").status_code, 200)
        self.assertEqual(len(seen), 1)   # 허용 요청에는 부르지 않음

    def test_hook_failure_keeps_denial(self):
        def broken(request, exc):
            raise RuntimeError("incident store down")
        c, _ = self.make(broken)
        r = c.post("/api/admin/x")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["error"]["code"], "ACCESS_DENIED")

    def test_audit_file_failure_keeps_denial(self):
        c, _ = self.make(None, audit_path="/nonexistent-dir/audit.json")
        self.assertEqual(c.post("/api/admin/x").status_code, 403)


if __name__ == "__main__":
    unittest.main()
