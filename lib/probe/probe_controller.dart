import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../render/palette.dart';
import '../render/scene_layout.dart';
import '../t2s/camera_catalog.dart';
import '../t2s/flat_field.dart';
import '../t2s/shutter_correction.dart';
import '../t2s/t2s_commands.dart';
import '../t2s/t2s_frame.dart';
import '../t2s/temperature_model.dart';
import '../t2s/tiny1c_commands.dart';
import 'frame_processor.dart';
import 'measure_point.dart';
import 'view_settings.dart';

export 'frame_processor.dart' show DisplaySource, FrameStats;
export 'measure_point.dart' show MeasurePoint;

/// USB IDs of cameras known to be T2S+ V2 units.
final Set<String> kKnownV2UsbIds = <String>{
  for (final KnownCamera c in kKnownCameras)
    if (c.revision == HardwareRevision.v2) c.usbId,
};

String usbId(int vendorId, int productId) =>
    '${vendorId.toRadixString(16).padLeft(4, '0')}:'
    '${productId.toRadixString(16).padLeft(4, '0')}';

class ProbeController extends ChangeNotifier {
  ProbeController() {
    _deviceEventsSub = _camera.deviceEvents.listen((UvcDeviceEvent event) {
      log('USB ${event.type.name}: ${event.device.displayName} '
          '(${usbId(event.device.vendorId, event.device.productId)})');
      if (event.type == UvcDeviceEventType.detached &&
          event.device.deviceId == device?.deviceId) {
        unawaited(disconnect(keepLog: true));
        refreshDevices();
      } else if (event.type == UvcDeviceEventType.attached && !streaming) {
        unawaited(autoConnect());
      } else {
        refreshDevices();
      }
    });
    _streamErrorSub = _camera.streamErrors.listen((UvcStreamError e) {
      log('Stream error: ${e.message}');
    });
  }

  final UvcCamera _camera = uvcCamera;
  StreamSubscription<UvcDeviceEvent>? _deviceEventsSub;
  StreamSubscription<UvcStreamError>? _streamErrorSub;

  // Connection state.
  List<UvcUsbDevice> devices = <UvcUsbDevice>[];
  UvcUsbDevice? device;
  List<UvcCameraMode> modes = <UvcCameraMode>[];
  UvcCameraMode? mode;
  bool get streaming => _pollTimer != null;
  bool busy = false;
  String status = 'Not connected';

  // Processing state.
  // Wall measurements (2026-11-06): with the closed shutter anchored at the
  // model level, taking the shutter temperature from the sensor reads about
  // 5 °C above the shutter register, matching the vendor app.
  ModelSettings settings = const ModelSettings(
    revision: HardwareRevision.v2,
    shutterSource: ShutterSource.fpa,
  );

  /// Display settings and their preferences.
  late final ViewSettings _view = ViewSettings(
    notify: notifyListeners,
    setAutoShutter: setAutoShutter,
  );
  DisplaySource get displaySource => _view.displaySource;
  Palette get palette => _view.palette;
  int get quarterTurns => _view.quarterTurns;
  double get minSpan => _view.minSpan;
  bool get fixedScale => _view.fixedScale;
  double get fixedMin => _view.fixedMin;
  double get fixedMax => _view.fixedMax;
  SceneLayout get layout => _view.layout;
  int get viewTurns => _view.viewTurns;
  int get labelOutline => _view.labelOutline;
  bool get flatFieldEnabled => _view.flatFieldEnabled;
  bool get mirror => _view.mirror;

  /// User measurement points in sensor coordinates.
  final MeasurePoints _points = MeasurePoints();
  List<MeasurePoint> get measurePoints => _points.points;
  static const int maxMeasurePoints = MeasurePoints.max;

  /// Incremented whenever a new [image] is ready; capture and streaming
  /// listen to this instead of to every state change.
  final ValueNotifier<int> frameTick = ValueNotifier<int>(0);

  /// Statistics, colour scale and markers of the latest frame.
  final FrameProcessor _processor = FrameProcessor();

  /// Colour scale of the latest frame, in °C.
  double get scaleLow => _processor.scaleLow;
  double get scaleHigh => _processor.scaleHigh;

  /// Lens shading correction measured on a uniform surface (per camera).
  FlatField? flatField;

  /// Hottest/coldest marker positions in sensor pixels, smoothed so they
  /// glide instead of jumping across evenly warm areas.
  (double, double)? get hotMarker => _processor.hotMarker;
  (double, double)? get coldMarker => _processor.coldMarker;

