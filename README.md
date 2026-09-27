# vncviewer.koplugin

A VNC (RFB 3.8) client for KOReader. It adds a single **VNC viewer** entry to the file-browser
main menu (*More tools* → *VNC viewer*) which opens a full-screen remote desktop viewer:
the remote framebuffer is rendered through KOReader's BlitBuffer abstraction, taps and drags
become RFB pointer events, the on-screen keyboard types into the remote session, and the view
can be zoomed and panned.

## Install

This is an out-of-tree plugin. Put the `vncviewer.koplugin` directory where KOReader looks for
plugins and make sure external plugins are enabled:

- Linux/desktop: `~/.config/koreader/plugins/vncviewer.koplugin`, which is covered by
  `extra_plugin_paths` in `settings.reader.lua`.
- The plugin must not be listed in `plugins_disabled` / `plugins_disable_external`.

Connection profiles and global settings live in
`~/.config/koreader/settings/vncviewer.lua`.

> **Passwords are stored in clear text**, matching KOReader's own convention for `opds.lua` and
> `kosync.lua`. VNC Authentication is a weak, DES-based scheme anyway — run it over SSH or a VPN.

## Using the viewer

Tap *More tools* → *VNC viewer* to get the connection list (or "New connection…" to add one),
then pick a connection.

The remote framebuffer owns the **whole screen** — there is no permanent toolbar. The menu is
opened the way KOReader's file manager and reader open theirs: **tap, or swipe down, in
KOReader's own menu zone** at the top of the screen (the same `DTAP_ZONE_MENU` area, honouring
the global *activate menu on* preference, so with "swipe only" taps there still go to the remote
desktop).

Gestures on the canvas:

| Gesture | Effect |
| --- | --- |
| tap | left click |
| long press | right click |
| one-finger drag | move with the left button held |
| two-finger drag | pan the view (does not move the remote pointer) |
| pinch / spread | zoom the view, keeping the point between the fingers fixed |
| two-finger rotate | change the screen orientation |
| swipe up from the bottom | show the on-screen keyboard |
| swipe down | hide it again |
| tap / swipe down in the top menu zone | open the in-app menu |

The on-screen keyboard is drawn **over** the framebuffer: showing or hiding it never rescales or
moves the view. Pan (two-finger drag) if part of the remote desktop ends up behind the keyboard —
if the zoomed view already fits in the space above the keyboard, nothing is hidden at all. The keyboard is
re-laid out from the current screen dimensions whenever they change, so it fits after a rotation
just like everything else (rotations and screen resizes go through KOReader's generic
`SetRotationMode` / `ScreenResize` events).

A physical keyboard is forwarded too: printable characters via `TextInput`, and the named keys
(Backspace, Tab, arrows, Home/End, Page Up/Down, F1-F12, modifiers, …) as X11 keysyms. `Back`
leaves the viewer without dropping the connection.

The in-app menu offers everything the viewer can do: the connection list, a status line, zoom
presets (**Fit framebuffer** included), a "keyboard always visible" toggle, show/hide keyboard,
**Rotate screen** and the four screen orientations, "use current orientation as default", the
keys the on-screen keyboard does not have (Enter/Tab/Esc/Delete), **Disconnect** (with
confirmation) and **Leave (keep connection)**. When the connection has just
gone down, the menu leads with **Reconnect to <name>**.

Every menu and dialog has a way back, and it always returns to where you came from: the
connection list is the root, its per-connection dialog (**Connect** / **Edit** / **Delete** /
**Back**) returns to the list, the editor's **Cancel** (and the Back key, and tapping outside)
returns to whatever opened it, and a cancelled delete returns to the per-connection dialog. A
**failed connection returns to the connection list** with the error on top of it instead of
dropping you back into the file browser, and a connection lost while viewing leaves the viewer
open (with the last picture) and offers **Reconnect** in the menu.

