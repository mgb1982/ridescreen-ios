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
