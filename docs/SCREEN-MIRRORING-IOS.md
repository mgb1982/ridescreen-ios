# iOS screen mirroring

## Goal

Mirror the full iPhone display to an EasyConn/Carbit motorcycle display while RideScreen is active and the iPhone remains unlocked. Screen capture starts only after the rider chooses RideScreen in Apple's broadcast picker. RideScreen must not save captured frames or include their contents in diagnostics.

## iOS capture path

The app's current deployment target is iOS 16. Ordinary `RPScreenRecorder` capture is limited to the RideScreen app. Capturing other apps requires a ReplayKit Broadcast Upload Extension using `RPBroadcastSampleHandler`, launched through `RPSystemBroadcastPickerView`. The system picker is the explicit consent step. The extension continues processing video samples after RideScreen leaves the foreground.

ScreenCaptureKit's newer iOS screen capture path is not the baseline because the app supports iOS 16.

## Motorcycle transport

The Android implementation in `ridescreen-aa-build/app/src/main/java/dev/zanderp/opencfmoto/EasyConnProber.kt` and `PxcHandshake.kt` is the protocol reference:

- Discover EasyConn on the motorcycle Wi-Fi.
- The phone listens on TCP 10920 (media data), 10921 (media control), and 10922 (PXC control); the motorcycle connects back to the phone.
- Complete the PXC control handshake and channel selection, then answer media requests.
- The dash pulls video with `REQ_RV_DATA_NEXT (114)`. Frames are H.264 Annex-B; the initial keyframe needs codec configuration (SPS/PPS).
- The phone must remain reachable on the motorcycle Wi-Fi while the app is in the background. Network discovery, local-network privacy, and the extension's network lifetime must be verified on a physical iPhone.

This is a custom EasyConn/PXC stream, not AirPlay. A ReplayKit picker or capture extension alone does not produce a motorcycle display image.

## Implementation milestones

1. Add a ReplayKit broadcast extension and an explicit RideScreen entry point. Verify that the extension starts only after system consent and receives screen sample buffers without persisting them.
2. Port EasyConn discovery and PXC control/media state to Swift. Keep the extension in charge of the long-lived background stream; share only connection settings and stream state with the app.
3. Encode ReplayKit video samples as H.264 Annex-B at the canvas size requested by the dash. Handle keyframes, SPS/PPS, pull cadence, back-pressure, stop, and reconnect.
4. Validate on an iPhone and the Zontes display: start, switch to another app, confirm the image and touch behavior, stop, and confirm the stream ends cleanly.

## Acceptance criteria

- CI builds both the app and broadcast extension for simulator and device.
- Starting capture always requires an explicit system picker action.
- No screen image, encoded frame, PKE credential, or full device identifier is written to logs or disk.
- A failed discovery, PXC handshake, encoder, or network session ends in a visible error and a clean stop.
- Physical testing confirms sustained video and correct aspect ratio on the motorcycle display. CI cannot validate the proprietary head-unit link.
