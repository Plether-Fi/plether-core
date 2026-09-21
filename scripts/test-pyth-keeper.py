#!/usr/bin/env python3
"""Exercise keeper authentication and fail-before-broadcast behavior against a local HTTP server."""

import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit


SCRIPT = Path(__file__).resolve().with_name("pyth-keeper.sh")
FEEDS = [
    "3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca",
    "0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8",
    "8ccb376aa871517e807358d4e3cf0bc7fe4950474dbe6c9ffc21ef64e43fc676",
]
PAYLOAD = {
    "binary": {"encoding": "hex", "data": ["aa00bb11", "cc22dd33"]},
    "parsed": [
        {"id": feed, "price": {"price": "12345", "conf": "10", "expo": -4, "publish_time": 1234567890}}
        for feed in FEEDS
    ],
}
TEST_KEY = "keeper-regression-dummy-key"


class HermesHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get("Authorization")))
        status, body = self.server.responses[0]
        if len(self.server.responses) > 1:
            self.server.responses.pop(0)
        if self.headers.get("Authorization") != f"Bearer {TEST_KEY}":
            status, body = 401, "unauthorized"
        self.send_response(status)
        self.end_headers()
        self.wfile.write(body.encode())


class PythKeeperTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pyth-keeper-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.calls = self.directory / "calls.jsonl"
        for name in ("cast", "forge"):
            stub = self.directory / name
            stub.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "with open(os.environ['KEEPER_TEST_CALLS'], 'a') as output:\n"
                "    output.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + '\\n')\n"
                "if Path(sys.argv[0]).name == 'forge':\n"
                "    sys.exit('Unexpected broadcast attempt')\n"
                "print('0x1234')\n"
            )
            stub.chmod(0o755)
        self.server = HTTPServer(("127.0.0.1", 0), HermesHandler)
        self.server.requests = []
        self.server.responses = [(200, json.dumps(PAYLOAD))]
        self.worker = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.worker.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.worker.join()
        self.server.server_close()

    def run_keeper(self, **overrides):
        env = {
            **os.environ,
            "PATH": f"{self.directory}{os.pathsep}{os.environ['PATH']}",
            "NETWORK": "mainnet",
            "DRY_RUN": "false",
            "PYTH_API_KEY": TEST_KEY,
            "HERMES_URL": f"http://127.0.0.1:{self.server.server_port}/v2/updates/price/latest",
            "MAINNET_RPC_URL": "http://unused.invalid",
            "KEEPER_PRIVATE_KEY": "unused-dummy-signer",
            "KEEPER_TEST_CALLS": str(self.calls),
            "NO_PROXY": "127.0.0.1",
            "no_proxy": "127.0.0.1",
            **overrides,
        }
        result = subprocess.run(
            ["bash", str(SCRIPT)], cwd=self.directory, env=env,
            capture_output=True, text=True, timeout=20,
        )
        self.assertNotIn(TEST_KEY, result.stdout + result.stderr)
        return result

    def assert_stopped_before_encoding(self, result, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.calls.exists(), "must not invoke cast or forge for a failed Hermes response")

    def test_missing_key_fails_before_request(self):
        result = self.run_keeper(PYTH_API_KEY="")
        self.assert_stopped_before_encoding(result, "Missing env var: PYTH_API_KEY")
        self.assertEqual(self.server.requests, [])

    def test_unauthorized_plain_text_reports_http_error(self):
        self.server.responses = [(401, "unauthorized")]
        result = self.run_keeper()
        self.assert_stopped_before_encoding(result, "Hermes request failed")
        self.assertIn("401", result.stderr)
        self.assertNotIn("parse error", result.stderr)

    def test_non_json_success_response_is_rejected(self):
        self.server.responses = [(200, "<html>gateway error</html>")]
        self.assert_stopped_before_encoding(self.run_keeper(), "invalid price-update response")

    def test_invalid_payloads_are_rejected(self):
        for field, value in (("data", []), ("data", ["abc"]), ("data", ["zz"]), ("encoding", "base64")):
            with self.subTest(field=field, value=value):
                payload = copy.deepcopy(PAYLOAD)
                payload["binary"][field] = value
                self.server.responses = [(200, json.dumps(payload))]
                self.assert_stopped_before_encoding(self.run_keeper(), "invalid price-update response")
        self.server.responses = [(200, json.dumps({"binary": PAYLOAD["binary"], "parsed": []}))]
        self.assert_stopped_before_encoding(self.run_keeper(), "invalid price-update response")

    def test_authenticated_dry_run_encodes_updates_for_both_networks(self):
        for network, feeds in (("mainnet", FEEDS[2:]), ("sepolia", FEEDS)):
            with self.subTest(network=network):
                result = self.run_keeper(NETWORK=network, DRY_RUN="true")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("price=1.2345 conf=0.001", result.stdout)
                self.assertIn("DRY_RUN=true; skipping broadcast.", result.stdout)
                path, authorization = self.server.requests[-1]
                self.assertEqual(authorization, f"Bearer {TEST_KEY}")
                self.assertEqual(parse_qs(urlsplit(path).query)["ids[]"], ["0x" + feed for feed in feeds])
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls, [["cast", "abi-encode", "f(bytes[])", "[0xaa00bb11,0xcc22dd33]"]] * 2)

    def test_transient_http_failure_recovers_before_encoding(self):
        self.server.responses = [(503, "temporarily unavailable"), (200, json.dumps(PAYLOAD))]
        result = self.run_keeper(DRY_RUN="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.server.requests), 2)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
