# VNC for KOReader

Two halves of one thing. **Control a remote desktop from KOReader**: the plugin adds *VNC viewer* to
KOReader's file browser menu, and the remote screen fills the display, driven by touch, the
on-screen keyboard and a physical keyboard. And **share KOReader's own screen**: a small VNC server,
started from the *Network* menu, lets a computer elsewhere watch and drive the reader — see
[Sharing this screen (VNC server)](#sharing-this-screen-vnc-server).

Both halves speak RFB 3.8, the protocol ordinary VNC servers and viewers (x11vnc, TigerVNC,
TightVNC, RealVNC in compatibility mode, Remmina, phone apps, ...) all understand.

## What you get

- The remote framebuffer on the whole screen, scaled to fit, with zoom presets (fit screen, fit
  with the on-screen keyboard, or a fixed 25 % … 400 %) and panning for the rest.
- Touch control: tap = left click, long press = right click, drag = drag with the button held.
  Two-finger drag pans the view, pinch/spread zooms, two-finger rotate turns the screen.
- An on-screen keyboard that types into the remote session, plus a physical keyboard with
  modifiers, arrows, function keys and auto-repeat. Keys the on-screen keyboard does not have
  (Enter, Tab, Esc, Delete) are in the menu.
- Connection profiles (name, host, port, password) you can add, edit and delete from KOReader.
- One connection can be flagged to connect by itself at KOReader's start (and to appear as
  **VNC auto connect** in KOReader's **Start with** menu).
- Wi-Fi is turned on when a connection needs it and switched back off when you disconnect.
- **Leave** the viewer and the connection survives: reopen it and the picture is resynchronised.
  Only **Disconnect** closes the session.

## Install

1. On GitHub, download this repository as a ZIP: green **Code** button ▸ **Download ZIP**.
2. Unpack the ZIP.
3. Move the plugin folder into the `plugins` directory in your KOReader folder (create the
   `plugins` directory if it is not there yet). GitHub names the unpacked folder after the
   repository and the branch — `vnc.koplugin-main` — so rename it to **`vnc.koplugin`**
   while you are at it: KOReader only loads plugin directories whose name ends in `.koplugin`.
4. Restart KOReader.

That is all — there are no release artefacts to fetch, because the plugin is plain Lua and uses
only what KOReader already ships.

## Using it

Open the file browser menu in KOReader, then **More tools** ▸ **VNC viewer**. You get the
connection list; start with **New connection…** and give it a name, the host, the port (5900 by
default) and the password your VNC server uses. Tap a connection to connect.

**Manage connections…** opens each saved connection's own actions (Connect, Edit, Delete), plus an
**Auto connect on start** switch. Turning it on dials that connection by itself on KOReader's next
start and shows it in the viewer; the connection list then marks it (**name (auto connect)**).
Only one connection can carry it — turning it on for another clears the first. While a connection
carries it, KOReader's own **Start with** menu also offers **VNC auto connect**, so the choice shows
up where KOReader keeps its own startup choices.

KOReader cannot be told about the viewer before it opens the file browser — it has no boot hook for
plugins — so with **VNC auto connect** selected the file browser appears for a moment and the
viewer opens over it. If the connection cannot be made, the failure is reported exactly as a manual
connect's is, and you are left in the normal KOReader UI; there is no retry.

There is no permanent toolbar: the remote desktop owns the whole screen.

| Gesture | Effect |
| --- | --- |
| tap | left click |
| long press | right click |
| one-finger drag | drag with the left button held |
| two-finger drag | pan the view (does not move the remote pointer) |
| pinch / spread | zoom the view, keeping the point between the fingers fixed |
| two-finger rotate | change the screen orientation |
| swipe up from the bottom strip | show the on-screen keyboard |
| swipe down above the keyboard | hide it again |
| swipe down in the top menu zone | open the menu |

The two keyboard swipes have to start in the space the keyboard leaves free: a swipe **up from the
bottom strip** shows the keyboard, a swipe down **above** it hides it again. Swipes that begin on
the keys themselves belong to KOReader's keyboard, where a swipe on a key inserts one of its
alternate characters — so there is no "swipe down on the keyboard to put it away". The menu's
**Hide keyboard** entry does that from anywhere, and **keyboard always visible** keeps the keyboard
up regardless of either swipe.

A tap is *always* a click on the remote — including in the top menu zone — so there is never a
dead spot on the screen. That is why the menu opens on a **swipe down** in KOReader's menu zone at
the top; with a physical keyboard, the **Menu** key (F1 on KOReader's own keymap) toggles it too.

**The menu** offers the connection list, a status line, the zoom presets, a "keyboard always
visible" toggle, show/hide keyboard, the screen orientation (including rotations), "use current
orientation as default", sending single keys (Enter/Tab/Esc/Delete), **Disconnect** (with a
confirmation) and **Leave (keep connection)**. If the connection has just dropped, it leads with
**Reconnect to …**.

**The keyboard** is drawn over the framebuffer and never rescales the view. A view that is too
large for the space above the keyboard keeps the whole screen — pan with two fingers to reach what
the keys cover — while a view that fits in that space is moved into it instead of hiding behind
the keys. The keyboard gets out of the way whenever a menu or dialog is open, and comes back when
it closes. Pick **Fit (with keyboard)** if you want the zoom itself to respect the keyboard: it
fits the whole remote screen into the space the keyboard leaves, and follows the keyboard.

**Leave (keep connection)** closes the viewer but keeps the session, the remote framebuffer and
Wi-Fi up, so reopening the viewer is instant. **Disconnect** closes the connection and restores
Wi-Fi if the plugin turned it on.

## Sharing this screen (VNC server)

The plugin can also serve the other way round: KOReader's own screen as a VNC desktop, so a
computer elsewhere can watch what your reader is showing and drive it with its mouse and keyboard.

It is **off by default**. Turn it on in KOReader's *Network* menu: **VNC server** — the entry is
checked while it runs and opens a submenu with

- **Start/Stop VNC server**,
- a status line (the address it listens on, and how many clients are connected),
- **Start with KOReader** — off by default; when on, the server starts by itself when KOReader
  starts (a manual stop still stops it, and it stays stopped until the next start),
- **IP address** — `0.0.0.0` (the default) serves every interface, `127.0.0.1` only this device,
- **Port** — 5900 by default,
- **Password** — clients must then authenticate (VNC Authentication); leave it empty and anybody
  who can reach the port gets in.

For scripted or headless setups a few environment variables override the server settings. They
apply to that run only and are **never written to the settings file** (the menu always shows and
edits the stored values):

| Variable | Effect |
| --- | --- |
| `VNC_KOPLUGIN_ENABLE_SERVER` | Start at boot. Any non-empty value except `0`, `no`, `false` (trimmed, case-insensitive) starts the server; empty or unset means "use the stored setting". |
| `VNC_KOPLUGIN_SERVER_HOST` | Bind address for this run; empty or unset leaves the stored one. |
| `VNC_KOPLUGIN_SERVER_PORT` | Port for this run (an integer 1–65535); anything else is ignored with a warning. |
| `VNC_KOPLUGIN_SERVER_PASSWORD` | Password for this run; set it empty for "no password". |

Setting the password by environment keeps it out of `settings/vnc.lua`.

On Kindles the plugin opens the port in the device's firewall while it runs (the same thing
KOReader's own HTTP inspector does) and closes it again when you stop the server.

Connect with any VNC viewer — `x11vnc`'s viewer, TigerVNC, Remmina, a phone app — to
`<reader-ip>:5900`. You see KOReader's screen; clicking, dragging and typing act on the reader.
Everything KOReader can do is therefore remote-controllable, so treat the password as important and
prefer a tunnel (SSH, WireGuard) if the network is not yours. **The server is only reachable while
it is started**, and KOReader must be running.

The server uses the viewer's own choice of encoding: it can produce **Raw, RRE, Hextile and ZRLE**
and takes the first entry of the client's preference list it can do, falling back to Raw when the
client asks for something else (Tight, TRLE, CopyRect). A large changed region is carried as several
rectangles of at most 256 px a side for the encoders that walk every pixel, so a full-screen change
cannot hold up the reader's UI; a Raw client is not tiled.

An incremental update request with nothing to answer is **held**, not answered with an empty update:
a viewer asks again the moment it is answered, so answering every time would be a ping-pong at the
poll rate. The hold ends as soon as something inside the region the request named has changed; a
client that has gone quiet with a request outstanding is sent one empty update a second as a sign of
life, and that sign of life deliberately does not release the hold, so the change still reaches it
afterwards. Viewers that keep their picture up to date without asking (the Continuous Updates
extension, client message 150) are supported too: whatever changes inside the region they enabled is
pushed to them. The community extensions real viewers send are handled rather than fatal — a Fence
ping is answered, and a client asking the server to resize the desktop is declined, because the
picture follows the reader's own screen.

A client's click is injected as a click: a press is buffered until it is known what it is — the
release (a click), motion of 4 px or more with the button down (a drag), or the reader's own
long-press interval (a long press). Both halves also set `TCP_NODELAY` on the socket, so a reply
that leaves as several small writes is not delayed by Nagle's algorithm.

What a client sees is KOReader's logical screen: the e-ink panel's own flash/ghosting is not
reproduced, and the on-screen keyboard, dialogs and rotations are simply part of the picture.

## Power consumption

The two halves behave very differently.

**The viewer** costs nothing while it is not connected: with no session open there is no timer, no
socket and no work of any kind. While a session is up, expect the usual power use of a network
connection and — mostly — of screen updates, because every frame has to be received, decoded and
drawn. A picture that does not change costs very little; a moving one costs what the update rate
implies.

**The server**:

- **Installed but not started**: no runtime overhead worth mentioning — nothing is scheduled, and
  nothing listens.
- **Started, nobody connected**: a small, steady overhead. The server keeps a lightweight check
  running about a hundred times a second so it can notice a connection as soon as one arrives — the
  network does not wake it up by itself. It is a constant, low-level cost, and you can expect it to
  show only as slightly shorter runtime on a battery-powered device.
- **A client connected**: a little more, because that is when the per-connection work and the
  network traffic happen. With a still screen even that stays very small — about one tiny
  keep-alive-sized packet a second, and no frame work at all until something on the screen actually
  changes.

One caveat matters more than the above on an e-reader: the server does not manage Wi-Fi itself — it
neither turns it on nor keeps it on — so a device that goes to sleep drops the connection. And
while Wi-Fi is up it is usually the **larger** part of the power bill, bigger than the server's own
periodic check.

## Settings

Connection profiles live in a plain Lua file inside KOReader's settings directory,
`settings/vnc.lua`:

```lua
return {
    ["profiles"] = {
        [1] = { ["name"] = "desktop", ["host"] = "10.0.0.5", ["port"] = 5900, ["password"] = "",
                ["autoconnect"] = true },  -- connect here at start (at most one profile may)
    },
    ["settings"] = {
        ["orientation"] = 0,               -- default screen orientation (0 = upright)
        ["keyboard_always_visible"] = false,
        ["zoom_mode"] = "fit",             -- "fit", "fit_with_keyboard" or 0.25 .. 4
        ["enable_tight"] = false,          -- opt-in Tight encoding, see below
    },
    ["server"] = {                         -- the VNC server (Network menu); 0.0.0.0 = any interface
        ["ip"] = "0.0.0.0",
        ["port"] = 5900,
        ["password"] = "",                 -- empty = no authentication at all
        ["autostart"] = false,             -- start the server with KOReader
    },
}
```

You never have to edit it by hand (the editor in the viewer writes it), but it is a good place to
keep a password out of the dialog. Unknown keys are dropped and missing ones defaulted when it is
loaded, so a broken file does not keep the plugin from starting; if a hand-edited file flags more
than one profile for `autoconnect`, the first keeps the flag and the rest are cleared.

> **Passwords are stored in clear text**, like KOReader itself does for OPDS and progress sync.
> VNC Authentication is a weak, DES-based scheme anyway, and **nothing in a VNC session is
> encrypted** — run it over SSH, WireGuard or a trusted network.

## Server compatibility

- RFB 3.8 with security type *None* or *VNC Authentication* (password). No TLS/VeNCrypt/SASL, so
  servers that require those cannot be used — as a client *and* as the server above.
- Encodings: ZRLE, TRLE, Hextile, RRE, CopyRect and Raw — all of RFC 6143 — plus DesktopSize
  (servers that resize their desktop are followed automatically).
- **Tight** compression is implemented but **off by default**: it is not part of RFC 6143 and
  servers interpret its control byte differently, so it is opt-in (`["enable_tight"] = true`) until
  it has been tested against the server you use.

## How this was written

This plugin is **vibe coded**: the code was written by a machine — **DeepSeek V4 Flash**, driven
prompt by prompt from a specification — with the protocol and the UI behaviour pinned down by the
tests described in `NOTES.txt`. Treat it as what it is: a hobby project that happens to be tested
rather than a polished product.

## Disclaimer

It comes with **no warranty** of any kind, and the developer may not be able to offer support for
it. Use it at your own risk, and keep in mind that a VNC session — including the password — travels
unencrypted, so do not expose it to a network you do not trust. Bug reports and patches are
welcome.

## For developers

`NOTES.txt` has the architecture, the internals, the test setup and what has and has not been
verified. The three suites it describes live in `tools/` and are run from the KOReader root with
KOReader's own LuaJIT:

    PLUGIN=~/.config/koreader/plugins/vnc.koplugin
    cd /usr/lib/koreader

    # the client protocol stack, over a real socket, against tools/mock_vnc_server.py
    LUA_PATH="$PLUGIN/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" \
      ./luajit "$PLUGIN/tools/proto_smoke.lua" --tmp "$HOME/vnc-smoke"   # --tmp=<dir> works as well

    # the dialogs and the viewer widget against KOReader's widget stack, headless
    KO_HOME="$HOME/vnc-smoke/ui" SDL_VIDEODRIVER=dummy \
      LUA_PATH="$PLUGIN/?.lua;;" LUA_CPATH="./common/?.so;;" \
      ./luajit "$PLUGIN/tools/ui_smoke.lua"

    # the server half: pixel formats, encoders, protocol, the real socket path, input injection
    KO_HOME="$HOME/vnc-smoke/server" SDL_VIDEODRIVER=dummy \
      LUA_PATH="$PLUGIN/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" \
      ./luajit "$PLUGIN/tools/server_smoke.lua"

`tools/mock_vnc_server.py` is the RFB fixture the client suite talks to — deterministic patterns in
every encoding, both security types, and every client message logged — and
`tools/tight_jpeg.b64` is the fixed 32×32 JPEG it serves for its Tight JPEG rectangle.
`tools/mock_vnc_client.py` is the independent Python client the server is proved against, so the
server is checked by something that is not this plugin's own code.

Keep the scratch directories on the home filesystem: a quota-limited `/tmp` makes the suites fail
(its default locations are under `/tmp`). The UI suite needs a **fresh** `KO_HOME` — it reuses fixed
paths under it — and `SDL_VIDEODRIVER=dummy` keeps the SDL emulator from opening a window without
changing what the checks see. `NOTES.txt` has the rest of the pitfalls, the live end-to-end recipe
(mock server plus a real KOReader driven through its HTTP inspector) and the open ends.
