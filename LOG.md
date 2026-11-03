# RideScreen iOS change log

## 2026-11-03 — Screen mirroring capture foundation

- Added a ReplayKit Broadcast Upload Extension and an explicit system broadcast picker on the home screen.
- The extension receives approved screen video samples and records only bounded sample counts in the system log. It does not save or transmit screen frames.
- Added localized capture UI for Spanish, Catalan, and English.
- Added standalone codecs for the PXC control frame, media request/response frame, and length-prefixed raw video response. These codecs are not connected to sockets yet.
- Pending: EasyConn discovery, PXC handshake/session, H.264 encoding/frame transport, CI validation, and physical iPhone + motorcycle display testing.
