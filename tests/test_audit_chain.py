"""감사 로그 공통 형식·해시 체인 시험."""
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

from privacygate.audit import POLICY_VERSION, AuditWriter, verify_chain


class AuditChain(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.path = self.dir / "svc.json"

    def write(self, n, writer=None):
        w = writer or AuditWriter("transfer-api", str(self.path))
        for i in range(n):
            w.record(trace_id=f"t{i}", action="delivery.download", result="allow", actor="A-001", role="member",
                     owner_id="owner-uuid", recipient_id="recipient-uuid", approval_id="ap-1",
                     file_id="f-1", file_hash="a" * 64, consent_id="c-1")
        return w

    def lines(self):
        return self.path.read_text(encoding="utf-8").splitlines()

    def test_standard_fields_and_policy_version(self):
        self.write(1)
        e = json.loads(self.lines()[0])
        for k in ("ts", "service", "trace_id", "actor", "role", "action", "result", "policy_version",
                  "owner_id", "recipient_id", "consent_id", "approval_id", "file_id", "file_hash", "seq", "prev_hash", "hash"):
            self.assertIn(k, e)
        self.assertEqual(e["policy_version"], POLICY_VERSION)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode) & 0o007, 0)   # 다른 사용자 읽기 불가

    def test_detail_fields_absent_when_not_given(self):
        AuditWriter("internal-api", str(self.path)).record(trace_id="t", action="GET /api/me", result="allow")
        e = json.loads(self.lines()[0])
        self.assertNotIn("file_hash", e)
        self.assertIn("actor", e)          # 기존 필드는 null 이라도 유지 (Wazuh 규칙 호환)

    def test_unknown_detail_field_rejected(self):
        with self.assertRaises(ValueError):
            AuditWriter("x", str(self.path)).record(trace_id="t", action="a", result="allow", contact_phone="010")

    def test_valid_chain_survives_restart(self):
        self.write(3)
        self.write(2)                       # 새 기록기(재시작)도 앞 줄을 이어 받는다
        self.assertEqual(verify_chain(self.lines()), [])
        self.assertEqual([json.loads(l)["seq"] for l in self.lines()], ["1", "2", "3", "4", "5"])

    def test_detects_modification(self):
        self.write(3)
        lines = self.lines()
        e = json.loads(lines[1]); e["result"] = "deny"; lines[1] = json.dumps(e)
        self.assertTrue(any("해시 불일치" in p for p in verify_chain(lines)))

    def test_detects_deletion_and_reorder(self):
        self.write(4)
        lines = self.lines()
        self.assertTrue(any("끊김" in p for p in verify_chain(lines[:1] + lines[2:])))
        self.assertTrue(any("끊김" in p for p in verify_chain([lines[0], lines[2], lines[1], lines[3]])))

    def test_write_failure_shows_as_gap(self):
        w = self.write(2)
        real = w.path
        w.path = str(self.dir / "missing-dir" / "x.json")
        w.record(trace_id="lost", action="a", result="allow")      # 파일에 못 씀
        w.path = real
        w.record(trace_id="after", action="a", result="allow")
        problems = verify_chain(self.lines())
        self.assertTrue(any("누락" in p or "끊김" in p for p in problems))


if __name__ == "__main__":
    unittest.main()
