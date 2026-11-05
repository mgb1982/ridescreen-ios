# RideScreen iOS work log

## 2026-11-03

- Enforced the existing 28-character motorcycle-name limit while typing in the garage editor. The store already applied the same limit when persisting the value.
- Validation: awaiting GitHub Actions for the dedicated `codex/ios-bike-name-limit` pull request.
- PKE: Manel confirmed all commands work in build 57. The supplied iOS log shows successful BLE discovery, UART setup, challenge/status responses, and state polling; it contains no credential, MCU ID, or challenge values.
- OBD: transport for the Allstric adapter remains unverified on iPhone. Need an iPhone-side BLE discovery/Car Scanner check before implementing a transport-specific client. Do not infer BLE compatibility from the Android RFCOMM log or the listing's iOS claim.
- Physical checks still needed: verify the garage editor truncates at 28 characters on iPhone; verify the Allstric adapter's transport and supported RPM PID on iPhone/motorcycle.
- Deferred creation of the PKE BLE controller until the rider opens the PKE controls sheet. The Bluetooth permission should now be requested when opening PKE, not on app launch.
- Added the PKE entry label to the Spanish, Catalan and English string catalog.
- Validation: awaiting dedicated GitHub Actions build and simulator tests.
- Physical check still needed: confirm the permission prompt timing on iPhone, then connect and operate PKE with the Android and official Zontes apps closed.

## 2026-11-03 — Screen mirroring capture foundation

- Added a ReplayKit Broadcast Upload Extension and an explicit system broadcast picker on the home screen.
- The extension receives approved screen video samples and records only bounded sample counts in the system log. It does not save or transmit screen frames.
- Added localized capture UI for Spanish, Catalan, and English.
- Added standalone codecs for the PXC control frame, media request/response frame, and length-prefixed raw video response. These codecs are not connected to sockets yet.
- Pending: EasyConn discovery, PXC handshake/session, H.264 encoding/frame transport, CI validation, and physical iPhone + motorcycle display testing.

## 2026-11-05 — Mirror field test (Claude)

- Merged #9, #10 and #11. The broadcast entry moved from the home screen into a "Mirror test" sheet.
- Added `MirrorLinkTester`: joins nothing by itself; on the bike Wi‑Fi it opens 10920–10922, browses `_EasyConn._tcp`, sends MDNS_RESPOND to Bonjour hits and `<gateway>:10930` (Android identity first, then iOS), and logs which reverse sockets the dash opens plus their first command IDs. No handshake replies, no video. Log is copyable/shareable and contains no password or PKE data.
- Added a VisionKit QR reader for the projection QR (shows SSID and password to join manually), `NSLocalNetworkUsageDescription`, `NSBonjourServices` and a camera description.
- The picker now reads the extension's bundle ID from the embedded .appex (sideloading may rewrite IDs). The home card shows whether the screen is being captured (`UIScreen.isCaptured`).
- Added PXC codec tests against the Android byte layout and QR parser tests.
- Pending: physical test on Manel's 125X (SoftAP, 192.168.3.1).
