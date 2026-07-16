"""Regression tests for session wiring and preview URL persistence."""

import json
import os
from pathlib import Path
import subprocess
import time


ROOT = Path(__file__).resolve().parent


def _run(script: Path, *args: str, env: dict[str, str], stdin: str | None = None):
    return subprocess.run(
        ["bash", str(script), *args],
        cwd=ROOT,
        env=env,
        input=stdin,
        text=True,
        capture_output=True,
        check=True,
        timeout=10,
    )


def test_pair_url_records_reopenable_base_url(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    url = 'http://127.0.0.1:4173/path?q="quoted"&slash=\\value'
    env = {**os.environ, "HOME": str(home)}

    result = _run(ROOT / "tools/pair-url.sh", url, env=env)

    record = json.loads((home / ".click-bridge/bindings.jsonl").read_text().strip())
    assert record["state"] == "pending"
    assert record["url"] == url
    assert f"{url}#cb={record['token']}" in result.stdout


def test_hook_preserves_url_when_lazy_binding_becomes_bound(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    token = "reopen123"
    url = "http://127.0.0.1:4173/preview"
    (state / "last.json").write_text(json.dumps({"component": "Card", "cb_token": token}))
    (state / "bindings.jsonl").write_text(
        json.dumps(
            {
                "token": token,
                "state": "pending",
                "claude_pid": None,
                "url": url,
                "ts": time.time(),
            }
        )
        + "\n"
    )
    env = {**os.environ, "CLICK_BRIDGE_DIR": str(state)}

    result = _run(
        ROOT / "hooks/claude-code-inject.sh",
        env=env,
        stdin=json.dumps({"session_id": "session-abcdef", "cwd": str(ROOT)}),
    )

    records = [json.loads(line) for line in (state / "bindings.jsonl").read_text().splitlines()]
    assert records[-1]["state"] == "bound"
    assert records[-1]["session_id"] == "session-abcd"
    assert records[-1]["url"] == url
    assert "[CLICK-BRIDGE]" in result.stdout


def test_dev_browser_skips_missing_explicit_extension(tmp_path):
    home = tmp_path / "home"
    bin_dir = tmp_path / "bin"
    home.mkdir()
    bin_dir.mkdir()
    args_file = tmp_path / "chromium-args"

    fake_ss = bin_dir / "ss"
    fake_ss.write_text("#!/usr/bin/env bash\nexit 0\n")
    fake_browser = bin_dir / "chromium-browser"
    fake_browser.write_text(
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > \"$CHROMIUM_ARGS_FILE\"\n"
    )
    fake_ss.chmod(0o755)
    fake_browser.chmod(0o755)

    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "CLICK_BRIDGE_EXTENSION": str(tmp_path / "missing-extension"),
        "CHROMIUM_ARGS_FILE": str(args_file),
    }

    result = _run(ROOT / "tools/dev-browser.sh", "http://127.0.0.1:4173/", env=env)
    for _ in range(100):
        if args_file.exists():
            break
        time.sleep(0.01)

    args = args_file.read_text().splitlines()
    assert not any(arg.startswith("--load-extension=") for arg in args)
    assert "CLICK_BRIDGE_EXTENSION does not exist" in result.stderr