**Leaving** the viewer closes the app but *keeps* the connection, the remote framebuffer and
Wi-Fi up; reopening the viewer re-attaches and resynchronises with one non-incremental full
update. Only **Disconnect** closes the socket, frees the plane and restores Wi-Fi.

## Settings file

`~/.config/koreader/settings/vncviewer.lua`, versioned with `settings_version` (currently 1).
Unknown keys are dropped and wrong types are coerced on load, so an older or hand-edited file
keeps working; the rewritten file is saved once at start-up.

```lua
return {
    ["profiles"] = {
        [1] = { ["name"] = "desktop", ["host"] = "10.0.0.5", ["port"] = 5900,
                ["username"] = "", ["password"] = "" },
    },
    ["settings"] = {
        ["orientation"] = 0,               -- Screen.DEVICE_ROTATED_* used as the app default
        ["keyboard_always_visible"] = false,
        ["zoom_mode"] = "fit",             -- "fit" or a numeric scale (0.25 .. 4)
        ["enable_tight"] = false,          -- see below
    },
    ["settings_version"] = 1,
}
```

`username` is reserved for servers that use a username-bearing security type; neither `None` nor
VNC Authentication does, so it may stay empty.

### `enable_tight` is off by default

Tight (encoding 7) is **not** part of RFC 6143, and its compression-control byte is interpreted
differently by different servers (`0x0A` is "no zlib/uncompressed" in libvncclient and "PNG" in
TurboVNC/noVNC). This implementation follows libvncclient `src/libvncclient/tight.c` (cross-checked
against noVNC's `core/decoders/tight.js`) and is exercised by the bundled mock server, but it has
not been verified against a real TigerVNC/x11vnc server. Everything the plugin does by default
(ZRLE, TRLE, Hextile, RRE, CopyRect, Raw) is straight RFC 6143, so Tight stays opt-in until it has
been tested against a real server. Flip the default in the same commit as that verification.

## Architecture

| Module | Responsibility |
| --- | --- |
| `main.lua` | plugin entry: settings store, the FM menu entry, session registry, app lifecycle |
| `vncviewer/settings.lua` | versioned `LuaSettings` wrapper (profiles + global settings), migration |
| `vncviewer/protocol.lua` | RFB 3.8 state machine (handshake, messages), transport agnostic |
| `vncviewer/encodings.lua` | rectangle decoders: Raw/CopyRect/RRE/Hextile/TRLE/ZRLE/Tight, DesktopSize |
| `vncviewer/zstream.lua` | stateful zlib `inflate` (one stream per RFB zlib stream) |
| `vncviewer/des.lua` | DES-ECB for VNC Authentication |
| `vncviewer/pxfmt.lua` | negotiated client pixel format + fast RGB24 pixel writes |
| `vncviewer/util.lua`, `keysyms.lua` | byte readers/writers, rect helpers, key names → X11 keysyms |
| `vncviewer/session.lua` | socket transport, Wi-Fi handling, poll task, attach/detach, reconnect |
| `vncviewer/framebuffer.lua` | the remote plane and the view transform (fit/zoom/pan/draw) |
| `vncviewer/app.lua` | the full-screen viewer widget: toolbar, gestures, keyboard, menu wiring |
| `vncviewer/menu.lua`, `dialogs.lua` | in-app menu, connection list, profile editor |
| `vncviewer/keyboard.lua` | `VirtualKeyboard` wired to RFB key events |

The protocol layer never touches a socket: it runs as a coroutine that asks its transport for
exactly `n` bytes and yields `("need", n)` to a driver. `session.lua` is that driver, and it runs
it from a `UIManager:scheduleIn` poll task with a per-tick CPU budget, so a frame that spans
several ticks cannot block the UI thread. Exactly one update request is outstanding at any time,
which is what bounds memory while the viewer is closed.

## Tests

### Protocol layer (headless, no KOReader needed beyond its LuaJIT)

`tools/mock_vnc_server.py` is a small RFB 3.8 server used as the test target (there is no VNC
server in the development environment). It serves a deterministic synthetic framebuffer in any
encoding, logs every client message, verifies VNC Authentication with OpenSSL's own DES (via
EVP, an implementation completely independent of `vncviewer/des.lua`) and can repaint or resize
the desktop on demand.