  static const double markerHysteresis = FrameProcessor.markerHysteresis;
  static const double markerSmoothing = FrameProcessor.markerSmoothing;
  ShutterCorrection? correction;
  T2sFrame? frame;
  Uint16List? get processedCounts => _processor.processedCounts;
  TemperatureTable? get table => _processor.table;
  FrameStats? get stats => _processor.stats;
  ui.Image? image;
  (int, int)? point;
  double fps = 0;
  int framesReceived = 0;
  int undecodableFrames = 0;
  String lastFrameInfo = '';

  final List<String> logLines = <String>[];

  Timer? _pollTimer;
  int _ticksAtLastStats = 0;
  int _lastSequence = -1;
  final Stopwatch _fpsWatch = Stopwatch();
  int _fpsFrames = 0;
  bool _rendering = false;
  bool _holdShutter = false;

  /// A shutter correction has been attempted since connecting.
  bool _correctionAttempted = false;

  /// Stream layout of the connected camera.
  CameraFamily family = CameraFamily.xtherm;

  /// Catalogue entry of the connected camera, null if unknown.
  KnownCamera? knownModel;

  /// Display name of the connected camera.
  String cameraName = '';

  /// Xtherm camera of unknown revision: decided from the first frames.
  bool _revisionPending = false;

  late final Tiny1cCommands _tiny1c = Tiny1cCommands(_camera.controlTransfer);

  /// Whether the app can trigger the camera's shutter (Tiny1-C modules
  /// calibrate on their own and offer no known command for it).
  bool get canTriggerShutter => family == CameraFamily.xtherm;

  /// True while a V2 camera streams but has no shutter reference yet: the
  /// image would still show the raw stripes, so it is not shown.
  bool get calibrationPending =>
      streaming &&
      family == CameraFamily.xtherm &&
      (_revisionPending ||
          (settings.revision == HardwareRevision.v2 &&
              correction == null &&
              !_correctionAttempted));

  /// Repeat the shutter correction on its own as the camera drifts.
  bool autoShutter = true;

  /// Anchor corrected frames at the model's shutter level (true) or at the
  /// reference mean (false, the IR-Py-Thermal behaviour).
  bool anchorToModel = true;
  double _correctionFpa = double.nan;
  final Stopwatch _correctionAge = Stopwatch();
  final Stopwatch _connectedFor = Stopwatch();

  /// The shutter takes a moment to open again; frames in that window still
  /// show the shutter and are not displayed.
  final Stopwatch _shutterReleased = Stopwatch();

  /// Sensor temperature change that triggers a new shutter correction.
  static const double reNucFpaDelta = 0.3;

  /// Minimum time between two automatic shutter corrections.
  static const Duration minReNucInterval = Duration(seconds: 20);

  void log(String message) {
    final DateTime now = DateTime.now();
    final String ts =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    logLines.add('$ts $message');
    if (logLines.length > 300) logLines.removeAt(0);
    debugPrint('[probe] $message');
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Devices
  // ---------------------------------------------------------------------

  Future<void> refreshDevices() async {
    try {
      devices = await _camera.listUsbDevices();
      for (final UvcUsbDevice d in devices) {
        log('Found ${d.displayName} ${usbId(d.vendorId, d.productId)} '
            'manufacturer="${d.manufacturerName}" product="${d.productName}" '
            'serial="${d.serialNumber}"');
      }
      if (devices.isEmpty) log('No UVC device found');
    } catch (e) {
      log('Listing devices failed: $e');
    }
    notifyListeners();
  }

  /// Lists devices and connects right away when exactly one known T2S+
  /// (or exactly one camera at all) is attached.
  Future<void> loadPreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _view.load(prefs);
    autoShutter = prefs.getBool('autoShutter') ?? true;
    notifyListeners();
  }

  /// Display settings shared with the web remote.
  Map<String, Object> viewSettings() => _view.toMap(
    autoShutter: autoShutter,
    flatFieldCalibrated: flatField != null,
  );

  /// Applies one display setting by name (from the settings page or the
  /// web remote) and persists it. Unknown keys are ignored.
  Future<void> applySetting(String key, Object? value) =>
      _view.apply(key, value);

  /// Changes the overlay layout; [persist] false while dragging.
  Future<void> setLayout(SceneLayout value, {bool persist = true}) =>
      _view.setLayout(value, persist: persist);

  Future<void> setMinSpan(double value) => _view.setMinSpan(value);

  // ---------------------------------------------------------------------
  // Measurement points
  // ---------------------------------------------------------------------

  MeasurePoint? addMeasurePoint(int x, int y) {
    final MeasurePoint? p = _points.add(x, y);
    if (p != null) notifyListeners();
    return p;
  }

  void moveMeasurePoint(MeasurePoint p, int x, int y) {
    _points.move(p, x, y);
    notifyListeners();
  }

  void removeMeasurePoint(MeasurePoint p) {
    _points.remove(p);
    notifyListeners();
  }

