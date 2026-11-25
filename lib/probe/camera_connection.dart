import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

import '../t2s/camera_catalog.dart';
import '../t2s/t2s_commands.dart';
import '../t2s/t2s_frame.dart';
import '../t2s/temperature_model.dart';
import '../t2s/tiny1c_commands.dart';
import 'probe_state.dart';

/// USB IDs of cameras known to be T2S+ V2 units.
final Set<String> kKnownV2UsbIds = <String>{
  for (final KnownCamera c in kKnownCameras)
    if (c.revision == HardwareRevision.v2) c.usbId,
};

String usbId(int vendorId, int productId) =>
    '${vendorId.toRadixString(16).padLeft(4, '0')}:'
    '${productId.toRadixString(16).padLeft(4, '0')}';

/// The USB side of the camera: device list, opening a device and choosing
/// its stream, polling and decoding frames, and sending commands. The order
/// of a connect (open, start, load calibration, shutter) is up to
/// [ProbeController], which ties this to the other parts.
class CameraConnection {
  CameraConnection({required this.state, required this.onFrame});

  final ProbeState state;

  /// Called with every newly decoded frame, after [frame] is set.
  final void Function(T2sFrame frame) onFrame;

  final UvcCamera camera = uvcCamera;

  List<UvcUsbDevice> devices = <UvcUsbDevice>[];
  UvcUsbDevice? device;
  List<UvcCameraMode> modes = <UvcCameraMode>[];
  UvcCameraMode? mode;
  bool get streaming => _pollTimer != null;

  /// Stream layout of the connected camera.
  CameraFamily family = CameraFamily.xtherm;

  /// Catalogue entry of the connected camera, null if unknown.
  KnownCamera? knownModel;

  /// Display name of the connected camera.
  String cameraName = '';

  /// Whether the app can trigger the camera's shutter (Tiny1-C modules
  /// calibrate on their own and offer no known command for it).
  bool get canTriggerShutter => family == CameraFamily.xtherm;

  /// Latest decoded frame.
  T2sFrame? frame;
  double fps = 0;
  int framesReceived = 0;
  int undecodableFrames = 0;
  String lastFrameInfo = '';

  Timer? _pollTimer;
  int _lastSequence = -1;
  final Stopwatch _fpsWatch = Stopwatch();
  int _fpsFrames = 0;

  late final Tiny1cCommands _tiny1c = Tiny1cCommands(camera.controlTransfer);

  void _log(String message) => state.log(message);

  // ---------------------------------------------------------------------
  // Devices
  // ---------------------------------------------------------------------

  Future<void> refreshDevices() async {
    try {
      devices = await camera.listUsbDevices();
      for (final UvcUsbDevice d in devices) {
        _log('Found ${d.displayName} ${usbId(d.vendorId, d.productId)} '
            'manufacturer="${d.manufacturerName}" product="${d.productName}" '
            'serial="${d.serialNumber}"');
      }
      if (devices.isEmpty) _log('No UVC device found');
    } catch (e) {
      _log('Listing devices failed: $e');
    }
    state.notify();
  }

  /// The device to connect to on its own: the only known camera, or the
  /// only device at all. Null when the choice is not clear.
  UvcUsbDevice? autoConnectCandidate() {
    final List<UvcUsbDevice> known = devices
        .where((UvcUsbDevice d) =>
            knownCamera(usbId(d.vendorId, d.productId)) != null)
        .toList();
    final List<UvcUsbDevice> pick = known.isNotEmpty ? known : devices;
    return pick.length == 1 ? pick.first : null;
  }

  /// Opens [target] and chooses its stream layout and mode. Returns null
  /// (with [ProbeState.status] set) when that fails; throws on USB errors.
  Future<StreamChoice?> open(UvcUsbDevice target) async {
    device = target;
    final String id = usbId(target.vendorId, target.productId);
    final KnownCamera? known = knownCamera(id);
    knownModel = known;
    _log('Opening $id (${known?.name ?? 'model not in the catalogue'})');
    // Android requires CAMERA before it grants USB access to a UVC device.
    final bool cameraGranted = await camera.ensureCameraPermission();
    _log('Camera permission ${cameraGranted ? 'granted' : 'DENIED'}');
    if (!cameraGranted) {
      state.status = 'Camera permission denied';
      return null;
    }
    await camera.openUsbDevice(target.deviceId);
    _log('USB device opened');

    modes = camera.supportedModes();
    for (final UvcCameraMode m in modes) {
      _log('Mode: ${m.label} (format ${m.frameFormat})');
    }
    final StreamChoice? choice = chooseStream(<OfferedMode>[
      for (int i = 0; i < modes.length; i++)
        OfferedMode(modes[i].formatName, modes[i].width, modes[i].height, i),
    ], known);
    if (choice == null) {
      state.status = 'Camera not supported';
      _log('No supported stream layout among the offered modes');
      return null;
    }
    mode = modes[choice.modeIndex];
    family = choice.family;
    _log('Protocol ${family.name}: ${choice.reason}');
    cameraName = family == CameraFamily.tiny1c
        ? known?.name ?? 'Tiny1-C thermal camera'
        : known?.name ?? 'Xtherm thermal camera';
    return choice;
  }

