#!/usr/bin/env python3
"""Read-only EventKit smoke test; prints counts, never event contents."""
import datetime
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
server = subprocess.Popen(["/bin/bash", str(root / "scripts/run.sh")], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, text=True, bufsize=1)
counter = 0


def rpc(method, params):
    global counter
    counter += 1
    server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": counter, "method": method, "params": params}) + "\n")
    server.stdin.flush()
    response = json.loads(server.stdout.readline())
    if "error" in response:
        raise RuntimeError(response["error"])
    return response["result"]


def call(name, arguments=None):
    output = rpc("tools/call", {"name": name, "arguments": arguments or {}})
    if output.get("isError"):
        raise RuntimeError(output["content"][0]["text"])
    return output["structuredContent"]


try:
    rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                       "clientInfo": {"name": "calendar-read-verifier", "version": "1"}})
    status = call("calendar_status")
    print(json.dumps({"status": status}, ensure_ascii=False), flush=True)
    if not status["connected"]:
        if "--authorize" not in sys.argv:
            raise RuntimeError("Calendar full access is required; rerun with --authorize to show the native prompt.")
        status = call("request_access")
        print(json.dumps({"authorized": status["connected"]}), flush=True)
    calendars = call("list_calendars")["calendars"]
    now = datetime.datetime.now(datetime.timezone.utc)
    args = {"start": now.isoformat(timespec="seconds"),
            "end": (now + datetime.timedelta(days=7)).isoformat(timespec="seconds"), "limit": 5}
    listing = call("list_events", args)
    if listing["events"]:
        event = listing["events"][0]
        detail = call("get_event", {"event_ref": event["event_ref"]})["event"]
        assert detail["calendar_id"] == event["calendar_id"]
        assert detail["start_instant"] == event["start_instant"]
    found = call("search_events", {**args, "query": "__apple_calendar_nonexistent_smoke_test__"})
    assert not found["events"]
    gaps = call("find_free_time", {k: v for k, v in args.items() if k != "limit"})
    print(json.dumps({"read_check": "passed", "calendar_count": len(calendars),
                      "writable_calendar_count": sum(c["writable"] for c in calendars),
                      "source_types": sorted({c["source_type"] for c in calendars}),
                      "events_next_7_days": listing["total"], "exact_occurrence_read": bool(listing["events"]),
                      "busy_intervals": len(gaps["busy"]), "free_intervals": len(gaps["free"]),
                      "live_calendar_writes": 0}), flush=True)
finally:
    server.stdin.close()
    server.wait(timeout=10)
