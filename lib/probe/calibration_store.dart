import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../t2s/flat_field.dart';
import '../t2s/t2s_frame.dart';
import '../t2s/temperature_model.dart';
import '../t2s/temperature_unit.dart';
import 'camera_connection.dart';
import 'frame_processor.dart';
import 'probe_state.dart';
import 'shutter_control.dart';

/// Per-camera calibration kept in the preferences: the lens shading (flat
/// field) and the one-point temperature calibration. Measures, loads,
/// saves and resets both.
///
/// The one-point calibration is stored per unit, revision and shutter
/// source; the lens shading only per unit.
class CalibrationStore {
  CalibrationStore({
    required this.state,
    required this.connection,
    required this.shutter,
    required this.processor,
  });

  final ProbeState state;
  final CameraConnection connection;
  final ShutterControl shutter;
  final FrameProcessor processor;

  /// Lens shading correction measured on a uniform surface (per camera).
  FlatField? flatField;

  String get _calibrationKey {
    final UvcUsbDevice? d = connection.device;
    final String unit = d == null
        ? 'unknown'
        : '${usbId(d.vendorId, d.productId)}.${d.serialNumber}';
    return 'calibration.$unit.${state.settings.revision.name}.'
        '${state.settings.shutterSource.name}';
  }

  String get _flatFieldKey {
    final UvcUsbDevice? d = connection.device;
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
    state.log('Loaded lens shading correction');
  }

  Future<void> resetFlatField() async {
    flatField = null;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_flatFieldKey);
    state.log('Lens shading correction removed');
  }

  /// Measures the lens shading on a uniform surface. Returns a message for
  /// the user, with the size of the correction in [unit].
  Future<String> calibrateFlatField(TemperatureUnit unit) async {
    if (!connection.streaming || connection.frame == null) {
      return 'No camera image';
    }
    if (state.settings.revision == HardwareRevision.v2) {
      await shutter.runShutterCorrection();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    state.busy = true;
    state.status = 'Measuring lens shading…';
    state.notify();
    try {
      final List<Uint16List> frames = <Uint16List>[];
      final Stopwatch sw = Stopwatch()..start();
      Uint16List? last;
      while (frames.length < 25 && sw.elapsed < const Duration(seconds: 6)) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final Uint16List? c = processor.preFlatCounts;
        if (c == null || identical(c, last)) continue;
        last = c;
        frames.add(c);
      }
      final T2sFrame? f = connection.frame;
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
      // Express the correction as a temperature around the centre level.
      final TemperatureTable? t = processor.table;
      final Uint16List? processedCounts = processor.processedCounts;
      String size = '${ff.maxOffset.toStringAsFixed(0)} counts';
      if (t != null && processedCounts != null) {
        final int centre =
            spotCount(processedCounts, f.width, f.height, (f.width ~/ 2, f.height ~/ 2));
        final double dT =
            (t.lookup(centre + ff.maxOffset.round()) - t.lookup(centre)).abs();
        if (dT.isFinite) size = unit.formatSpan(dT);
      }
      state.log('Lens shading measured from ${frames.length} frames, '
          'largest correction $size');
      return 'Lens shading corrected (up to $size at the edges)';
    } finally {
      state.busy = false;
      state.status = 'Streaming';
      state.notify();
    }
  }

  /// Loads the lens shading and the one-point calibration for the current
  /// device, revision and shutter source.
  Future<void> load() async {
    await _loadFlatField();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? json = prefs.getString(_calibrationKey);
    double shutterOffset = 0;
    double userOffset = 0;
    if (json != null) {
      final Map<String, dynamic> m = jsonDecode(json) as Map<String, dynamic>;
      shutterOffset = (m['shutterOffset'] as num?)?.toDouble() ?? 0;
      userOffset = (m['userOffset'] as num?)?.toDouble() ?? 0;
      state.log('Loaded calibration: shutterOffset=$shutterOffset '
          'userOffset=$userOffset');
    }
    state.settings = state.settings.copyWith(
      shutterOffset: shutterOffset,
      userOffset: userOffset,
    );
    state.notify();
  }

  Future<void> _saveCalibration() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _calibrationKey,
      jsonEncode(<String, double>{
        'shutterOffset': state.settings.shutterOffset,
        'userOffset': state.settings.userOffset,
      }),
    );
  }

  /// One-point calibration: makes the measured spot ([point], else the
  /// centre) read [knownCelsius].
  Future<void> calibrateTo(double knownCelsius, (int, int)? point) async {
    final T2sFrame? f = connection.frame;
    final Uint16List? counts = processor.processedCounts;
    if (f == null || counts == null) return;
    final (int, int) at = point ?? (f.width ~/ 2, f.height ~/ 2);
    final int count = spotCount(counts, f.width, f.height, at);
    if (state.settings.revision == HardwareRevision.v2 && f.meta != null) {
      final double? solved = solveShutterOffset(
        meta: f.meta!,
        profile: f.profile!,
        settings: state.settings,
        count: count,
        targetCelsius: knownCelsius,
      );
      if (solved == null) {
        state.log('Calibration failed: model gives no value (NaN). '
            'Write default parameters first.');
        return;
      }
      state.settings =
          state.settings.copyWith(shutterOffset: solved, userOffset: 0);
      state.log('Calibrated: shutterOffset=${solved.toStringAsFixed(2)} '
          'for ${knownCelsius.toStringAsFixed(1)} °C at $at');
    } else {
      final TemperatureTable t =
          tableFor(f, state.settings.copyWith(userOffset: 0));
      final double current = t.lookup(count);
      if (current.isNaN) {
        state.log('Calibration failed: model gives no value (NaN).');
        return;
      }
      state.settings =
          state.settings.copyWith(userOffset: knownCelsius - current);
      state.log('Calibrated: userOffset=${state.settings.userOffset.toStringAsFixed(2)}');
    }
    await _saveCalibration();
    state.notify();
  }

  Future<void> resetCalibration() async {
    state.settings = state.settings.copyWith(shutterOffset: 0, userOffset: 0);
    await _saveCalibration();
    state.log('Calibration reset');
  }
}
