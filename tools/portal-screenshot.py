#!/usr/bin/env python3
"""GNOME Wayland desktop screenshot — via xdg-desktop-portal.

On GNOME 50, gnome-screenshot is gone and grim is wlroots-only → the portal is the only
reliable path left.
Usage:
    python3 portal-screenshot.py [target.png]
Prints the file path to stdout (the portal's own path under ~/Pictures if no target is given).
Env defaults are baked in for headless/timer invocations (they attach to the live Wayland session).
"""
import os
import shutil
import sys

os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")  # defaults to the current uid
os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path=/run/user/{os.getuid()}/bus")

import gi  # noqa: E402

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

TIMEOUT_S = 15


def main():
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    loop = GLib.MainLoop()
    result = {}

    def on_response(_conn, _sender, _path, _iface, _signal, params):
        code, results = params.unpack()
        result["code"] = code
        result["uri"] = results.get("uri", "")
        loop.quit()

    # Listen to all portal Request/Response signals (fine for a one-shot utility)
    bus.signal_subscribe(
        "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
        "Response", None, None, Gio.DBusSignalFlags.NONE, on_response,
    )
    bus.call_sync(
        "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Screenshot", "Screenshot",
        GLib.Variant("(sa{sv})", ("", {
            "handle_token": GLib.Variant("s", "ccshot"),
            "interactive": GLib.Variant("b", False),
        })),
        GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, -1, None,
    )
    GLib.timeout_add_seconds(TIMEOUT_S, loop.quit)
    loop.run()

    if result.get("code") != 0 or not result.get("uri"):
        print(f"FAIL: portal response {result or 'timeout'}", file=sys.stderr)
        sys.exit(1)

    src = result["uri"].removeprefix("file://")
    if len(sys.argv) > 1:
        dst = os.path.expanduser(sys.argv[1])
        shutil.move(src, dst)
        print(dst)
    else:
        print(src)


if __name__ == "__main__":
    main()
