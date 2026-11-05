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

1. **Capture foundation (implemented):** a ReplayKit broadcast extension and an explicit home-screen picker are in place. The handler receives approved video samples, counts them for bounded diagnostics, and discards the image data. It does not yet send video to the dash.
2. **Wire format foundation (implemented):** `PXCWireCodec.swift` handles the 16-byte control header, the 8-byte media header, and raw length-prefixed H.264 frame responses. It is not connected to network sockets yet.
3. **Connection and session (pending):** port EasyConn discovery, listener setup, PXC control handshake, media request handling, reconnect, and permissions/network behavior.
4. **Video and validation (pending):** encode ReplayKit samples as H.264 Annex-B at the canvas size requested by the dash, including keyframes/SPS/PPS, pull cadence, and back-pressure; then test on an iPhone and the Zontes display.

## Acceptance criteria

- CI builds both the app and broadcast extension for simulator and device.
- Starting capture always requires an explicit system picker action.
- No screen image, encoded frame, PKE credential, or full device identifier is written to logs or disk.
- A failed discovery, PXC handshake, encoder, or network session ends in a visible error and a clean stop.
- Physical testing confirms sustained video and correct aspect ratio on the motorcycle display. CI cannot validate the proprietary head-unit link.
