"""click-bridge server tests — exercised against a real server via stdlib http.client."""
import json
import threading
import time
import http.client
from pathlib import Path

import pytest

import server as srv


@pytest.fixture()
def bridge(tmp_path):
    """Start a real server on an ephemeral port, return (host, port, dir)."""
    httpd = srv.make_server("127.0.0.1", 0, tmp_path)
    port = httpd.server_address[1]
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    yield ("127.0.0.1", port, tmp_path)
    httpd.shutdown()


def _req(host, port, method, path, body=None, headers=None):
    conn = http.client.HTTPConnection(host, port, timeout=5)
    conn.request(method, path, body=body, headers=headers or {"Content-Type": "application/json"})
    resp = conn.getresponse()
    data = resp.read()
    result = (resp.status, dict(resp.getheaders()), data)
    conn.close()
    return result


def test_health(bridge):
    host, port, _ = bridge
    status, _, data = _req(host, port, "GET", "/health")
    assert status == 200
    assert json.loads(data)["ok"] is True


def test_post_click_writes_last_and_history(bridge):
    host, port, d = bridge
    payload = {"component": "TaskCard", "source": {"file": "src/TaskCard.tsx", "line": 42}}
    status, headers, data = _req(host, port, "POST", "/click", json.dumps(payload))
    assert status == 200
    assert json.loads(data)["ok"] is True
    assert headers.get("Access-Control-Allow-Origin") == "*"

    last = json.loads((d / "last.json").read_text())
    assert last["component"] == "TaskCard"
    assert last["source"]["line"] == 42
    assert "ts" in last and "iso" in last

    lines = (d / "history.jsonl").read_text().strip().splitlines()
    assert len(lines) == 1


def test_second_post_overwrites_last_appends_history(bridge):
    host, port, d = bridge
    _req(host, port, "POST", "/click", json.dumps({"component": "A"}))
    time.sleep(0.01)
    _req(host, port, "POST", "/click", json.dumps({"component": "B"}))

    last = json.loads((d / "last.json").read_text())
    assert last["component"] == "B"
    lines = (d / "history.jsonl").read_text().strip().splitlines()
    assert len(lines) == 2
    assert json.loads(lines[0])["component"] == "A"


def test_get_last_returns_latest(bridge):
    host, port, _ = bridge
    _req(host, port, "POST", "/click", json.dumps({"selector": "#btn", "note": "broken button"}))
    status, _, data = _req(host, port, "GET", "/last")
    assert status == 200
    obj = json.loads(data)
    assert obj["selector"] == "#btn"


def test_get_last_before_any_click_404(bridge):
    host, port, _ = bridge
    status, _, data = _req(host, port, "GET", "/last")
    assert status == 404
    assert json.loads(data)["ok"] is False


def test_invalid_json_400(bridge):
    host, port, _ = bridge
    status, _, data = _req(host, port, "POST", "/click", "{broken json")
    assert status == 400
    assert json.loads(data)["ok"] is False


def test_oversized_body_413(bridge):
    host, port, _ = bridge
    big = json.dumps({"text": "x" * 300000})
    status, _, _ = _req(host, port, "POST", "/click", big)
    assert status == 413


def test_options_preflight_204_with_cors(bridge):
    host, port, _ = bridge
    status, headers, _ = _req(host, port, "OPTIONS", "/click")
    assert status == 204
    assert headers.get("Access-Control-Allow-Origin") == "*"
    assert "POST" in headers.get("Access-Control-Allow-Methods", "")


def test_unknown_path_404(bridge):
    host, port, _ = bridge
    status, _, _ = _req(host, port, "GET", "/nope")
    assert status == 404


def test_snippet_js_served(bridge):
    host, port, _ = bridge
    status, headers, data = _req(host, port, "GET", "/snippet.js")
    assert status == 200
    assert "javascript" in headers.get("Content-Type", "")
    body = data.decode()
    assert "__clickBridgeLoaded" in body
    assert "console_errors" in body
