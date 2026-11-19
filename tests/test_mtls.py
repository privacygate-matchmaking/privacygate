"""서비스 간 mTLS 시험: mtls-certs.sh 로 만든 인증서로 '서비스 인증서만 연결, 인증서 없음·다른 CA·평문은 차단'.
openssl 이 없으면 건너뛴다."""
import http.server
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipIf(shutil.which("openssl") is None, "openssl 필요")
class MutualTLS(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import httpx  # noqa: F401  (없으면 건너뜀)
        cls.tmp = Path(tempfile.mkdtemp())
        (cls.tmp / "infra/scripts").mkdir(parents=True)
        shutil.copy(ROOT / "infra/scripts/mtls-certs.sh", cls.tmp / "infra/scripts/")
        subprocess.run(["bash", str(cls.tmp / "infra/scripts/mtls-certs.sh")], check=True, capture_output=True)
        cls.d = cls.tmp / "infra/secrets/mtls"
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cls.d / "transfer-api.pem", cls.d / "transfer-api.key")
        ctx.load_verify_locations(cls.d / "ca.pem")
        ctx.verify_mode = ssl.CERT_REQUIRED

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

            def log_message(self, *a):
                pass
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.socket = ctx.wrap_socket(cls.server.socket, server_side=True)
        cls.url = f"https://localhost:{cls.server.server_address[1]}/health"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def env(self, name):
        return {"MTLS_CA_FILE": str(self.d / "ca.pem"), "MTLS_CERT_FILE": str(self.d / f"{name}.pem"),
                "MTLS_KEY_FILE": str(self.d / f"{name}.key")}

    def get(self, **kw):
        import httpx
        try:
            return httpx.get(self.url, timeout=5, **kw).status_code
        except httpx.HTTPError as exc:
            return type(exc).__name__

    def test_disabled_without_env(self):
        from privacygate import mtls
        for k in ("MTLS_CA_FILE", "MTLS_CERT_FILE", "MTLS_KEY_FILE"):
            os.environ.pop(k, None)
        self.assertEqual(mtls.client_options(), {})

    def test_service_cert_connects_others_blocked(self):
        from privacygate import mtls
        os.environ.update(self.env("external-api"))
        try:
            self.assertEqual(self.get(**mtls.client_options()), 200)
        finally:
            for k in self.env("x"):
                os.environ.pop(k)
        self.assertNotEqual(self.get(verify=ssl.create_default_context(cafile=str(self.d / "ca.pem"))), 200)   # 인증서 없음
        self.assertNotEqual(self.get(), 200)                                                                   # 서버 검증 불가
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=evil",
                        "-keyout", str(self.tmp / "evil.key"), "-out", str(self.tmp / "evil.pem")], check=True, capture_output=True)
        foreign = ssl.create_default_context(cafile=str(self.d / "ca.pem"))
        foreign.load_cert_chain(self.tmp / "evil.pem", self.tmp / "evil.key")
        self.assertNotEqual(self.get(verify=foreign), 200)                                                     # 다른 CA

    def test_ca_key_not_world_readable(self):
        self.assertEqual(os.stat(self.d / "ca.key").st_mode & 0o077, 0)


if __name__ == "__main__":
    unittest.main()
