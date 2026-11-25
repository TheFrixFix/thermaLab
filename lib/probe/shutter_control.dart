import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../t2s/camera_catalog.dart';
import '../t2s/shutter_correction.dart';
import '../t2s/t2s_commands.dart';
import '../t2s/t2s_frame.dart';
import '../t2s/temperature_model.dart';
import 'camera_connection.dart';
import 'probe_state.dart';

/// Mean absolute difference between horizontal neighbours, on every second
/// row. Uncorrected V2 frames show strong pixel-to-pixel stripes, frames a
/// V1 camera has corrected itself do not.
double pixelNoise(T2sFrame f) {
  double sum = 0;
  int n = 0;
  for (int y = 0; y < f.height; y += 2) {
    final int row = y * f.width;
    for (int x = 1; x < f.width; x++) {
      sum += (f.counts[row + x] - f.counts[row + x - 1]).abs();
      n++;
    }
  }
  return sum / n;
}

HardwareRevision revisionFromNoise(double pixelNoise) =>
    pixelNoise > 40 ? HardwareRevision.v2 : HardwareRevision.v1;

/// The camera shutter: the V2 software shutter correction (closing the
/// shutter, taking the reference), repeating it as the camera drifts,
/// hiding frames while the shutter is closed, and deciding the hardware
/// revision of unknown Xtherm cameras.
class ShutterControl {
  ShutterControl({
    required this.state,
    required this.connection,
    required this.dropImage,
  });

  final ProbeState state;
  final CameraConnection connection;

  /// Drops the picture on screen without disposing it.
  final void Function() dropImage;

  ShutterCorrection? correction;

  /// Repeat the shutter correction on its own as the camera drifts.
  bool autoShutter = true;

  /// Anchor corrected frames at the model's shutter level (true) or at the
  /// reference mean (false, the IR-Py-Thermal behaviour).
  bool anchorToModel = true;

  bool _holdShutter = false;

  /// A shutter correction has been attempted since connecting.
  bool _correctionAttempted = false;

  /// Xtherm camera of unknown revision: decided from the first frames.
  bool revisionPending = false;

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

  /// True while a V2 camera streams but has no shutter reference yet: the
  /// image would still show the raw stripes, so it is not shown.
  bool get calibrationPending =>
      connection.streaming &&
      connection.family == CameraFamily.xtherm &&
      (revisionPending ||
          (state.settings.revision == HardwareRevision.v2 &&
              correction == null &&
              !_correctionAttempted));

  void loadPreferences(SharedPreferences prefs) {
    autoShutter = prefs.getBool('autoShutter') ?? true;
  }

  /// Sets up for a camera whose stream layout was just chosen.
  void prepareFor(CameraFamily family, KnownCamera? known) {
    if (family == CameraFamily.tiny1c) {
      // The module corrects itself; nothing to wait for.
      state.settings = state.settings.copyWith(revision: HardwareRevision.v1);
      revisionPending = false;
      _correctionAttempted = true;
    } else {
      final HardwareRevision? rev = known?.revision;
      revisionPending = rev == null;
      if (rev != null) {
        state.settings = state.settings.copyWith(revision: rev);
      }
    }
  }

  /// The stream runs; times the automatic re-correction from now.
  void streamStarted() {
    _connectedFor
      ..reset()
      ..start();
  }

  /// Stops holding the shutter closed (first step of a disconnect).
  void releaseHold() {
    _holdShutter = false;
  }

  /// Forgets the reference and the revision state (on disconnect).
  void reset() {
    _correctionAttempted = false;
    revisionPending = false;
    correction = null;
  }

  /// Decides the revision of an unknown Xtherm camera from its latest
  /// frame.
  void detectRevision() {
    final T2sFrame? f = connection.frame;
    revisionPending = false;
    if (f == null) {
      state.settings = state.settings.copyWith(revision: HardwareRevision.v2);
      state.log('No frame to judge the revision; assuming V2');
      return;
    }
    final double noise = pixelNoise(f);
    final HardwareRevision rev = revisionFromNoise(noise);
    state.settings = state.settings.copyWith(revision: rev);
    state.log('Revision ${rev.name} detected (pixel-to-pixel noise '
        '${noise.toStringAsFixed(1)} counts)');
  }