`tools/tight_jpeg.b64` is the fixed 32x32 JPEG the mock uses for its Tight JPEG rectangle (so the
test needs no image library).

`tools/proto_smoke.lua` starts one mock instance per case on an ephemeral port and drives the
real protocol stack over a real socket:

```sh
PLUGIN=~/.config/koreader/plugins/vncviewer.koplugin
cd /usr/lib/koreader && \
  LUA_PATH="$PLUGIN/?.lua;./common/?.lua;./common/?/init.lua;;" \
  LUA_CPATH="./common/?.so;;" \
  ./luajit "$PLUGIN/tools/proto_smoke.lua" --tmp /tmp/vncv_smoke
```

It prints one `ok - <name>` line per check and exits 0 on success, otherwise 1 with
`FAIL: <name>: <detail>`. The checks cover: DES against FIPS vectors, the VNC-auth bit reversal,
the pixel format and encoding list as they hit the wire, `None`/VNC security (including a wrong
password), every encoding decoded pixel-exactly (gradient, quadrants and checker patterns, plus
the Hextile/Tight sub-path variants), ZRLE stream continuity across many rectangles, DesktopSize,
the exact bytes of pointer/key/cut-text messages, and the fatal path for an encoding we never
advertised.

Requirements: `python3` with the standard library, `libcrypto` with the legacy provider
(OpenSSL 3.x) for the mock's DES, and KOReader's own `luajit`.

### UI plumbing (headless)

`tools/ui_smoke.lua` drives the real plugin, its dialogs and a real viewer widget against
KOReader's widget stack, with no KOReader process and no VNC server involved (one profile points
at a closed port to exercise the failure path):

```sh
PLUGIN=~/.config/koreader/plugins/vncviewer.koplugin
cd /usr/lib/koreader && \
  KO_HOME=/tmp/vncv_ui_home \
  LUA_PATH="$PLUGIN/?.lua;;" LUA_CPATH="./common/?.so;;" \
  ./luajit "$PLUGIN/tools/ui_smoke.lua"
```

It checks that every menu and dialog has a way back that returns to the previous surface with no
dialog left behind (cancel and save in the editor, Back in the per-connection dialog, cancelled
and confirmed deletes), that a failed connection returns to the connection list with exactly one
dismissable message, that the canvas covers the whole screen and follows a rotation, that showing
the keyboard neither rescales nor moves the view, that the keyboard is re-laid out for the new
screen dimensions after a rotation, and that KOReader's menu tap/swipe zones are registered.

### Live end-to-end

Start the mock and KOReader, then drive the real plugin through KOReader's HTTP inspector
(port 8989, `httpinspector.autostart = true`):

