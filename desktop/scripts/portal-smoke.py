#!/usr/bin/env python3
"""Mock the portal on a private D-Bus session: consent, session scoping, release and Close."""
import os
import select
import subprocess
import sys
import threading

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

DBusGMainLoop(set_as_default=True)
BUS = dbus.SessionBus()
NAME = dbus.service.BusName("org.freedesktop.portal.Desktop", BUS)
ROOT = "/org/freedesktop/portal/desktop"
BINARY = os.environ.get("CHIRP_PORTAL_SMOKE", "/cargo-target/debug/examples/portal-smoke")
objects = []
errors = []
closed = threading.Event()
DENIED = "--denied" in sys.argv


class Request(dbus.service.Object):
    @dbus.service.signal("org.freedesktop.portal.Request", signature="ua{sv}")
    def Response(self, code, values):
        pass


class Session(dbus.service.Object):
    @dbus.service.method("org.freedesktop.portal.Session", in_signature="", out_signature="")
    def Close(self):
        closed.set()


class Portal(dbus.service.Object):
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        return dbus.UInt32(1)

    def request(self, sender, options):
        path = f"{ROOT}/request/{sender[1:].replace('.', '_')}/{options['handle_token']}"
        request = Request(BUS, path)
        objects.append(request)
        return path, request

    @dbus.service.method("org.freedesktop.portal.GlobalShortcuts", in_signature="a{sv}", out_signature="o", sender_keyword="sender")
    def CreateSession(self, options, sender=None):
        path, request = self.request(sender, options)
        self.session = f"{ROOT}/session/{sender[1:].replace('.', '_')}/{options['session_handle_token']}"
        objects.append(Session(BUS, self.session))
        GLib.timeout_add(50, lambda: (request.Response(0, {"session_handle": dbus.String(self.session)}), False)[1])
        return path

    @dbus.service.method("org.freedesktop.portal.GlobalShortcuts", in_signature="oa(sa{sv})sa{sv}", out_signature="o", sender_keyword="sender")
    def BindShortcuts(self, session, shortcuts, parent, options, sender=None):
        assert str(session) == self.session
        assert len(shortcuts) == 1 and str(shortcuts[0][0]) == "dictate"
        assert str(shortcuts[0][1]["preferred_trigger"]) == "CTRL+ALT+space"
        path, request = self.request(sender, options)
        values = dbus.Array([dbus.Struct(("dictate", dbus.Dictionary({"description": "Dictate with Chirp", "trigger_description": "Ctrl+Alt+Space"}, signature="sv")), signature="sa{sv}")], signature="(sa{sv})")
        if DENIED:
            GLib.timeout_add(50, lambda: (request.Response(1, {}), False)[1])
        else:
            GLib.timeout_add(50, lambda: (request.Response(0, {"shortcuts": values}), False)[1])
        return path

    @dbus.service.signal("org.freedesktop.portal.GlobalShortcuts", signature="osta{sv}")
    def Activated(self, session, shortcut, timestamp, options):
        pass

    @dbus.service.signal("org.freedesktop.portal.GlobalShortcuts", signature="osta{sv}")
    def Deactivated(self, session, shortcut, timestamp, options):
        pass


portal = Portal(BUS, ROOT)
loop = GLib.MainLoop()


def read(process):
    assert select.select([process.stdout], [], [], 8)[0], "portal client timed out"
    return process.stdout.readline().decode().strip()


def emit():
    # Neither another session nor another action may control Chirp.
    portal.Activated(ROOT + "/session/foreign", "dictate", 1, {})
    portal.Activated(portal.session, "other-action", 2, {})
    portal.Activated(portal.session, "dictate", 3, {})
    portal.Deactivated(ROOT + "/session/foreign", "dictate", 4, {})
    portal.Deactivated(portal.session, "dictate", 5, {})
    return False


def check():
    global DENIED
    denied = DENIED
    process = subprocess.Popen([BINARY, *(["--unavailable"] if denied else [])], stdout=subprocess.PIPE, bufsize=0)
    try:
        first = read(process)
        if denied:
            assert first == "unavailable" and closed.wait(3)
            assert process.wait(timeout=5) == 0
            print("Portal: declined binding closes the session without recording")
            return
        assert first == "ready"
        GLib.idle_add(emit)
        assert read(process) == "events"
        assert closed.wait(3), "portal Session.Close was not called"
        assert process.wait(timeout=5) == 0
        print("Portal: approved binding, scoped press/release, and session cleanup passed")
        closed.clear()
        DENIED = True
        process = subprocess.Popen([BINARY, "--unavailable"], stdout=subprocess.PIPE, bufsize=0)
        assert read(process) == "unavailable" and closed.wait(3)
        assert process.wait(timeout=5) == 0
        print("Portal: declined binding closes the session without recording")
    except BaseException as error:
        errors.append(f"{type(error).__name__}: {error}")
        process.kill()
        process.wait()
    finally:
        GLib.idle_add(loop.quit)


GLib.timeout_add(30, lambda: (threading.Thread(target=check, daemon=True).start(), False)[1])
GLib.timeout_add_seconds(20, lambda: (errors.append("timeout"), loop.quit(), False)[2])
loop.run()
assert not errors, "Portal smoke failed: " + ", ".join(errors)
