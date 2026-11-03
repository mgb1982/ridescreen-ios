# RideScreen iOS work log

## 2026-11-03

- Deferred creation of the PKE BLE controller until the rider opens the PKE controls sheet. The Bluetooth permission should now be requested when opening PKE, not on app launch.
- Added the PKE entry label to the Spanish, Catalan and English string catalog.
- Validation: awaiting dedicated GitHub Actions build and simulator tests.
- Physical check still needed: confirm the permission prompt timing on iPhone, then connect and operate PKE with the Android and official Zontes apps closed.
