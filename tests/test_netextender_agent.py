import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
import select
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AGENT_PATH = ROOT / "scripts" / "netextender-agent"
SPEC = importlib.util.spec_from_loader(
    "netextender_agent", SourceFileLoader("netextender_agent", str(AGENT_PATH))
)
AGENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AGENT)

FINGERPRINT = "SHA1[00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:10:20:30:40]"


class CertificateHelpersTest(unittest.TestCase):
    def test_extracts_warning_details_and_fingerprint(self):
        prompt = (
            "There is a problem with the site's security certificate.\r\n"
            "Warning: self signed certificate in certificate chain\r\n"
            "Do you want to proceed? (Y:Yes, N:No, V:View Certificate)"
        )
        details = (
            "  Certificate Detail:\r\n"
            "  Issued To:\r\n     Common Name (CN): vpn.example.com\r\n"
            f"  Fingerprints:\r\n     {FINGERPRINT}\r\n"
            "Do you want to proceed? (Y:Yes, N:No, V:View Certificate)"
        )
        self.assertEqual(AGENT.certificate_warning(prompt),
                         "self signed certificate in certificate chain")
        parsed = AGENT.certificate_details(details)
        self.assertIn("Common Name (CN): vpn.example.com", parsed)
        self.assertEqual(AGENT.certificate_fingerprint(parsed), FINGERPRINT)

    def test_persists_pin_without_changing_other_sections(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / ".netextender"
            config.write_text("[profiles]\nkeep=this\n\n[trustedcerts]\nold:443=SHA1[AA]\n\n[logging]\ngeneral=info\n")
            os.chmod(config, 0o640)
            AGENT.persist_trusted_certificate("vpn.example.com:443", FINGERPRINT, config)
            contents = config.read_text()
            self.assertIn("keep=this", contents)
            self.assertIn("general=info", contents)
            self.assertIn(f"vpn.example.com:443={FINGERPRINT}", contents)
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o640)

    def test_replaces_existing_server_case_insensitively(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / ".netextender"
            config.write_text(f"[trustedcerts]\nVPN.EXAMPLE.COM:443={FINGERPRINT}\n")
            replacement = "SHA1[40:30:20:10:FF:EE:DD:CC:BB:AA:99:88:77:66:55:44:33:22:11:00]"
            AGENT.persist_trusted_certificate("vpn.example.com:443", replacement, config)
            contents = config.read_text()
            self.assertEqual(contents.count("="), 1)
            self.assertIn(f"vpn.example.com:443={replacement}", contents)


class CertificatePtyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary.name)
        self.bin_dir = self.home / "bin"
        self.bin_dir.mkdir()
        self._executable("secret-tool", "#!/bin/sh\nprintf 'test-password\\n'\n")
        self._executable("netExtender", textwrap.dedent(f"""\
            #!/usr/bin/env python3
            import os
            import sys
            print("There is a problem with the site's security certificate.", flush=True)
            print("Warning: self signed certificate in certificate chain", flush=True)
            prompt = "Do you want to proceed? (Y:Yes, N:No, V:View Certificate)"
            print(prompt, flush=True)
            answer = input().strip().upper()
            if answer == "V":
                print("Certificate Detail:", flush=True)
                print("Issued To: Common Name (CN): vpn.example.com", flush=True)
                fingerprint = "" if os.environ.get("OMIT_FINGERPRINT") else "{FINGERPRINT}"
                print("Fingerprints: " + fingerprint, flush=True)
                print(prompt, flush=True)
                answer = input().strip().upper()
            if answer != "Y":
                raise SystemExit(3)
            print("Password:", flush=True)
            if input().strip() != "test-password":
                raise SystemExit(4)
            print("One Time Password:", flush=True)
            if input().strip() != "123456":
                raise SystemExit(5)
        """))

    def tearDown(self):
        self.temporary.cleanup()

    def _executable(self, name, contents):
        path = self.bin_dir / name
        path.write_text(contents)
        path.chmod(0o755)

    def _start_agent(self, extra_environment=None):
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)
        environment["PATH"] = str(self.bin_dir) + os.pathsep + environment["PATH"]
        environment.update(extra_environment or {})
        return subprocess.Popen(
            [str(AGENT_PATH), "connect", "--server", "vpn.example.com:443",
             "--username", "user", "--domain", "domain"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=environment,
        )

    def _event(self, process, expected):
        ready, _, _ = select.select([process.stdout], [], [], 5)
        self.assertTrue(ready, f"timed out waiting for {expected}")
        event = json.loads(process.stdout.readline())
        self.assertEqual(event["event"], expected)
        return event

    def _finish(self, process):
        code = process.wait(timeout=5)
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
        return code

    def test_view_accept_and_otp(self):
        process = self._start_agent()
        self._event(process, "connecting")
        self._event(process, "needs_certificate")
        process.stdin.write("cert:view\n")
        process.stdin.flush()
        self._event(process, "reading_certificate")
        details = self._event(process, "certificate_details")
        self.assertEqual(details["fingerprint"], FINGERPRINT)
        process.stdin.write("cert:accept\n")
        process.stdin.flush()
        self._event(process, "certificate_accepted")
        self._event(process, "needs_otp")
        process.stdin.write("123456\n")
        process.stdin.flush()
        self._event(process, "verifying_otp")
        self.assertEqual(self._finish(process), 0)

    def test_cancel_rejects_certificate(self):
        process = self._start_agent()
        self._event(process, "connecting")
        self._event(process, "needs_certificate")
        process.stdin.write("cert:cancel\n")
        process.stdin.flush()
        self._event(process, "certificate_cancelled")
        ended = self._event(process, "ended")
        self.assertEqual(ended["code"], 3)
        self.assertEqual(self._finish(process), 3)

    def test_always_trust_persists_pin(self):
        process = self._start_agent()
        self._event(process, "connecting")
        self._event(process, "needs_certificate")
        process.stdin.write("cert:always\n")
        process.stdin.flush()
        self._event(process, "reading_certificate")
        self._event(process, "certificate_details")
        self._event(process, "certificate_trusted")
        self._event(process, "needs_otp")
        process.stdin.write("123456\n")
        process.stdin.flush()
        self._event(process, "verifying_otp")
        self.assertEqual(self._finish(process), 0)
        self.assertIn(f"vpn.example.com:443={FINGERPRINT}",
                      (self.home / ".netextender").read_text())

    def test_always_trust_failure_accepts_once_with_warning(self):
        process = self._start_agent({"OMIT_FINGERPRINT": "1"})
        self._event(process, "connecting")
        self._event(process, "needs_certificate")
        process.stdin.write("cert:always\n")
        process.stdin.flush()
        self._event(process, "reading_certificate")
        self._event(process, "certificate_details")
        warning = self._event(process, "warning")
        self.assertIn("accepted for this connection", warning["message"])
        self._event(process, "needs_otp")
        process.stdin.write("123456\n")
        process.stdin.flush()
        self._event(process, "verifying_otp")
        self.assertEqual(self._finish(process), 0)
        self.assertFalse((self.home / ".netextender").exists())


if __name__ == "__main__":
    unittest.main()
