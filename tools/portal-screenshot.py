#!/usr/bin/env python3
"""GNOME Wayland masaüstü screenshot — xdg-desktop-portal üzerinden.

GNOME 50'de gnome-screenshot ÖLÜ, grim wlroots-only → TEK güvenilir yol portal.
Kullanım:
    python3 portal-screenshot.py [hedef.png]
stdout'a dosya yolunu basar (hedef verilmezse portalın yazdığı ~/Resimler yolu).
Headless/timer çağrıları için env default'ları gömülü (canlı Wayland oturumuna bağlanır).
"""
import os
import shutil
import sys

os.environ.setdefault("XDG_RUNTIME_DIR", "/run/user/1000")
os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/1000/bus")

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

    # Tüm portal Request/Response sinyallerini dinle (tek atımlık utility için yeterli)
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
        print(f"FAIL: portal yaniti {result or 'timeout'}", file=sys.stderr)
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
