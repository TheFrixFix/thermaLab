import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../render/palette.dart';
import '../render/scene_layout.dart';
import '../t2s/camera_catalog.dart';
import '../t2s/flat_field.dart';
import '../t2s/shutter_correction.dart';
import '../t2s/t2s_commands.dart';
import '../t2s/t2s_frame.dart';
import '../t2s/temperature_model.dart';
import 'calibration_store.dart';
import 'camera_connection.dart';
import 'frame_processor.dart';
import 'measure_point.dart';
import 'probe_state.dart';
import 'shutter_control.dart';
import 'snapshot_export.dart';
import 'view_settings.dart';

export 'camera_connection.dart' show kKnownV2UsbIds, usbId;
export 'frame_processor.dart' show DisplaySource, FrameStats;
export 'measure_point.dart' show MeasurePoint;

/// The app's central state, used by every screen and by capture. Owns
/// the parts below, wires them together (the connect sequence, the frame
/// loop) and notifies listeners. Public members forward to the parts, so
/// callers need only this class.
class ProbeController extends ChangeNotifier {
  ProbeController() {
    _deviceEventsSub = _connection.camera.deviceEvents.listen((UvcDeviceEvent event) {
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
    _streamErrorSub = _connection.camera.streamErrors.listen((UvcStreamError e) {
      log('Stream error: ${e.message}');
    });
  }

  StreamSubscription<UvcDeviceEvent>? _deviceEventsSub;
  StreamSubscription<UvcStreamError>? _streamErrorSub;

  // ---------------------------------------------------------------------
  // Parts
  // ---------------------------------------------------------------------

  /// Model settings, busy flag, status line and log, shared by the parts.
  late final ProbeState _state = ProbeState(notify: notifyListeners);

  /// USB devices, the open camera, frame polling and commands.
  late final CameraConnection _connection = CameraConnection(
    state: _state,
    onFrame: _process,
  );

  /// Shutter correction, its automatic repetition and revision detection.
  late final ShutterControl _shutter = ShutterControl(
    state: _state,
    connection: _connection,
    dropImage: () => image = null,
  );

  /// Statistics, colour scale and markers of the latest frame.
  final FrameProcessor _processor = FrameProcessor();

  /// Lens shading and one-point calibration, per camera.
  late final CalibrationStore _calibration = CalibrationStore(
    state: _state,
    connection: _connection,
    shutter: _shutter,
    processor: _processor,
  );

  /// Display settings and their preferences.
  late final ViewSettings _view = ViewSettings(
    notify: notifyListeners,
    setAutoShutter: setAutoShutter,
  );

  /// User measurement points in sensor coordinates.
  final MeasurePoints _points = MeasurePoints();

  // ---------------------------------------------------------------------
  // Own state
  // ---------------------------------------------------------------------

  /// Latest picture, built from the processed frame.
  ui.Image? image;

  /// Tap point for the spot reading and the one-point calibration.
  (int, int)? point;

  /// Incremented whenever a new [image] is ready; capture and streaming
  /// listen to this instead of to every state change.
  final ValueNotifier<int> frameTick = ValueNotifier<int>(0);

  int _ticksAtLastStats = 0;
  bool _rendering = false;

  // ---------------------------------------------------------------------
  // Shared state and log
  // ---------------------------------------------------------------------

  ModelSettings get settings => _state.settings;
  set settings(ModelSettings value) => _state.settings = value;
  bool get busy => _state.busy;
  set busy(bool value) => _state.busy = value;
  String get status => _state.status;
  set status(String value) => _state.status = value;
  List<String> get logLines => _state.logLines;
  void log(String message) => _state.log(message);

  // ---------------------------------------------------------------------
  // Connection and commands
  // ---------------------------------------------------------------------

  List<UvcUsbDevice> get devices => _connection.devices;
  UvcUsbDevice? get device => _connection.device;
  List<UvcCameraMode> get modes => _connection.modes;
  UvcCameraMode? get mode => _connection.mode;
  bool get streaming => _connection.streaming;
  CameraFamily get family => _connection.family;
  KnownCamera? get knownModel => _connection.knownModel;
  String get cameraName => _connection.cameraName;
  bool get canTriggerShutter => _connection.canTriggerShutter;
  T2sFrame? get frame => _connection.frame;
  double get fps => _connection.fps;
  int get framesReceived => _connection.framesReceived;
  int get undecodableFrames => _connection.undecodableFrames;
  String get lastFrameInfo => _connection.lastFrameInfo;

  Future<void> refreshDevices() => _connection.refreshDevices();

  bool sendCommand(int value, String label, {bool quiet = false}) =>
      _connection.sendCommand(value, label, quiet: quiet);

  void triggerShutter() => _connection.triggerShutter();

  void setRange(MeasurementRange range) => _connection.setRange(range);

  /// Writes emissivity 0.95, 20 °C ambient/reflected, 1 m distance and
  /// commits them. Needed once on units that still report emissivity 0.02.
  Future<void> writeDefaultParameters() =>
      _connection.writeDefaultParameters();

  // ---------------------------------------------------------------------
  // Shutter
  // ---------------------------------------------------------------------

  ShutterCorrection? get correction => _shutter.correction;

  /// True while a V2 camera streams but has no shutter reference yet: the
  /// image would still show the raw stripes, so it is not shown.
  bool get calibrationPending => _shutter.calibrationPending;

  /// Repeat the shutter correction on its own as the camera drifts.
  bool get autoShutter => _shutter.autoShutter;

  /// Anchor corrected frames at the model's shutter level (true) or at the
  /// reference mean (false, the IR-Py-Thermal behaviour).
  bool get anchorToModel => _shutter.anchorToModel;

  static const double reNucFpaDelta = ShutterControl.reNucFpaDelta;
  static const Duration minReNucInterval = ShutterControl.minReNucInterval;

  /// Closes the shutter, waits until the picture stops changing and
  /// averages several frames into a per-pixel reference (V2 only).
  Future<void> runShutterCorrection() => _shutter.runShutterCorrection();

  void setAnchorToModel(bool value) => _shutter.setAnchorToModel(value);

  Future<void> setAutoShutter(bool value) => _shutter.setAutoShutter(value);

  void clearShutterCorrection() => _shutter.clearShutterCorrection();

  // ---------------------------------------------------------------------
  // Model settings and calibration
  // ---------------------------------------------------------------------

  void setRevision(HardwareRevision revision) {
    settings = settings.copyWith(revision: revision);
    log('Model revision set to ${revision.name}');
    _calibration.load();
  }

  void setShutterSource(ShutterSource source) {
    settings = settings.copyWith(shutterSource: source);
    log('Shutter temperature source: ${source.name}');
    _calibration.load();
  }

  /// Lens shading correction measured on a uniform surface (per camera).
  FlatField? get flatField => _calibration.flatField;

  Future<void> resetFlatField() => _calibration.resetFlatField();

  /// Measures the lens shading on a uniform surface. Returns a message for
  /// the user.
  Future<String> calibrateFlatField() => _calibration.calibrateFlatField();

  /// One-point calibration: makes the measured spot (tap point, else the
  /// centre) read [knownCelsius].
  Future<void> calibrateTo(double knownCelsius) =>
      _calibration.calibrateTo(knownCelsius, point);

  Future<void> resetCalibration() => _calibration.resetCalibration();

  // ---------------------------------------------------------------------
  // Latest frame
  // ---------------------------------------------------------------------

  Uint16List? get processedCounts => _processor.processedCounts;
  TemperatureTable? get table => _processor.table;
  FrameStats? get stats => _processor.stats;

  /// Colour scale of the latest frame, in °C.
  double get scaleLow => _processor.scaleLow;
  double get scaleHigh => _processor.scaleHigh;

  /// Hottest/coldest marker positions in sensor pixels, smoothed so they
  /// glide instead of jumping across evenly warm areas.
  (double, double)? get hotMarker => _processor.hotMarker;
  (double, double)? get coldMarker => _processor.coldMarker;

  static const double markerHysteresis = FrameProcessor.markerHysteresis;
  static const double markerSmoothing = FrameProcessor.markerSmoothing;

  /// Temperature of the 3x3 neighbourhood around a sensor pixel.
  double? temperatureAt(int x, int y) => _processor.temperatureAt(frame, x, y);

  /// Per-pixel temperatures of the latest frame in 1/50 °C (sensor
  /// orientation), -32768 where the model has no value. Used by the web
  /// viewer, which colours the image itself.
  Int16List? temperatureGrid() => _processor.temperatureGrid();

  void setPoint((int, int)? p) {
    point = p;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Display settings
  // ---------------------------------------------------------------------

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

  Future<void> loadPreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _view.load(prefs);
    _shutter.loadPreferences(prefs);
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

  void setDisplaySource(DisplaySource source) =>
      _view.setDisplaySource(source);

  Future<void> setPalette(Palette p) => _view.setPalette(p);

  Future<void> rotate() => _view.rotate();

  // ---------------------------------------------------------------------
  // Measurement points
  // ---------------------------------------------------------------------

  List<MeasurePoint> get measurePoints => _points.points;
  static const int maxMeasurePoints = MeasurePoints.max;

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

  // ---------------------------------------------------------------------
  // Connecting
  // ---------------------------------------------------------------------

  /// Lists devices and connects right away when exactly one known T2S+
  /// (or exactly one camera at all) is attached.
  Future<void> autoConnect() async {
    await refreshDevices();
    if (streaming || busy) return;
    final UvcUsbDevice? pick = _connection.autoConnectCandidate();
    if (pick != null) {
      log('Auto-connecting to ${pick.displayName}');
      await connect(pick);
    }
  }

  Future<void> connect(UvcUsbDevice target) async {
    if (busy) return;
    busy = true;
    status = 'Opening ${target.displayName}…';
    notifyListeners();
    try {
      await disconnect(keepLog: true);
      final StreamChoice? choice = await _connection.open(target);
      if (choice == null) return;
      _shutter.prepareFor(family, knownModel);
      if (!await _connection.startStream()) return;
      _shutter.streamStarted();
      await _calibration.load();
      status = 'Streaming';
      notifyListeners();

      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (family == CameraFamily.xtherm) {
        sendCommand(T2sCommand.rawMode, 'raw mode');
      } else {
        await _connection.setupTiny1c();
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
    if (_shutter.revisionPending) {
      _shutter.detectRevision();
      await _calibration.load();
    }
    await _shutter.correctAfterConnect();
  }

  Future<void> disconnect({bool keepLog = false}) async {
    _connection.stopPolling();
    _shutter.releaseHold();
    await _connection.close();
    _shutter.reset();
    _processor.reset();
    image = null;
    status = 'Not connected';
    if (!keepLog) logLines.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Frame loop
  // ---------------------------------------------------------------------

  /// Called by the connection for every decoded frame.
  void _process(T2sFrame f) {
    if (!_shutter.handleFrame(f)) return;
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

  /// Writes the current raw frame plus a JSON report and opens the share
  /// sheet, so the data can be analysed elsewhere.
  Future<void> exportSnapshot() => exportDiagnostics(this);

  @override
  void dispose() {
    frameTick.dispose();
    _connection.stopPolling();
    _deviceEventsSub?.cancel();
    _streamErrorSub?.cancel();
    image?.dispose();
    unawaited(disconnect(keepLog: true));
    super.dispose();
  }
}