```sh
PLUGIN=~/.config/koreader/plugins/vncviewer.koplugin
python3 "$PLUGIN/tools/mock_vnc_server.py" --port 5900 --encoding zrle --pattern quadrants \
    --log /tmp/mock.log &
koreader &
sleep 20
curl -s 'http://127.0.0.1:8989/koreader/ui/vncviewer/connect_profile/local/'
curl -s 'http://127.0.0.1:8989/koreader/ui/vncviewer/app/send_pointer/300/200/1'
curl -s 'http://127.0.0.1:8989/koreader/ui/vncviewer/app/send_key/65293/1'   # 0xFF0D down
sleep 3
grep -E 'INPUT (PointerEvent|KeyEvent)' /tmp/mock.log

curl -s -o /tmp/screen.png 'http://127.0.0.1:8989/koreader/device/screen/bb'
python3 - <<'PYEOF'
import json, urllib.request
from PIL import Image
B = "http://127.0.0.1:8989/koreader"

def g(path):
    return urllib.request.urlopen(B + path, timeout=15).read()

canvas = json.loads(g("/ui/vncviewer/app/canvas"))
fw, fh = json.loads(g("/ui/vncviewer/app/remote/get_size/"))
scale = float(g("/ui/vncviewer/app/remote/scale"))
vx = float(g("/ui/vncviewer/app/remote/view_x"))
vy = float(g("/ui/vncviewer/app/remote/view_y"))
im = Image.open("/tmp/screen.png").convert("RGB")

def probe(px, py):
    x = int(round(canvas["x"] + (px - vx) * scale))
    y = int(round(canvas["y"] + (py - vy) * scale))
    return im.getpixel((x, y))

red, green = probe(fw // 4, fh // 4), probe(3 * fw // 4, fh // 4)
blue, white = probe(fw // 4, 3 * fh // 4), probe(3 * fw // 4, 3 * fh // 4)
assert red[0] > 180 and red[1] < 80, red
assert green[1] > 180 and green[0] < 80, green
assert blue[2] > 180 and blue[0] < 80, blue
assert min(white) > 180, white
print("ok - screen shows the decoded remote framebuffer:", red, green, blue, white)
PYEOF
```

Inspector URI grammar: a trailing `/` *calls* a method, no slash *reads* a field
(`/koreader/ui/vncviewer/app/canvas`, `/koreader/ui/vncviewer/sessions/local/get_state/`),
BlitBuffers are rendered as PNG. The inspector only reaches objects reachable from the file
manager, so it can drive the connection list (`ui/vncviewer/connection_list/item_table/<n>/…`)
but not the dialogs it opens; those flows are covered by `tools/ui_smoke.lua` instead.

Verified this way: all seven encodings render the pattern in the live GUI (zrle, hextile, trle,
raw, mixed, rre, copyrect); pointer/key input reaches the server; the toolbar/keyboard/zoom/rotate
actions work and the keyboard sends real RFB key events; opening a menu suppresses canvas gestures
and leaving/reopening keeps the connection; with `EMULATE_BW_SCREEN=1` the quadrants still come out
as four distinguishable grey levels; and with the Emulator's fake Wi-Fi the plugin turns Wi-Fi on
when it is off, restores it on disconnect, and never touches a Wi-Fi it did not turn on.

## Limitations

- **Multi-touch gestures cannot be synthesised** on the SDL3 build (no `ydotool`/`wtype`), so the
  gesture *handlers* are unit-tested but the gesture *detector* wiring (pinch/spread/rotate/
  two-finger drag/swipe) has to be exercised by hand on a touch device. The same applies to a
  real tap in the menu zone.
- **The top menu zone is reserved**: with the default `swipe_tap` activation, taps in KOReader's
  `DTAP_ZONE_MENU` (the top eighth of the screen) open the menu instead of clicking the remote
  desktop, exactly as they do in the file manager. Sweep that region mentally or switch
  *activate menu on* to "swipe only" if you need those pixels.
- **Tight is off by default** and untested against a real server (see above).
- **Wi-Fi**: on the SDL *Desktop* device (which is what `koreader` selects when `KO_MULTIUSER` is
  set) KOReader reports Wi-Fi as permanently on, so no Wi-Fi toggling happens there. The fake
  Wi-Fi backend used by the *Emulator* device is what the auto-connect path is verified against.
  `session.lua` never waits forever: if turning Wi-Fi on does not complete in 30 s the attempt
  fails with a message instead of leaving the viewer stuck on "connecting".
- **No suspend handling**: while KOReader is suspended the poll task simply does not run and the
  single outstanding update request is buffered by the kernel. If a connection is reported dying
  across suspend, the fix is to re-request a full update on resume — not done yet.
- `plugins_disable_external` (unset by default) disables all non-builtin plugins, this one
  included.
