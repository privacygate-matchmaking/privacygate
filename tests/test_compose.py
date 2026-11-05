"""실행 환경 검사: compose 망 분리, 비밀값 Git 제외, DB 스키마 불변식."""
import pathlib
import unittest

try:
    import yaml
except ImportError:  # PyYAML 없으면 건너뜀
    yaml = None

ROOT = pathlib.Path(__file__).resolve().parents[1]
PUBLIC = {"public-internal", "public-external", "public-auth"}


@unittest.skipIf(yaml is None, "PyYAML 필요")
class ComposeIsolation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc = yaml.safe_load((ROOT / "compose.yaml").read_text(encoding="utf-8"))
        cls.nets = {name: set(svc.get("networks", [])) for name, svc in cls.doc["services"].items()}

    def shared(self, a, b):
        return self.nets[a] & self.nets[b]

    def test_external_api_isolated(self):
        for other in ("internal-api", "business-db", "transfer-db", "internal-web"):
            self.assertFalse(self.shared("external-api", other), other)

    def test_db_only_by_owner(self):
        for db, owner in (("business-db", "internal-api"), ("transfer-db", "transfer-api")):
            for name in self.nets:
                if name not in (db, owner):
                    self.assertFalse(self.shared(db, name), f"{db}↔{name}")

    def test_named_networks(self):
        self.assertEqual(self.shared("internal-api", "business-db"), {"business-net"})
        self.assertIn("transfer-net", self.shared("internal-api", "transfer-api"))
        self.assertIn("external-net", self.shared("external-web", "external-api"))

    def test_only_public_networks_open(self):
        for name, cfg in self.doc["networks"].items():
            if name not in PUBLIC:
                self.assertTrue(cfg.get("internal"), name)

    def test_ports_bound_to_localhost(self):
        for name, svc in self.doc["services"].items():
            for port in svc.get("ports", []):
                self.assertTrue(str(port).startswith("127.0.0.1:"), name)
            if svc.get("ports"):
                self.assertTrue(self.nets[name] & PUBLIC, name)

    def test_storage_mounted_by_owner_only(self):
        owners = {"evidence-storage": "internal-api", "transfer-staging": "transfer-api",
                  "transfer-verified": "transfer-api"}
        for name, svc in self.doc["services"].items():
            for vol in svc.get("volumes", []):
                src = str(vol).split(":")[0]
                if src in owners:
                    self.assertEqual(name, owners[src], src)


@unittest.skipIf(yaml is None, "PyYAML 필요")
class Https(unittest.TestCase):
    def test_public_ports_are_tls(self):
        doc = yaml.safe_load((ROOT / "compose.yaml").read_text(encoding="utf-8"))
        for name in ("internal-web", "external-web", "keycloak"):
            for port in doc["services"][name]["ports"]:
                self.assertTrue(str(port).endswith(":8443"), name)

    def test_env_example_https_and_secure_cookie(self):
        env = (ROOT / ".env.example").read_text(encoding="utf-8")
        for key in ("KC_PUBLIC_URL", "INTERNAL_BASE_URL", "EXTERNAL_BASE_URL"):
            self.assertRegex(env, rf"(?m)^{key}=https://")
        self.assertRegex(env, r"(?m)^COOKIE_SECURE=true$")
        self.assertRegex(env, r"(?m)^REQUIRE_STAFF_OTP=true$")   # 기본값은 OTP 켜짐
        self.assertRegex(env, r"(?m)^GATE_MODE=enforce$")         # 기본값은 통제 켜짐


class Gitignore(unittest.TestCase):
    def test_secrets_ignored(self):
        text = (ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertIn(".env", text.splitlines())
        self.assertIn("infra/secrets/*", text)
        self.assertIn("*.pem", text)


class TransferSchema(unittest.TestCase):
    SCHEMA = (ROOT / "infra/db/transfer/01-schema.sql").read_text(encoding="utf-8")

    def test_requester_not_approver(self):
        self.assertIn("CHECK (approver_id <> requester_id)", self.SCHEMA)

    def test_status_values(self):
        self.assertIn("'pending', 'passed', 'blocked', 'error'", self.SCHEMA)
        self.assertIn("'pending', 'approved', 'rejected', 'revoked', 'expired'", self.SCHEMA)

    def test_approval_pins_file(self):
        for col in ("approved_file_id", "approved_file_version", "approved_file_hash"):
            self.assertRegex(self.SCHEMA, rf"{col}\s+\w+\s+NOT NULL")


class AuditInsertOnly(unittest.TestCase):
    def test_both_dbs(self):
        for db in ("business", "transfer"):
            grants = (ROOT / f"infra/db/{db}/02-app-role.sh").read_text(encoding="utf-8")
            self.assertIn("GRANT INSERT ON audit_log", grants)
            self.assertNotRegex(grants, r"(UPDATE|DELETE)[^;]*audit_log")


if __name__ == "__main__":
    unittest.main()
