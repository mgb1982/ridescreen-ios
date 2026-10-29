# RideScreen iOS

An independent iOS companion project for RideScreen AA, focused on recording rides and adding telemetry overlays to video.

## Project status

**Early scaffold. Not tested on a real device.** This repository currently establishes the project structure and a cloud build workflow. Trip recording, location tracking, video import, telemetry synchronization, and overlays are not implemented yet.

## Goals

- Record a ride route, elapsed time, distance, and location-derived speed.
- Import videos recorded on an iPhone or compatible action camera.
- Synchronize available trip telemetry with video and render an overlay.
- Keep the iOS app independent from the Android projection functionality.

## Build

The GitHub Actions workflow in `.github/workflows/ios-build.yml` runs two jobs on a macOS runner:

- **iOS Simulator build:** checks that the current SwiftUI project compiles for the simulator.
- **Unsigned device package:** compiles for iOS devices and uploads `RideScreenIOS-unsigned-IPA` as a temporary workflow artifact.

The device artifact is **unsigned and cannot be installed directly**. It is a build/package check and a starting point for a future signing workflow, not an installable release. Artifacts are retained for 7 days.

## Installation and signing

Device installation, signing, and distribution are not configured yet. Apple's free Personal Team signing requires Xcode and provisioning must be renewed periodically. Do not add Apple signing certificates, private keys, provisioning profiles, or account credentials to the repository.

## License

This project is licensed under **GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later)**. See [LICENSE](LICENSE).

## Contributions

The project is in its initial scaffold phase. Features and supported devices will be documented as they are implemented and tested.