  /// Temperature of the 3x3 neighbourhood around a sensor pixel.
  double? temperatureAt(int x, int y) => _processor.temperatureAt(frame, x, y);

  /// Per-pixel temperatures of the latest frame in 1/50 °C (sensor
  /// orientation), -32768 where the model has no value. Used by the web
  /// viewer, which colours the image itself.
  Int16List? temperatureGrid() => _processor.temperatureGrid();

  Future<void> autoConnect() async {
    await refreshDevices();
    if (streaming || busy) return;
    final List<UvcUsbDevice> known = devices
        .where((UvcUsbDevice d) =>
            knownCamera(usbId(d.vendorId, d.productId)) != null)
        .toList();
    final List<UvcUsbDevice> pick = known.isNotEmpty ? known : devices;
    if (pick.length == 1) {
      log('Auto-connecting to ${pick.first.displayName}');
      await connect(pick.first);
    }
  }

  Future<void> connect(UvcUsbDevice target) async {
    if (busy) return;
    busy = true;
    status = 'Opening ${target.displayName}…';
    notifyListeners();
    try {
      await disconnect(keepLog: true);
      device = target;
      final String id = usbId(target.vendorId, target.productId);
      final KnownCamera? known = knownCamera(id);
      knownModel = known;
      log('Opening $id (${known?.name ?? 'model not in the catalogue'})');
      // Android requires CAMERA before it grants USB access to a UVC device.
      final bool cameraGranted = await _camera.ensureCameraPermission();
      log('Camera permission ${cameraGranted ? 'granted' : 'DENIED'}');
      if (!cameraGranted) {
        status = 'Camera permission denied';
        return;
      }
      await _camera.openUsbDevice(target.deviceId);
      log('USB device opened');

      modes = _camera.supportedModes();
      for (final UvcCameraMode m in modes) {
        log('Mode: ${m.label} (format ${m.frameFormat})');
      }
      final StreamChoice? choice = chooseStream(<OfferedMode>[
        for (int i = 0; i < modes.length; i++)
          OfferedMode(modes[i].formatName, modes[i].width, modes[i].height, i),
      ], known);
      if (choice == null) {
        status = 'Camera not supported';
        log('No supported stream layout among the offered modes');
        return;
      }
      mode = modes[choice.modeIndex];
      family = choice.family;
      log('Protocol ${family.name}: ${choice.reason}');
      if (family == CameraFamily.tiny1c) {
        // The module corrects itself; nothing to wait for.
        settings = settings.copyWith(revision: HardwareRevision.v1);
        _revisionPending = false;
        _correctionAttempted = true;
        cameraName = known?.name ?? 'Tiny1-C thermal camera';
      } else {
        final HardwareRevision? rev = known?.revision;
        _revisionPending = rev == null;
        if (rev != null) settings = settings.copyWith(revision: rev);
        cameraName = known?.name ?? 'Xtherm thermal camera';
      }
      log('Starting ${mode!.label}');
      final UvcPreviewStartResult result = await _camera.startPreview(
        mode!,
        policy: UvcPreviewPolicy.sequenceOnly,
        timeout: const Duration(seconds: 6),
      );
      log('Preview start: success=${result.success} '
          'frames=${result.validFrameCount} errors=${result.errorCount} '
          '${result.lastError ?? ''}');
      if (!result.success) {
        status = 'Stream did not start';
        return;
      }
      _startPolling();
      _connectedFor
        ..reset()
        ..start();
      await _loadCalibration();
      status = 'Streaming';
      notifyListeners();

      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (family == CameraFamily.xtherm) {
        sendCommand(T2sCommand.rawMode, 'raw mode');
      } else {
        await _setupTiny1c();
      }
    } catch (e) {
      status = 'Connect failed';
      log('Connect failed: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
    if (!streaming || family != CameraFamily.xtherm) return;
    // Let the raw stream settle, then decide the revision if needed: V2
    // frames are unusable without a shutter reference taken by the app,
    // V1 cameras correct themselves and only need a shutter click.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!streaming) return;
    if (_revisionPending) {
      _detectRevision();
      await _loadCalibration();
    }
    if (settings.revision == HardwareRevision.v2) {
      await runShutterCorrection();
    } else {
      triggerShutter();
      _correctionAttempted = true;
      notifyListeners();
    }
  }

  /// Uncorrected V2 frames show strong pixel-to-pixel stripes, frames a V1
  /// camera has corrected itself do not.
  void _detectRevision() {
    final T2sFrame? f = frame;
    _revisionPending = false;
    if (f == null) {
      settings = settings.copyWith(revision: HardwareRevision.v2);
      log('No frame to judge the revision; assuming V2');
      return;
    }
    double sum = 0;
    int n = 0;
    for (int y = 0; y < f.height; y += 2) {
      final int row = y * f.width;
      for (int x = 1; x < f.width; x++) {
        sum += (f.counts[row + x] - f.counts[row + x - 1]).abs();
        n++;
      }
    }
    final double pixelNoise = sum / n;
    final HardwareRevision rev =
        pixelNoise > 40 ? HardwareRevision.v2 : HardwareRevision.v1;
    settings = settings.copyWith(revision: rev);
    log('Revision ${rev.name} detected (pixel-to-pixel noise '
        '${pixelNoise.toStringAsFixed(1)} counts)');
  }

  Future<void> _setupTiny1c() async {
    try {
      await _tiny1c.setEmissivity(0.95);
      log('Tiny1-C: emissivity 0.95');
    } catch (e) {
      log('Tiny1-C setup command failed: $e');
    }
  }

  Future<void> disconnect({bool keepLog = false}) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _holdShutter = false;
    try {
      if (_camera.isPreviewing) await _camera.stopPreview();
      if (_camera.openedDeviceId != null) await _camera.closeUsbDevice();
    } catch (e) {
      log('Disconnect: $e');
    }
    frame = null;
    _correctionAttempted = false;
    _revisionPending = false;
    _processor.reset();
    image = null;
    correction = null;
    framesReceived = 0;
    undecodableFrames = 0;
    _lastSequence = -1;
    status = 'Not connected';
    if (!keepLog) logLines.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------

  bool sendCommand(int value, String label, {bool quiet = false}) {
    try {
      final Stopwatch sw = Stopwatch()..start();
      _camera.setControl(UvcControlId.zoomAbs, value);
      final int ms = sw.elapsedMilliseconds;
      if (!quiet) log('Sent $label (0x${value.toRadixString(16)}) in $ms ms');
      if (quiet && ms > 100) {
        debugPrint('[probe] slow control transfer $label: $ms ms');
      }
      return true;
    } catch (e) {
      log('Command $label (0x${value.toRadixString(16)}) failed: $e');
      return false;
    }
  }

  void triggerShutter() => sendCommand(T2sCommand.shutter, 'shutter');

  void setRange(MeasurementRange range) {
    if (family == CameraFamily.tiny1c) {
      // High gain = normal range, low gain = high temperature range.
      _tiny1c
          .setHighGain(range == MeasurementRange.normal)
          .then((_) => log('Tiny1-C: range ${range.name}'))
          .catchError((Object e) => log('Tiny1-C range command failed: $e'));
    } else {
      sendCommand(
        range == MeasurementRange.high
            ? T2sCommand.rangeHigh
            : T2sCommand.rangeNormal,
        'range ${range.name}',
      );
    }
    settings = settings.copyWith(range: range);
    notifyListeners();
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
      log('Parameter $label ${ok ? 'sent' : 'FAILED'}');
    }
    sendCommand(T2sCommand.saveParameters, 'save parameters');
  }

  /// Closes the shutter, waits until the picture stops changing and
  /// averages several frames into a per-pixel reference (V2 only).
  ///
  /// Uncorrected V2 frames carry a strong sensor gradient and column
  /// stripes that stay when the shutter is closed, so "uniform" cannot be
  /// tested directly. Instead: the picture jumps when the shutter moves in,
  /// then holds still. The difference to the open picture is logged as
  /// evidence that the shutter really closed.
  Future<void> runShutterCorrection() async {
    if (family == CameraFamily.tiny1c) {
      log('Tiny1-C cameras run their shutter calibration on their own');
      return;
    }
    if (settings.revision == HardwareRevision.v1) {
      triggerShutter();
      return;
    }
    if (busy || frame == null) return;
    busy = true;
    status = 'Shutter correction…';
    notifyListeners();
    try {
      final T2sFrame open = frame!;
      _holdShutter = true;
      unawaited(_keepShutterClosed());

      final Stopwatch settle = Stopwatch()..start();
      Uint16List? previous;
      int stable = 0;
      double change = double.nan;
      while (settle.elapsed < const Duration(seconds: 8)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final T2sFrame? f = frame;
        if (f == null || identical(f.counts, previous)) continue;
        if (previous != null) {
          change = blockStdDev(_diff(f.counts, previous), f.width, f.height);
        }
        final double vsOpen =
            blockStdDev(_diff(f.counts, open.counts), f.width, f.height);
        debugPrint('[probe]   t=${settle.elapsedMilliseconds} ms '
            'change=${change.toStringAsFixed(1)} '
            'vsOpen=${vsOpen.toStringAsFixed(1)} '
            'mean=${countsMean(f.counts).toStringAsFixed(1)}');
        previous = f.counts;
        final bool still = change.isFinite && change < 4.0;
        stable = settle.elapsedMilliseconds > 600 && still ? stable + 1 : 0;
        if (stable >= 3) break;
      }
      final T2sFrame closed = frame!;
      final double vsOpen = blockStdDev(
        _diff(closed.counts, open.counts),
        closed.width,
        closed.height,
      );
      final double meanShift =
          countsMean(closed.counts) - countsMean(open.counts);
      log('Shutter ${stable >= 3 ? 'settled' : 'NOT settled'} after '
          '${settle.elapsedMilliseconds} ms; closed vs open: structure '
          '${vsOpen.toStringAsFixed(1)}, mean shift '
          '${meanShift.toStringAsFixed(1)}');

      final List<Uint16List> refs = <Uint16List>[];
      final Stopwatch collect = Stopwatch()..start();
      while (refs.length < 15 &&
          collect.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final T2sFrame? f = frame;
        if (f == null) continue;
        if (refs.isNotEmpty && identical(refs.last, f.counts)) continue;
        refs.add(f.counts);
      }
      if (refs.length < 5) {
        log('Shutter correction failed: only ${refs.length} frames '
            'in ${collect.elapsedMilliseconds} ms');
        return;
      }
      correction = ShutterCorrection.fromFrames(
        refs,
        closed.width,
        closed.height,
      );
      _correctionFpa = closed.meta!.fpaTemp(closed.profile!);
      _correctionAge
        ..reset()
        ..start();
      log('Reference from ${refs.length} frames, mean '
          '${correction!.referenceMean.toStringAsFixed(1)}, '
          '${correction!.deadPixels.length} dead pixels');
    } catch (e) {
      log('Shutter correction failed: $e');
    } finally {
      _holdShutter = false;
      if (!_correctionAttempted) {
        // The last rendered image is still the raw, striped one; drop it so
        // the loading screen stays until the first corrected frame. (Not
        // disposed here: a pending paint may still hold it.)
        image = null;
      }
      _correctionAttempted = true;
      _shutterReleased
        ..reset()
        ..start();
      busy = false;
      status = 'Streaming';
      notifyListeners();
    }
  }

  static Int32List _diff(Uint16List a, Uint16List b) {
    final Int32List out = Int32List(a.length);
    for (int i = 0; i < a.length; i++) {
      out[i] = a[i] - b[i];
    }
    return out;
  }

  Future<void> _keepShutterClosed() async {
    while (_holdShutter) {
      sendCommand(T2sCommand.shutter, 'shutter', quiet: true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// V2 frames drift as the camera warms up. Take a new reference when the
  /// sensor temperature moved, or after a while: every minute during the
  /// first five minutes, every three minutes after that.
  void _maybeReNuc(T2sFrame f) {
    if (!autoShutter ||
        busy ||
        correction == null ||
        settings.revision != HardwareRevision.v2) {
      return;
    }
    final T2sMetadata? meta = f.meta;
    if (meta == null) return;
    final double fpa = meta.fpaTemp(f.profile!);
    final Duration interval = _connectedFor.elapsed < const Duration(minutes: 5)
        ? const Duration(minutes: 1)
        : const Duration(minutes: 3);
    final bool fpaMoved =
        _correctionFpa.isFinite && (fpa - _correctionFpa).abs() > reNucFpaDelta;
    final bool tooOld = _correctionAge.elapsed > interval;
    // While the camera warms up right after plugging in, the sensor moves
    // fast; never click the shutter more often than this.
    final bool tooSoon = _correctionAge.elapsed < minReNucInterval;
    if (!tooSoon && (fpaMoved || tooOld)) {
      log('Auto shutter correction (${fpaMoved ? 'sensor ${_correctionFpa.toStringAsFixed(2)} → ${fpa.toStringAsFixed(2)} °C' : 'after ${_correctionAge.elapsed.inSeconds} s'})');
      unawaited(runShutterCorrection());
    }
  }

  void setAnchorToModel(bool value) {
    anchorToModel = value;
    log('Shutter anchor: ${value ? 'model level' : 'reference mean'}');
  }

  Future<void> setAutoShutter(bool value) async {
    autoShutter = value;
    log('Auto shutter correction ${value ? 'on' : 'off'}');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoShutter', value);
  }

  void clearShutterCorrection() {
    correction = null;
    log('Shutter correction cleared');
  }

  // ---------------------------------------------------------------------
  // Model settings and calibration
  // ---------------------------------------------------------------------

  void setRevision(HardwareRevision revision) {
    settings = settings.copyWith(revision: revision);
    log('Model revision set to ${revision.name}');
    _loadCalibration();
  }

  void setShutterSource(ShutterSource source) {
    settings = settings.copyWith(shutterSource: source);
    log('Shutter temperature source: ${source.name}');
    _loadCalibration();
  }

  void setDisplaySource(DisplaySource source) =>
      _view.setDisplaySource(source);

  Future<void> setPalette(Palette p) => _view.setPalette(p);

  Future<void> rotate() => _view.rotate();

  void setPoint((int, int)? p) {
    point = p;
    notifyListeners();
  }

  String get _calibrationKey {
    final UvcUsbDevice? d = device;
    final String unit = d == null
        ? 'unknown'
        : '${usbId(d.vendorId, d.productId)}.${d.serialNumber}';
    return 'calibration.$unit.${settings.revision.name}.'
        '${settings.shutterSource.name}';
  }

  String get _flatFieldKey {
    final UvcUsbDevice? d = device;
    return d == null
        ? 'flatField.unknown'
        : 'flatField.${usbId(d.vendorId, d.productId)}.${d.serialNumber}';
  }

  Future<void> _loadFlatField() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? json = prefs.getString(_flatFieldKey);
    flatField = null;
    if (json == null) return;
    final Map<String, dynamic> m = jsonDecode(json) as Map<String, dynamic>;
    flatField = FlatField.fromCoefficients(
      (m['w'] as num).toInt(),
      (m['h'] as num).toInt(),
      <double>[for (final Object? v in m['c'] as List<dynamic>) (v! as num).toDouble()],
    );
    log('Loaded lens shading correction');
  }

  Future<void> resetFlatField() async {
    flatField = null;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_flatFieldKey);
    log('Lens shading correction removed');
  }

  /// Measures the lens shading on a uniform surface. Returns a message for
  /// the user.
  Future<String> calibrateFlatField() async {
    if (!streaming || frame == null) return 'No camera image';
    if (settings.revision == HardwareRevision.v2) {
      await runShutterCorrection();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    busy = true;
    status = 'Measuring lens shading…';
    notifyListeners();
    try {
      final List<Uint16List> frames = <Uint16List>[];
      final Stopwatch sw = Stopwatch()..start();
      Uint16List? last;
      while (frames.length < 25 && sw.elapsed < const Duration(seconds: 6)) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final Uint16List? c = _processor.preFlatCounts;
        if (c == null || identical(c, last)) continue;
        last = c;
        frames.add(c);
      }
      final T2sFrame? f = frame;
      if (frames.length < 10 || f == null) return 'Not enough frames';
      final FlatField? ff = FlatField.fit(frames, f.width, f.height);
      if (ff == null) return 'Could not fit the shading';
      flatField = ff;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _flatFieldKey,
        jsonEncode(<String, Object>{
          'w': ff.width,
          'h': ff.height,
          'c': ff.coefficients,
        }),
      );
      // Express the correction in °C around the current centre level.
      final TemperatureTable? t = table;
      String size = '${ff.maxOffset.toStringAsFixed(0)} counts';
      if (t != null && processedCounts != null) {
        final int centre =
            spotCount(processedCounts!, f.width, f.height, (f.width ~/ 2, f.height ~/ 2));
        final double dT =
            (t.lookup(centre + ff.maxOffset.round()) - t.lookup(centre)).abs();
        if (dT.isFinite) size = '${dT.toStringAsFixed(1)} °C';
      }
      log('Lens shading measured from ${frames.length} frames, '
          'largest correction $size');
      return 'Lens shading corrected (up to $size at the edges)';
    } finally {
      busy = false;
      status = 'Streaming';
      notifyListeners();
    }
  }

  Future<void> _loadCalibration() async {
    await _loadFlatField();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? json = prefs.getString(_calibrationKey);
    double shutterOffset = 0;
    double userOffset = 0;
    if (json != null) {
      final Map<String, dynamic> m = jsonDecode(json) as Map<String, dynamic>;
      shutterOffset = (m['shutterOffset'] as num?)?.toDouble() ?? 0;
      userOffset = (m['userOffset'] as num?)?.toDouble() ?? 0;
      log('Loaded calibration: shutterOffset=$shutterOffset '
          'userOffset=$userOffset');
    }
    settings = settings.copyWith(
      shutterOffset: shutterOffset,
      userOffset: userOffset,
    );
    notifyListeners();
  }

  Future<void> _saveCalibration() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _calibrationKey,
      jsonEncode(<String, double>{
        'shutterOffset': settings.shutterOffset,
        'userOffset': settings.userOffset,
      }),
    );
  }

  /// One-point calibration: makes the measured spot (tap point, else the
  /// centre) read [knownCelsius].
  Future<void> calibrateTo(double knownCelsius) async {
    final T2sFrame? f = frame;
    final Uint16List? counts = processedCounts;
    if (f == null || counts == null) return;
    final (int, int) at = point ?? (f.width ~/ 2, f.height ~/ 2);
    final int count = spotCount(counts, f.width, f.height, at);
    if (settings.revision == HardwareRevision.v2 && f.meta != null) {
      final double? solved = solveShutterOffset(
        meta: f.meta!,
        profile: f.profile!,
        settings: settings,
        count: count,
        targetCelsius: knownCelsius,
      );
      if (solved == null) {
        log('Calibration failed: model gives no value (NaN). '
            'Write default parameters first.');
        return;
      }
      settings = settings.copyWith(shutterOffset: solved, userOffset: 0);
      log('Calibrated: shutterOffset=${solved.toStringAsFixed(2)} '
          'for ${knownCelsius.toStringAsFixed(1)} °C at $at');
    } else {
      final TemperatureTable t = tableFor(f, settings.copyWith(userOffset: 0));
      final double current = t.lookup(count);
      if (current.isNaN) {
        log('Calibration failed: model gives no value (NaN).');
        return;
      }
      settings = settings.copyWith(userOffset: knownCelsius - current);
      log('Calibrated: userOffset=${settings.userOffset.toStringAsFixed(2)}');
    }
    await _saveCalibration();
    notifyListeners();
  }

  Future<void> resetCalibration() async {
    settings = settings.copyWith(shutterOffset: 0, userOffset: 0);
    await _saveCalibration();
    log('Calibration reset');
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
    final UvcRawFrame? raw = _camera.copyLatestRawFrame();
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
        log('Cannot decode frame: $lastFrameInfo');
      }
      return;
    }
    frame = decoded;
    _process(decoded);
  }

  void _process(T2sFrame f) {
    // While the shutter is closed the picture shows only the shutter; keep
    // the last image on screen like commercial cameras do.
    if (_holdShutter || _shutterReleased.isRunning &&
        _shutterReleased.elapsed < const Duration(milliseconds: 800)) {
      return;
    }
    _shutterReleased.stop();
    _maybeReNuc(f);
    final ({Uint16List shown, bool byTemperature}) result = _processor.process(
      f,
      settings: settings,
      correction: correction,
      anchorToModel: anchorToModel,
      flatField: flatField,
      flatFieldEnabled: flatFieldEnabled,
      point: point,
      displaySource: displaySource,
      scale: _view.scale,
    );

    if (framesReceived % 75 == 0) {
      final TemperatureTable t = table!;
      final FrameStats s = stats!;
      final Uint16List counts = processedCounts!;
      final int ticksNow = frameTick.value;
      final T2sMetadata? meta = f.meta;
      final String detail = meta == null
          ? 'family=${family.name} '
          : 'fpa=${meta.fpaTemp(f.profile!).toStringAsFixed(2)} '
                'shutterRaw=${meta.shutterRaw} '
                'shutterV2=${meta.shutterTempV2.toStringAsFixed(2)} '
                'cal00=${meta.cal00} '
                'level=${t.shutterLevel.toStringAsFixed(0)} '
                'refMean=${correction?.referenceMean.toStringAsFixed(0)} '
                'eps=${meta.emissivity.toStringAsFixed(3)} ';
      debugPrint('[probe] stats fps=${fps.toStringAsFixed(1)} '
          'rendered=${frameTick.value - _ticksAtLastStats} '
          'mean=${s.meanCount.toStringAsFixed(0)} std=${s.stdDev.toStringAsFixed(1)} '
          'structure=${blockStdDev(counts, f.width, f.height).toStringAsFixed(1)} '
          'centre=${s.centerTemp.toStringAsFixed(2)}C '
          'centreAlt=${s.centerTempAlt.toStringAsFixed(2)}C '
          'min=${s.minTemp.toStringAsFixed(1)} '
          'max=${s.maxTemp.toStringAsFixed(1)} '
          '$detail'
          'corr=${correction != null} rev=${settings.revision.name}');
      _ticksAtLastStats = ticksNow;
    }

    _render(
      result.shown,
      f.width,
      f.height,
      table!,
      result.byTemperature,
      scaleLow,
      scaleHigh,
    );
  }

  void _render(
    Uint16List counts,
    int w,
    int h,
    TemperatureTable t,
    bool byTemperature,
    double lo,
    double hi,
  ) {
    if (_rendering) return;
    final Uint32List colors = palette.rgba;
    final Uint32List pixels = Uint32List(w * h);
    if (byTemperature) {
      final double span = math.max(hi - lo, 0.5);
      // Colour per count, then per pixel.
      final Uint32List lut = Uint32List(kTableSize);
      for (int c = 0; c < kTableSize; c++) {
        final double temp = t.values[c];
        lut[c] = temp.isNaN
            ? 0xFF000000
            : colors[(((temp - lo) / span) * 255).round().clamp(0, 255)];
      }
      for (int i = 0; i < w * h; i++) {
        pixels[i] = lut[counts[i].clamp(0, kTableSize - 1)];
      }
    } else {
      // Plain counts, auto-ranged over this frame.
      int lo = 1 << 30;
      int hi = -1;
      for (final int v in counts) {
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
      final double span = math.max(1, hi - lo).toDouble();
      for (int i = 0; i < w * h; i++) {
        pixels[i] = colors[(((counts[i] - lo) / span) * 255).round().clamp(
          0,
          255,
        )];
      }
    }
    _rendering = true;
    ui.decodeImageFromPixels(
      pixels.buffer.asUint8List(),
      w,
      h,
      ui.PixelFormat.rgba8888,
      (ui.Image img) {
        image?.dispose();
        image = img;
        _rendering = false;
        frameTick.value++;
        notifyListeners();
      },
    );
  }

  // ---------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------

  /// Writes the current raw frame plus a JSON report and opens the share
  /// sheet, so the data can be analysed elsewhere.
  Future<void> exportSnapshot() async {
    final T2sFrame? f = frame;
    if (f == null) {
      log('Nothing to export yet');
      return;
    }
    try {
      final Directory dir = await getTemporaryDirectory();
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final File bin = File('${dir.path}/t2s_frame_$stamp.bin');
      await bin.writeAsBytes(f.rawBytes);
      final List<File> files = <File>[bin];
      if (correction != null) {
        final File ref = File('${dir.path}/t2s_shutter_reference_$stamp.f32');
        await ref.writeAsBytes(correction!.reference.buffer.asUint8List());
        files.add(ref);
      }

      final TemperatureTable? t = table;
      final FrameStats? s = stats;
      final Map<String, Object?> report = <String, Object?>{
        'app': 'thermaLab diagnostics',
        'timestamp': DateTime.now().toIso8601String(),
        'device': device == null
            ? null
            : <String, Object?>{
                'usbId': usbId(device!.vendorId, device!.productId),
                'manufacturer': device!.manufacturerName,
                'product': device!.productName,
                'serial': device!.serialNumber,
              },
        'modes': modes.map((UvcCameraMode m) => m.label).toList(),
        'mode': mode?.label,
        'frame': <String, Object?>{
          'width': f.width,
          'imageHeight': f.height,
          'bytes': f.rawBytes.length,
          'fps': fps,
          'framesReceived': framesReceived,
          'undecodableFrames': undecodableFrames,
        },
        'settings': <String, Object?>{
          'revision': settings.revision.name,
          'range': settings.range.name,
          'shutterOffset': settings.shutterOffset,
          'userOffset': settings.userOffset,
          'shutterCorrection': correction != null,
          'deadPixels': correction?.deadPixels.length,
        },
        'family': family.name,
        'camera': cameraName,
        'metadata': f.meta?.toJson(),
        'fpaTemp': f.meta?.fpaTemp(f.profile!),
        'model': t == null
            ? null
            : <String, Object?>{
                'shutterTempUsed': t.shutterTemp,
                'nanCount': t.nanCount,
                'samples': <String, double>{
                  for (int c = 0; c < kTableSize; c += 1024)
                    '$c': t.values[c],
                },
              },
        'stats': s == null
            ? null
            : <String, Object?>{
                'minCount': s.minCount,
                'maxCount': s.maxCount,
                'meanCount': s.meanCount,
                'stdDev': s.stdDev,
                'centerCount': s.centerCount,
                'centerTemp': s.centerTemp,
                'centerTempAlt': s.centerTempAlt,
                'minTemp': s.minTemp,
                'maxTemp': s.maxTemp,
                'point': point == null ? null : <int>[point!.$1, point!.$2],
                'pointTemp': s.pointTemp,
                'pointTempAlt': s.pointTempAlt,
              },
        'log': logLines,
      };
      final File json = File('${dir.path}/t2s_report_$stamp.json');
      await json.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      files.add(json);

      final ui.Image? img = image;
      if (img != null) {
        final ByteData? png = await img.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png != null) {
          final File pngFile = File('${dir.path}/t2s_image_$stamp.png');
          await pngFile.writeAsBytes(png.buffer.asUint8List());
          files.add(pngFile);
        }
      }

      await SharePlus.instance.share(
        ShareParams(
          files: files.map((File file) => XFile(file.path)).toList(),
          text: 'thermaLab diagnostics snapshot $stamp',
        ),
      );
      log('Exported ${files.length} files');
    } catch (e) {
      log('Export failed: $e');
    }
  }

  @override
  void dispose() {
    frameTick.dispose();
    _pollTimer?.cancel();
    _deviceEventsSub?.cancel();
    _streamErrorSub?.cancel();
    image?.dispose();
    unawaited(disconnect(keepLog: true));
    super.dispose();
  }
}
