# vncviewer.koplugin

A VNC (RFB 3.8) client for KOReader. Adds a **VNC viewer** entry to the file-browser main menu
(*More tools* → *VNC viewer*) that opens a full-screen remote-desktop viewer.

## Install

This is an out-of-tree plugin. Put the `vncviewer.koplugin` directory where KOReader looks for plugins
and make sure external plugins are enabled:

- Linux/desktop: `~/.config/koreader/plugins/vncviewer.koplugin`, covered by `extra_plugin_paths`
  in `settings.reader.lua`.
- The plugin must not be listed in `plugins_disable_external`/`plugins_disabled`.

Connection profiles and global settings are stored in
`~/.config/koreader/settings/vncviewer.lua`.

## Usage

Open the file browser, tap *More tools* → *VNC viewer*, then pick or create a connection.

Gestures (canvas below the toolbar):

- tap = left click
- long press = right click
- one-finger drag = move with the left button held
- two-finger drag = pan the view
- pinch / spread = zoom the view
- two-finger rotate = change screen orientation
- swipe up from the bottom / swipe down = show / hide the on-screen keyboard

## Tests

The protocol layer is tested against a bundled mock RFB server (`tools/mock_vnc_server.py`, python3) by a
standalone harness that talks to it over a real socket:

```sh
PLUGIN=~/.config/koreader/plugins/vncviewer.koplugin
cd /usr/lib/koreader && \
  LUA_PATH="$PLUGIN/?.lua;./common/?.lua;./common/?/init.lua;;" \
  LUA_CPATH="./common/?.so;;" \
  ./luajit "$PLUGIN/tools/proto_smoke.lua" --tmp /tmp/vncv_smoke
```

Expected: one `ok - <name>` line per check, exit code 0.

The live app is exercised end-to-end by driving it through KOReader's HTTP inspector (port 8989) while the
mock server is running; see the plugin plan for the exact commands.
