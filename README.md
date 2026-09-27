# VNC viewer for KOReader

Control a remote desktop from KOReader. The plugin adds **VNC viewer** to KOReader's file browser
menu: connect to a VNC server and the remote screen fills the display, with touch, the on-screen
keyboard and a physical keyboard driving the remote machine.

Works with ordinary VNC servers — x11vnc, TigerVNC, TightVNC, RealVNC (in compatibility mode) and
friends — over RFB 3.8, the protocol they all speak.

Current version: **v0.5**.

## What you get

- The remote framebuffer on the whole screen, scaled to fit, with zoom presets (fit screen, fit
  with the on-screen keyboard, or a fixed 25 % … 400 %) and panning for the rest.
- Touch control: tap = left click, long press = right click, drag = drag with the button held.
  Two-finger drag pans the view, pinch/spread zooms, two-finger rotate turns the screen.
- An on-screen keyboard that types into the remote session, plus a physical keyboard with
  modifiers, arrows, function keys and auto-repeat. Keys the on-screen keyboard does not have
  (Enter, Tab, Esc, Delete) are in the menu.
- Connection profiles (name, host, port, password) you can add, edit and delete from KOReader.
- Wi-Fi is turned on when a connection needs it and switched back off when you disconnect.
- **Leave** the viewer and the connection survives: reopen it and the picture is resynchronised.
  Only **Disconnect** closes the session.

## Install

1. On GitHub, download this repository as a ZIP: green **Code** button ▸ **Download ZIP**.
2. Unpack the ZIP.
3. Move the plugin folder into the `plugins` directory in your KOReader folder (create the
   `plugins` directory if it is not there yet). GitHub names the unpacked folder after the
   repository and the branch — `vncviewer.koplugin-main` — so rename it to **`vncviewer.koplugin`**
   while you are at it: KOReader only loads plugin directories whose name ends in `.koplugin`.
4. Restart KOReader.

That is all — there are no release artefacts to fetch, because the plugin is plain Lua and uses
only what KOReader already ships.

## Using it

Open the file browser menu in KOReader, then **More tools** ▸ **VNC viewer**. You get the
connection list; start with **New connection…** and enter the host, the port (5900 by default) and
the password your VNC server uses. Tap a connection to connect.

There is no permanent toolbar: the remote desktop owns the whole screen.

| Gesture | Effect |
| --- | --- |
| tap | left click |
| long press | right click |
| one-finger drag | drag with the left button held |
| two-finger drag | pan the view (does not move the remote pointer) |
| pinch / spread | zoom the view, keeping the point between the fingers fixed |
| two-finger rotate | change the screen orientation |
| swipe up from the bottom | show the on-screen keyboard |
| swipe down | hide it again |
| swipe down in the top menu zone | open the menu |

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

It is **off by default and never starts on its own**. Turn it on in KOReader's *Network* menu:
**VNC server** — the entry is checked while it runs and opens a submenu with

- **Start/Stop VNC server**,
- a status line (the address it listens on, and how many clients are connected),
- **IP address** — `0.0.0.0` (the default) serves every interface, `127.0.0.1` only this device,
- **Port** — 5900 by default,
- **Password** — clients must then authenticate (VNC Authentication); leave it empty and anybody
  who can reach the port gets in.

On Kindles the plugin opens the port in the device's firewall while it runs (the same thing
KOReader's own HTTP inspector does) and closes it again when you stop the server.

Connect with any VNC viewer — `x11vnc`'s viewer, TigerVNC, Remmina, a phone app — to
`<reader-ip>:5900`. You see KOReader's screen; clicking, dragging and typing act on the reader.
Everything KOReader can do is therefore remote-controllable, so treat the password as important and
prefer a tunnel (SSH, WireGuard) if the network is not yours. **The server is only reachable while
it is started**, and KOReader must be running.

What a client sees is KOReader's logical screen: the e-ink panel's own flash/ghosting is not
reproduced, and the on-screen keyboard, dialogs and rotations are simply part of the picture.

## Settings

Connection profiles live in a plain Lua file inside KOReader's settings directory,
`settings/vncviewer.lua`:

```lua
return {
    ["profiles"] = {
        [1] = { ["name"] = "desktop", ["host"] = "10.0.0.5", ["port"] = 5900, ["password"] = "" },
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
    },
}
```

You never have to edit it by hand (the editor in the viewer writes it), but it is a good place to
keep a password out of the dialog. Unknown keys are dropped and missing ones defaulted when it is
loaded, so a broken file does not keep the plugin from starting.

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
verified.