  /// Starts the preview in the chosen [mode] and the frame polling.
  /// Returns false (with [ProbeState.status] set) when the stream did not
  /// start.
  Future<bool> startStream() async {
    _log('Starting ${mode!.label}');
    final UvcPreviewStartResult result = await camera.startPreview(
      mode!,
      policy: UvcPreviewPolicy.sequenceOnly,
      timeout: const Duration(seconds: 6),
    );
    _log('Preview start: success=${result.success} '
        'frames=${result.validFrameCount} errors=${result.errorCount} '
        '${result.lastError ?? ''}');
    if (!result.success) {
      state.status = 'Stream did not start';
      return false;
    }
    _startPolling();
    return true;
  }

  Future<void> setupTiny1c() async {
    try {
      await _tiny1c.setEmissivity(0.95);
      _log('Tiny1-C: emissivity 0.95');
    } catch (e) {
      _log('Tiny1-C setup command failed: $e');
    }
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Stops the preview, closes the device and forgets the frames. Call
  /// [stopPolling] first.
  Future<void> close() async {
    try {
      if (camera.isPreviewing) await camera.stopPreview();
      if (camera.openedDeviceId != null) await camera.closeUsbDevice();
    } catch (e) {
      _log('Disconnect: $e');
    }
    frame = null;
    framesReceived = 0;
    undecodableFrames = 0;
    _lastSequence = -1;
  }

  // ---------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------

  bool sendCommand(int value, String label, {bool quiet = false}) {
    try {
      final Stopwatch sw = Stopwatch()..start();
      camera.setControl(UvcControlId.zoomAbs, value);
      final int ms = sw.elapsedMilliseconds;
      if (!quiet) _log('Sent $label (0x${value.toRadixString(16)}) in $ms ms');
      if (quiet && ms > 100) {
        debugPrint('[probe] slow control transfer $label: $ms ms');
      }
      return true;
    } catch (e) {
      _log('Command $label (0x${value.toRadixString(16)}) failed: $e');
      return false;
    }
  }

  void triggerShutter() => sendCommand(T2sCommand.shutter, 'shutter');

  void setRange(MeasurementRange range) {
    if (family == CameraFamily.tiny1c) {
      // High gain = normal range, low gain = high temperature range.
      _tiny1c
          .setHighGain(range == MeasurementRange.normal)
          .then((_) => _log('Tiny1-C: range ${range.name}'))
          .catchError((Object e) => _log('Tiny1-C range command failed: $e'));
    } else {
      sendCommand(
        range == MeasurementRange.high
            ? T2sCommand.rangeHigh
            : T2sCommand.rangeNormal,
        'range ${range.name}',
      );
    }
    state.settings = state.settings.copyWith(range: range);
    state.notify();
  }

  /// Writes emissivity 0.95, 20 °C ambient/reflected, 1 m distance and
  /// commits them. Needed once on units that still report emissivity 0.02.
  Future<void> writeDefaultParameters() async {
    final List<(String, List<int>)> writes = <(String, List<int>)>[
      ('emissivity 0.95', encodeFloat(T2sParameter.emissivity, 0.95)),
      ('reflected 20 °C', encodeFloat(T2sParameter.reflectedTemp, 20)),
      ('air 20 °C', encodeFloat(T2sParameter.airTemp, 20)),
      ('distance 1 m', encodeUint16(T2sParameter.distance, 1)),
    ];
    for (final (String label, List<int> words) in writes) {
      bool ok = true;
      for (final int w in words) {
        ok &= sendCommand(w, label, quiet: true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      _log('Parameter $label ${ok ? 'sent' : 'FAILED'}');
    }
    sendCommand(T2sCommand.saveParameters, 'save parameters');
  }

  // ---------------------------------------------------------------------
  // Frame loop
  // ---------------------------------------------------------------------

  void _startPolling() {
    _fpsWatch
      ..reset()
      ..start();
    _fpsFrames = 0;
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => _poll(),
    );
  }

  void _poll() {
    final UvcRawFrame? raw = camera.copyLatestRawFrame();
    if (raw == null || raw.sequence == _lastSequence) return;
    _lastSequence = raw.sequence;
    framesReceived++;
    _fpsFrames++;
    if (_fpsWatch.elapsedMilliseconds > 1000) {
      fps = _fpsFrames * 1000 / _fpsWatch.elapsedMilliseconds;
      _fpsFrames = 0;
      _fpsWatch
        ..reset()
        ..start();
    }
    lastFrameInfo =
        'format ${raw.frameFormat}, ${raw.width}x${raw.height}, '
        '${raw.bytes.length} bytes, seq ${raw.sequence}';
    final T2sFrame? decoded = family == CameraFamily.tiny1c
        ? T2sFrame.decodeTiny1c(raw.bytes, raw.width, raw.height)
        : T2sFrame.decode(raw.bytes, raw.width, raw.height);
    if (decoded == null) {
      undecodableFrames++;
      if (undecodableFrames == 1 || undecodableFrames % 100 == 0) {
        _log('Cannot decode frame: $lastFrameInfo');
      }
      return;
    }
    frame = decoded;
    onFrame(decoded);
  }
}
