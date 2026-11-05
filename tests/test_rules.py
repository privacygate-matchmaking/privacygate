"""PrivacyGate 순수 로직 시험 (표준 라이브러리만 사용).

실행: python -m unittest discover -s tests -v   (privacygate 폴더에서, PYTHONPATH=src 또는 pip install -e .)
"""
import json
import unittest
from datetime import datetime, timedelta, timezone

from privacygate.audit import build_event, to_json_line
from privacygate.errors import STATUS, ErrorCode, GateError, error_body
from privacygate.policy import Principal, Role, can_decide_request, is_allowed
from privacygate.session_rules import csrf_problem, session_problem
from privacygate.tokens import code_challenge_s256, new_code_verifier, random_token, same
from privacygate.transfer_rules import ApprovedDelivery, StoredFile, delivery_problem

NOW = datetime(2026, 11, 5, 3, 0, tzinfo=timezone.utc)


class TokenTest(unittest.TestCase):
    def test_pkce_rfc7636_example(self):
        self.assertEqual(code_challenge_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                         "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

    def test_verifier_length(self):
        self.assertTrue(43 <= len(new_code_verifier()) <= 128)

    def test_tokens_unique(self):
        self.assertEqual(len({random_token() for _ in range(1000)}), 1000)

    def test_same(self):
        self.assertFalse(same(None, "a"))
        self.assertTrue(same(b"x", b"x"))


class PolicyTest(unittest.TestCase):
    def test_counselor_cannot_export_all_members(self):
        # 공격 ①: 상담 담당자가 관리자 전체 회원 내보내기를 직접 호출
        self.assertFalse(is_allowed("counselor", {Role.DATA_ADMIN}))

    def test_data_admin_can_export(self):
        self.assertTrue(is_allowed("data_admin", {Role.DATA_ADMIN}))

    def test_roles_not_granted_implicitly(self):
        self.assertFalse(is_allowed("data_admin", {Role.APPROVER}))     # 관리자에게 승인 권한 없음
        self.assertFalse(is_allowed("approver", {Role.DATA_ADMIN}))     # 승인자에게 내보내기 권한 없음

    def test_default_deny(self):
        self.assertFalse(is_allowed("data_admin", set()))
        self.assertFalse(is_allowed("admin", {"admin"}))
        self.assertFalse(is_allowed(None, {Role.DATA_ADMIN}))

    def test_requester_cannot_approve_own_request(self):
        approver = Principal("u-approver", "S-P01", "approver")
        self.assertTrue(can_decide_request(approver, requester_id="u-counselor"))
        self.assertFalse(can_decide_request(approver, requester_id="u-approver"))
        admin = Principal("u-admin", "S-D01", "data_admin")
        self.assertFalse(can_decide_request(admin, requester_id="u-counselor"))


class SessionTest(unittest.TestCase):
    def test_session_rules(self):
        self.assertIsNone(session_problem(NOW, NOW - timedelta(minutes=10), NOW + timedelta(hours=1), 1800))
        self.assertEqual(session_problem(NOW, NOW - timedelta(minutes=30), NOW + timedelta(hours=1), 1800),
                         "session_idle_expired")
        self.assertEqual(session_problem(NOW, NOW, NOW, 1800), "session_max_expired")

    def test_csrf(self):
        base = "http://localhost:8080"
        self.assertIsNone(csrf_problem("t", "t", "http://localhost:8080", base))
        self.assertEqual(csrf_problem("t", "t", "http://evil.example", base), "bad_origin")
        self.assertEqual(csrf_problem("t", "t", None, base), "bad_origin")
        self.assertEqual(csrf_problem("t", "x", "http://localhost:8080", base), "bad_csrf_token")


class AuditTest(unittest.TestCase):
    def base(self, **extra):
        return dict(ts=NOW.isoformat(), service="internal-api", trace_id="t1",
                    action="POST /api/admin/member-exports", result="deny", **extra)

    def test_one_json_line(self):
        line = to_json_line(build_event(**self.base(actor="S-A01", role="counselor", reason="role_not_allowed")))
        self.assertEqual(line.count("\n"), 1)
        self.assertEqual(json.loads(line)["trace_id"], "t1")

    def test_personal_data_fields_rejected(self):
        for key in ("contact_phone", "name", "password", "session_id", "file_content", "request_id"):
            with self.assertRaises(ValueError):
                build_event(**self.base(**{key: "x"}))

    def test_long_value_rejected(self):
        with self.assertRaises(ValueError):
            build_event(**self.base(reason="x" * 500))


class ErrorTest(unittest.TestCase):
    def test_codes_and_status(self):
        self.assertEqual(STATUS[ErrorCode.AUTH_REQUIRED], 401)
        self.assertEqual(STATUS[ErrorCode.APPROVAL_MISMATCH], 403)
        self.assertEqual(STATUS[ErrorCode.INVALID_STATE], 409)

    def test_reason_not_in_body(self):
        exc = GateError(ErrorCode.ACCESS_DENIED, "role_not_allowed")
        body = error_body(exc.code, "t1", exc.message)
        self.assertEqual(body["error"]["code"], "ACCESS_DENIED")
        self.assertNotIn("role_not_allowed", json.dumps(body))


class DeliveryTest(unittest.TestCase):
    def delivery(self, **kw):
        base = dict(delivery_id="d1", recipient_id="u-member-b", request_status="approved",
                    expires_at=NOW + timedelta(days=1), approved_file_id="f-ok", approved_file_version=1,
                    approved_file_hash="h-ok", consent_valid=True)
        base.update(kw)
        return ApprovedDelivery(**base)

    OK_FILE = StoredFile("f-ok", 1, "h-ok", "passed")

    def check(self, d, stored=OK_FILE, requester="u-member-b", requested=None):
        return delivery_problem(d, stored, requester_id=requester, now=NOW, requested_file_id=requested)

    def test_normal_delivery(self):
        self.assertIsNone(self.check(self.delivery()))

    def test_attack2_other_file_id(self):
        # 공격 ②: 정상 제공 건에 다른 file_id 를 끼워 넣음
        self.assertEqual(self.check(self.delivery(), requested="f-leaked"),
                         (ErrorCode.APPROVAL_MISMATCH, "requested_file_not_approved"))

    def test_other_recipient(self):
        self.assertEqual(self.check(self.delivery(), requester="u-other")[0], ErrorCode.APPROVAL_MISMATCH)

    def test_expired_and_revoked(self):
        self.assertEqual(self.check(self.delivery(expires_at=NOW))[0], ErrorCode.APPROVAL_EXPIRED)
        self.assertEqual(self.check(self.delivery(request_status="revoked"))[0], ErrorCode.ACCESS_DENIED)

    def test_consent_withdrawn(self):
        self.assertEqual(self.check(self.delivery(consent_valid=False))[0], ErrorCode.CONSENT_INVALID)

    def test_scan_passed_is_not_enough(self):
        # 검사 통과와 제공 승인은 별개: 파일이 바뀌었거나 검사 미통과면 거부
        self.assertEqual(self.check(self.delivery(), stored=StoredFile("f-ok", 1, "h-changed", "passed"))[1],
                         "file_hash_mismatch")
        self.assertEqual(self.check(self.delivery(), stored=StoredFile("f-ok", 1, "h-ok", "blocked"))[1],
                         "scan_blocked")




class RoleFromClaims(unittest.TestCase):
    def test_single_role(self):
        from privacygate.policy import role_from_claims
        self.assertEqual(role_from_claims({"realm_access": {"roles": ["offline_access", "approver"]}}), "approver")

    def test_none_or_ambiguous(self):
        from privacygate.policy import role_from_claims
        self.assertIsNone(role_from_claims({}))
        self.assertIsNone(role_from_claims({"realm_access": {"roles": ["approver", "data_admin"]}}))


class GateMode(unittest.TestCase):
    def test_default_enforce(self):
        from privacygate import gate_mode
        self.assertEqual(gate_mode.current({}), "enforce")
        self.assertFalse(gate_mode.is_baseline({}))

    def test_baseline_and_invalid(self):
        from privacygate import gate_mode
        self.assertTrue(gate_mode.is_baseline({"GATE_MODE": "baseline"}))
        with self.assertRaises(RuntimeError):
            gate_mode.current({"GATE_MODE": "off"})


class BaselineDelivery(unittest.TestCase):
    """baseline 은 수신자만 확인 → 공격 ②(다른 file_id) 가 통과한다. enforce 는 막는다."""
    def setUp(self):
        from datetime import datetime, timedelta, timezone
        from privacygate.transfer_rules import ApprovedDelivery
        self.now = datetime(2026, 11, 20, tzinfo=timezone.utc)
        self.d = ApprovedDelivery("d1", "member-b", "approved", self.now + timedelta(days=1),
                                  "file-ok", 1, "h", True)

    def test_attack2_blocked_in_enforce(self):
        from privacygate.transfer_rules import delivery_problem
        self.assertEqual(delivery_problem(self.d, None, requester_id="member-b", now=self.now,
                                          requested_file_id="file-leak")[1], "requested_file_not_approved")

    def test_attack2_passes_in_baseline(self):
        from privacygate.transfer_rules import delivery_problem
        self.assertIsNone(delivery_problem(self.d, None, requester_id="member-b", now=self.now,
                                           requested_file_id="file-leak", baseline=True))

    def test_baseline_still_checks_recipient(self):
        from privacygate.transfer_rules import delivery_problem
        self.assertEqual(delivery_problem(self.d, None, requester_id="someone", now=self.now,
                                          baseline=True)[1], "recipient_mismatch")


if __name__ == "__main__":
    unittest.main()
