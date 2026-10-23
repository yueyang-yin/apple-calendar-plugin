#!/usr/bin/env python3
"""Exercise the real stdio server without changing calendar data."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProtocolTests(unittest.TestCase):
    def exchange(self, messages):
        payload = "\n".join(json.dumps(m) if not isinstance(m, str) else m for m in messages) + "\n"
        result = subprocess.run(["/bin/bash", str(ROOT / "scripts/run.sh")], input=payload,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]

    @staticmethod
    def request(method, request_id=1, params=None):
        request = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            request["params"] = params
        return request

    def initialize(self, version="2025-11-25"):
        return self.request("initialize", 1, {"protocolVersion": version, "capabilities": {},
                                              "clientInfo": {"name": "calendar-verifier", "version": "1"}})

    def test_tool_discovery_and_status(self):
        results = self.exchange([self.initialize(), self.request("tools/list", 2),
                                 self.request("tools/call", 3, {"name": "calendar_status", "arguments": {}})])
        self.assertEqual(results[0]["result"]["protocolVersion"], "2025-11-25")
        tools = results[1]["result"]["tools"]
        self.assertEqual(len(tools), 15)
        self.assertEqual(len({t["name"] for t in tools}), 15)
        by_name = {t["name"]: t for t in tools}
        self.assertTrue(by_name["list_events"]["annotations"]["readOnlyHint"])
        self.assertTrue(by_name["delete_event"]["annotations"]["destructiveHint"])
        self.assertFalse(by_name["create_event"]["annotations"]["destructiveHint"])
        self.assertTrue(by_name["search_places"]["annotations"]["readOnlyHint"])
        self.assertIn("place_ref", by_name["create_event"]["inputSchema"]["properties"])
        self.assertIn("structured_location", by_name["update_event"]["inputSchema"]["properties"])
        self.assertTrue(by_name["calculate_route"]["annotations"]["readOnlyHint"])
        self.assertTrue(by_name["check_travel_feasibility"]["annotations"]["readOnlyHint"])
        self.assertIn("entire_series", by_name["update_event"]["inputSchema"]["properties"]["scope"]["enum"])
        recurrence = by_name["create_event"]["inputSchema"]["properties"]["recurrence"]["properties"]
        self.assertIn("ordinal_weekdays", recurrence)
        self.assertIn("set_positions", recurrence)
        status = results[2]["result"]
        self.assertFalse(status["isError"])
        self.assertEqual(json.loads(status["content"][0]["text"]), status["structuredContent"])
        self.assertIn("time_zone", status["structuredContent"])

    def test_version_negotiation(self):
        for version in ["2024-11-05", "2025-03-26", "2025-06-18"]:
            with self.subTest(version=version):
                self.assertEqual(self.exchange([self.initialize(version)])[0]["result"]["protocolVersion"], version)
        self.assertEqual(self.exchange([self.initialize("2099-01-01")])[0]["result"]["protocolVersion"], "2025-11-25")

    def test_modern_probe_falls_back(self):
        results = self.exchange([self.request("server/discover"), self.initialize()])
        self.assertEqual(results[0]["error"]["code"], -32601)
        self.assertIn("result", results[1])

    def test_notifications_have_no_response(self):
        results = self.exchange([self.initialize(), {"jsonrpc": "2.0", "method": "notifications/initialized"},
                                 self.request("ping", 2)])
        self.assertEqual(len(results), 2)
        self.assertEqual(results[-1]["result"], {})

    def test_missing_initialization(self):
        self.assertEqual(self.exchange([self.request("tools/list")])[0]["error"]["code"], -32002)

    def test_malformed_messages(self):
        cases = [("{broken", -32700), ([], -32600),
                 ({"jsonrpc": "1.0", "id": 1, "method": "ping"}, -32600),
                 (self.request("ping", True), -32600), (self.request("ping", 1, []), -32602)]
        for request, code in cases:
            with self.subTest(request=request):
                self.assertEqual(self.exchange([request])[0]["error"]["code"], code)

    def test_unknown_tool_and_method(self):
        results = self.exchange([self.initialize(), self.request("tools/call", 2, {"name": "invented"}),
                                 self.request("invented", 3)])
        self.assertEqual(results[1]["error"]["code"], -32602)
        self.assertEqual(results[2]["error"]["code"], -32601)

    def test_invalid_writes_are_rejected_before_access(self):
        results = self.exchange([self.initialize(), self.request("tools/call", 2,
                                    {"name": "create_event", "arguments": {"title": "Incomplete"}})])
        self.assertTrue(results[1]["result"]["isError"])
        self.assertEqual(json.loads(results[1]["result"]["content"][0]["text"])["error"], "invalid_arguments")

    def test_missing_event_reference_is_rejected(self):
        results = self.exchange([self.initialize(), self.request("tools/call", 2,
                                    {"name": "get_event", "arguments": {}}), self.request("ping", 3)])
        self.assertTrue(results[1]["result"]["isError"])
        self.assertEqual(json.loads(results[1]["result"]["content"][0]["text"])["error"], "invalid_arguments")
        self.assertEqual(results[2]["result"], {})

    def test_invalid_place_search_does_not_need_calendar_access(self):
        results = self.exchange([self.initialize(), self.request("tools/call", 2,
                                    {"name": "search_places", "arguments": {"query": "A building", "radius_meters": 1000}}),
                                 self.request("ping", 3)])
        self.assertTrue(results[1]["result"]["isError"])
        error = json.loads(results[1]["result"]["content"][0]["text"])
        self.assertEqual(error["error"], "invalid_arguments")
        self.assertEqual(results[2]["result"], {})

    def test_invalid_location_coordinates_are_rejected(self):
        results = self.exchange([self.initialize(), self.request("tools/call", 2,
                                    {"name": "create_event", "arguments": {
                                        "calendar_id": "test", "title": "Test", "start": "2026-10-24T13:00:00+01:00",
                                        "end": "2026-10-24T14:00:00+01:00",
                                        "structured_location": {"title": "A venue", "latitude": 51, "longitude": 181}}})])
        self.assertTrue(results[1]["result"]["isError"])
        self.assertEqual(json.loads(results[1]["result"]["content"][0]["text"])["error"], "invalid_arguments")

    def test_native_self_tests(self):
        binary = ROOT / "server/Apple Calendar.app/Contents/MacOS/AppleCalendarMCP"
        result = subprocess.run([str(binary), "--self-test"], text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertGreaterEqual(output["passed"], 41)
        self.assertEqual(output["live_calendar_writes"], 0)

    def test_route_requires_unambiguous_time_and_endpoints(self):
        point = {"coordinates": {"latitude": 51.24, "longitude": -0.58}}
        for arguments in [
            {"origin": point, "destination": point, "depart_at": "2031-01-01T10:00:00Z", "arrive_by": "2031-01-01T11:00:00Z"},
            {"origin": {}, "destination": point},
            {"origin": {**point, "place_ref": "ap1.invalid"}, "destination": point},
        ]:
            with self.subTest(arguments=arguments):
                result = self.exchange([self.initialize(), self.request("tools/call", 2,
                    {"name": "calculate_route", "arguments": arguments})])[1]["result"]
                self.assertTrue(result["isError"])
                self.assertEqual(json.loads(result["content"][0]["text"])["error"], "invalid_arguments")

    def test_live_diagnostics_require_explicit_write_flag(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/run.sh"), "--integration-test"],
                                capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--allow-calendar-writes", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
