# Architecture

Flutter app, Android only. Dart in `lib/`, a little Kotlin in `android/`,
USB through the vendored `packages/flutter_ffi_uvc` (libuvc, raw frames).

## Startup and data flow

`lib/main.dart` creates the long-lived objects and passes them down:

```
ProbeController ──frames──▶ buildScene() ──SceneData──▶ ScenePainter
 (USB, decoding,             lib/app/scene_builder.dart   screen, photo, video, stream
  markers, settings)
      │
      ├──▶ CsvLogger        temperature log
      └──▶ CaptureService   photo, video (Kotlin encoder), LiveServer (browser)
VisibleCamera + OverlayEngine   phone-camera overlay, switched off
```

Everything visible is drawn from one `SceneData`, so screen, photo, video and
stream always match. Settings persist through `shared_preferences`: display
settings in `ViewSettings`, calibration in `CalibrationStore`, the automatic
shutter switch in `ShutterControl`, capture, log and stream settings in
`CaptureService` and `CsvLogger`.

### Inside `ProbeController`

The rest of the app imports only `probe_controller.dart`, which re-exports
the few types callers need (`FrameStats`, `MeasurePoint`, …).
`ProbeController` is a thin `ChangeNotifier` that owns the parts in
`lib/probe/`, forwards its public members to them and runs the two sequences
that need several parts:

```
CameraConnection ──T2sFrame──▶ ShutterControl ──▶ FrameProcessor ──▶ ui.Image
 (poll, decode)                 hides frames         counts, stats,      built in
                                while closed,        scale, markers      ProbeController
                                re-corrects
```

- Frame loop: `CameraConnection` decodes each frame and hands it to the
  controller. `ShutterControl` drops it while the shutter is closed and starts
  an automatic correction when due. `FrameProcessor` computes counts,
  statistics and markers from the shutter reference, lens shading and display
  settings, and the controller builds the picture and tells capture and
  streaming that a new frame is ready.
- Connect: open the device and choose the stream (`CameraConnection`), set up
  the revision (`ShutterControl`), start the stream, load calibration
  (`CalibrationStore`), then for Xtherm cameras detect an unknown revision and
  take the first shutter reference.

The parts share model settings, the busy flag, the status line and the log
through `ProbeState`, and take each other in their constructors (connection ←
shutter ← calibration), so each file can be read on its own.
`FrameProcessor` and the revision check in `shutter_control.dart` are unit
tested: they need neither Flutter nor USB. The rest needs the camera, since
`CameraConnection` opens the native plugin when created.

## Files

| Path | Contents |
|---|---|
| `lib/t2s/` | Pure Dart, unit tested, no Flutter UI. |
| `t2s_frame.dart` | Xtherm frame layout, metadata, `CameraFamily`, `SensorProfile` |
| `temperature_model.dart` | Radiometric model, counts → °C lookup table |
| `camera_catalog.dart` | Known USB IDs, choice of protocol and video mode |
| `t2s_commands.dart`, `tiny1c_commands.dart` | Command words of the two protocols |
| `shutter_correction.dart` | V2 software shutter (non-uniformity) correction |
| `flat_field.dart` | Lens shading correction |
| `lib/probe/` | |
| `probe_controller.dart` | **Central state**: `ProbeController`, the facade the app uses. Owns the parts below, runs connect and the frame loop, builds the picture |
| `probe_state.dart` | `ProbeState`: model settings, busy flag, status line and log, shared by the parts below so they need not know `ProbeController` |
| `camera_connection.dart` | `CameraConnection`: USB device list, opening a camera and choosing its stream, frame polling and decoding, camera commands |
| `shutter_control.dart` | `ShutterControl`: V2 shutter correction, automatic repetition as the camera drifts, hiding frames while the shutter is closed, V1/V2 detection for unknown cameras |
| `calibration_store.dart` | `CalibrationStore`: lens shading and one-point calibration per camera: measuring, loading, saving, resetting |
| `frame_processor.dart` | `FrameProcessor`: corrected counts, statistics, colour scale, hottest/coldest markers. No Flutter or USB, unit tested |
| `measure_point.dart` | `MeasurePoint` and `MeasurePoints`: the user's measurement points |
| `view_settings.dart` | `ViewSettings`: display settings (palette, scale, rotation, layout…) and their preferences, applied by name from the settings page and the web remote |
| `snapshot_export.dart` | Diagnostics export: raw frame, shutter reference, JSON report and picture to the share sheet |
| `probe_page.dart` | Diagnostics screen |
| `lib/render/` | |
| `scene_painter.dart` | `SceneData`, `SceneMarker`, `ScenePainter`: draws a frame with all overlays |
| `scene_layout.dart` | Which elements show and where the movable ones sit |
| `geometry.dart` | Rotation and mirroring of sensor coordinates |
| `palette.dart` | Colour maps |
| `lib/app/` | |
| `viewer_page.dart` | Main screen, gestures, release button |
| `edit_panel.dart` | Edit mode controls |
| `settings_page.dart` | Settings screen |
| `scene_builder.dart` | `buildScene()`: controller state → `SceneData` |
| `overlay_calibration_page.dart` | Overlay calibration (hidden feature) |
| `lib/capture/` | |
| `capture_service.dart` | Photo, video, stream, remote commands from the browser; method channel `t2s_thermal/video` |
| `csv_logger.dart` | CSV temperature log |
| `live_server.dart` | HTTP and WebSocket server, see [web-protocol.md](web-protocol.md) |
| `lib/overlay/` | Phone-camera overlay (edges or blend, automatic alignment), switched off in `overlay_feature.dart`: too slow, and with the cameras ~10 cm apart and no depth data one calibration fits one distance only. `visible_camera.dart` (phone camera), `alignment.dart` (image matching), `overlay_engine.dart` (calibration and tracking) |
| `assets/web/index.html` | Browser viewer, one file, no external resources |
| `android/app/src/main/kotlin/…/` | `MainActivity.kt` (channel), `VideoEncoder.kt` (H.264) |
| `packages/flutter_ffi_uvc/` | Vendored libuvc plugin; changes listed in its `FORK.md` |
| `test/` | Unit tests, mostly for `lib/t2s/`, `lib/render/`, `frame_processor.dart` and the revision check in `shutter_control.dart`; `t2s_fixture.dart` builds fake frames |
| `tools/make_icon.py` | Generates the app icon |

## Where to change things

- New camera model: `camera_catalog.dart`, then [cameras.md](cameras.md).
- New display setting: state, preference and settings key in
  `view_settings.dart`, a forwarding getter in `probe_controller.dart`,
  drawing in `scene_painter.dart`, control in `edit_panel.dart`, remote
  `set` key in `capture_service.dart` and `assets/web/index.html`.
- Statistics, colour scale, hottest/coldest markers: `frame_processor.dart`,
  with tests in `test/frame_processor_test.dart`.
- Shutter correction or its timing: `shutter_control.dart`.
- Lens shading or one-point calibration: `calibration_store.dart`. Its
  preference keys hold users' calibrations; do not rename them.
- USB, stream choice, camera commands: `camera_connection.dart`; the order of
  the connect steps is in `probe_controller.dart`.
- New marker or overlay element: `SceneData` and `ScenePainter`, layout in
  `scene_layout.dart`.
- New remote command: `capture_service.dart` (handler) and
  `assets/web/index.html`; the wire format is in `live_server.dart`.
