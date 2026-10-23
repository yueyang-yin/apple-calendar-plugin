#!/usr/bin/env python3
"""Read-only MapKit route regression using public coordinates, never device location."""
import datetime
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
arrival = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).isoformat(timespec="seconds")
origin = {"coordinates": {"title": "Public route origin", "latitude": 51.2351, "longitude": -0.5748}}
destination = {"coordinates": {"title": "Public route destination", "latitude": 51.23228, "longitude": -0.5763}}
requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "route-verifier", "version": "1"}}}]
modes = ["walking", "driving", "cycling", "transit"]
for index, mode in enumerate(modes, 2):
    requests.append({"jsonrpc": "2.0", "id": index, "method": "tools/call", "params": {
        "name": "calculate_route", "arguments": {"origin": origin, "destination": destination,
            "transport_type": mode, "arrive_by": arrival, "time_zone": "Asia/Shanghai"}}})
process = subprocess.run(["bash", str(root / "scripts/run.sh")],
    input="\n".join(json.dumps(r) for r in requests) + "\n", text=True, capture_output=True, timeout=95)
assert process.returncode == 0, process.stderr
responses = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
assert len(responses) == len(requests)
summaries = []
for mode, response in zip(modes, responses[1:]):
    result = response["result"]
    if result.get("isError"):
        error = json.loads(result["content"][0]["text"])
        assert mode not in ("walking", "driving"), error
        assert error["error"] in ("route_unavailable", "route_mode_unavailable"), error
        summaries.append({"mode": mode, "coverage": "unavailable", "error": error["error"]})
    else:
        route = result["structuredContent"]
        assert route["transport_type"] == mode
        assert route["travel_seconds"] > 0 and route["distance_meters"] > 0
        assert route["estimated_arrival"].endswith("+08:00")
        assert route["estimated_departure"].endswith("+08:00")
        summaries.append({"mode": mode, "travel_seconds": route["travel_seconds"], "distance_meters": route["distance_meters"], "time_zone_check": "passed"})
print(json.dumps({"route_checks": summaries, "live_calendar_writes": 0}))