  /// First correction after connecting an Xtherm camera: V2 frames are
  /// unusable without a shutter reference taken by the app, V1 cameras
  /// correct themselves and only need a shutter click.
  Future<void> correctAfterConnect() async {
    if (state.settings.revision == HardwareRevision.v2) {
      await runShutterCorrection();
    } else {
      connection.triggerShutter();
      _correctionAttempted = true;
      state.notify();
    }
  }

  /// Called for every decoded frame. Returns false while the shutter
  /// covers the sensor (the frame is not shown); otherwise starts an
  /// automatic correction when due and returns true.
  bool handleFrame(T2sFrame f) {
    // While the shutter is closed the picture shows only the shutter; keep
    // the last image on screen like commercial cameras do.
    if (_holdShutter || _shutterReleased.isRunning &&
        _shutterReleased.elapsed < const Duration(milliseconds: 800)) {
      return false;
    }
    _shutterReleased.stop();
    _maybeReNuc(f);
    return true;
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
    if (connection.family == CameraFamily.tiny1c) {
      state.log('Tiny1-C cameras run their shutter calibration on their own');
      return;
    }
    if (state.settings.revision == HardwareRevision.v1) {
      connection.triggerShutter();
      return;
    }
    if (state.busy || connection.frame == null) return;
    state.busy = true;
    state.status = 'Shutter correction…';
    state.notify();
    try {
      final T2sFrame open = connection.frame!;
      _holdShutter = true;
      unawaited(_keepShutterClosed());

      final Stopwatch settle = Stopwatch()..start();
      Uint16List? previous;
      int stable = 0;
      double change = double.nan;
      while (settle.elapsed < const Duration(seconds: 8)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final T2sFrame? f = connection.frame;
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
      final T2sFrame closed = connection.frame!;
      final double vsOpen = blockStdDev(
        _diff(closed.counts, open.counts),
        closed.width,
        closed.height,
      );
      final double meanShift =
          countsMean(closed.counts) - countsMean(open.counts);
      state.log('Shutter ${stable >= 3 ? 'settled' : 'NOT settled'} after '
          '${settle.elapsedMilliseconds} ms; closed vs open: structure '
          '${vsOpen.toStringAsFixed(1)}, mean shift '
          '${meanShift.toStringAsFixed(1)}');

      final List<Uint16List> refs = <Uint16List>[];
      final Stopwatch collect = Stopwatch()..start();
      while (refs.length < 15 &&
          collect.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final T2sFrame? f = connection.frame;
        if (f == null) continue;
        if (refs.isNotEmpty && identical(refs.last, f.counts)) continue;
        refs.add(f.counts);
      }
      if (refs.length < 5) {
        state.log('Shutter correction failed: only ${refs.length} frames '
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
      state.log('Reference from ${refs.length} frames, mean '
          '${correction!.referenceMean.toStringAsFixed(1)}, '
          '${correction!.deadPixels.length} dead pixels');
    } catch (e) {
      state.log('Shutter correction failed: $e');
    } finally {
      _holdShutter = false;
      if (!_correctionAttempted) {
        // The last rendered image is still the raw, striped one; drop it so
        // the loading screen stays until the first corrected frame. (Not
        // disposed here: a pending paint may still hold it.)
        dropImage();
      }
      _correctionAttempted = true;
      _shutterReleased
        ..reset()
        ..start();
      state.busy = false;
      state.status = 'Streaming';
      state.notify();
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
      connection.sendCommand(T2sCommand.shutter, 'shutter', quiet: true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// V2 frames drift as the camera warms up. Take a new reference when the
  /// sensor temperature moved, or after a while: every minute during the
  /// first five minutes, every three minutes after that.
  void _maybeReNuc(T2sFrame f) {
    if (!autoShutter ||
        state.busy ||
        correction == null ||
        state.settings.revision != HardwareRevision.v2) {
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
      state.log('Auto shutter correction (${fpaMoved ? 'sensor ${_correctionFpa.toStringAsFixed(2)} → ${fpa.toStringAsFixed(2)} °C' : 'after ${_correctionAge.elapsed.inSeconds} s'})');
      unawaited(runShutterCorrection());
    }
  }

  void setAnchorToModel(bool value) {
    anchorToModel = value;
    state.log('Shutter anchor: ${value ? 'model level' : 'reference mean'}');
  }

  Future<void> setAutoShutter(bool value) async {
    autoShutter = value;
    state.log('Auto shutter correction ${value ? 'on' : 'off'}');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoShutter', value);
  }

  void clearShutterCorrection() {
    correction = null;
    state.log('Shutter correction cleared');
  }
}
