import 'dart:math' as math;
import 'dart:typed_data';

import '../t2s/flat_field.dart';
import '../t2s/shutter_correction.dart';
import '../t2s/t2s_frame.dart';
import '../t2s/temperature_model.dart';

enum DisplaySource { temperature, correctedCounts, rawCounts }

/// Statistics of one processed frame.
class FrameStats {
  const FrameStats({
    required this.minCount,
    required this.maxCount,
    required this.meanCount,
    required this.stdDev,
    required this.centerCount,
    required this.minTemp,
    required this.maxTemp,
    required this.centerTemp,
    required this.centerTempAlt,
    required this.pointTempAlt,
    required this.pointCount,
    required this.pointTemp,
    required this.hottest,
    required this.coldest,
    required this.nanCount,
    required this.scaleLow,
    required this.scaleHigh,
  });

  final int minCount;
  final int maxCount;
  final double meanCount;
  final double stdDev;
  final int centerCount;
  final double minTemp;
  final double maxTemp;
  final double centerTemp;

  /// Same spots evaluated with the other [ShutterSource], for comparison.
  final double centerTempAlt;
  final double? pointTempAlt;
  final int? pointCount;
  final double? pointTemp;
  final (int, int) hottest;
  final (int, int) coldest;
  final int nanCount;
  final double scaleLow;
  final double scaleHigh;
}

/// How the colour scale is chosen; part of the display settings.
typedef ScaleOptions = ({
  bool fixedScale,
  double fixedMin,
  double fixedMax,
  double minSpan,
});

/// Turns decoded frames into corrected counts, temperatures, statistics,
/// colour scale and hottest/coldest markers. Pure Dart (no Flutter, no USB)
/// so it can be unit tested; building the picture happens in the caller.
///
/// Stateful only where the result depends on earlier frames (the markers)
/// and to keep the latest results for readers between frames.
class FrameProcessor {
  /// A new hottest/coldest pixel takes over only if it beats the current
  /// one by this much.
  static const double markerHysteresis = 0.2;

  /// Fraction of the remaining distance a marker moves per frame.
  static const double markerSmoothing = 0.35;

  TemperatureTable? table;

  /// Shutter-corrected counts before the lens shading correction, used to
  /// measure the shading.
  Uint16List? preFlatCounts;
  Uint16List? processedCounts;
  FrameStats? stats;

  /// Colour scale of the latest frame, in °C.
  double scaleLow = 0;
  double scaleHigh = 1;

  /// Hottest/coldest marker positions in sensor pixels, smoothed so they
  /// glide instead of jumping across evenly warm areas.
  (double, double)? hotMarker;
  (double, double)? coldMarker;
  (int, int)? _hotTarget;
  (int, int)? _coldTarget;

  /// Forgets the latest results and marker positions (on disconnect).
  /// [scaleLow], [scaleHigh] and [preFlatCounts] are kept.
  void reset() {
    hotMarker = null;
    coldMarker = null;
    _hotTarget = null;
    _coldTarget = null;
    processedCounts = null;
    table = null;
    stats = null;
  }

  /// Processes one frame and returns the counts to draw and whether to
  /// colour them by temperature over [scaleLow]..[scaleHigh] (else by
  /// counts, auto-ranged).
  ({Uint16List shown, bool byTemperature}) process(
    T2sFrame f, {
    required ModelSettings settings,
    required ShutterCorrection? correction,
    required bool anchorToModel,
    required FlatField? flatField,
    required bool flatFieldEnabled,
    required (int, int)? point,
    required DisplaySource displaySource,
    required ScaleOptions scale,
  }) {
    final TemperatureTable t = tableFor(f, settings);
    table = t;
    final bool useCorrection =
        settings.revision == HardwareRevision.v2 && correction != null;
    // Anchor the closed-shutter level where the model expects the shutter
    // temperature, instead of at the drifting reference mean.
    Uint16List counts = useCorrection
        ? correction.apply(
            f.counts,
            level: anchorToModel ? t.shutterLevel : null,
          )
        : f.counts;
    preFlatCounts = counts;
    final FlatField? ff = flatField;
    if (flatFieldEnabled &&
        ff != null &&
        ff.width == f.width &&
        ff.height == f.height) {
      counts = ff.apply(counts);
    }
    processedCounts = counts;
    final TemperatureTable alt = f.meta == null
        ? t
        : TemperatureTable.build(
            f.meta!,
            f.profile!,
            settings.copyWith(
              shutterSource: settings.shutterSource == ShutterSource.register
                  ? ShutterSource.fpa
                  : ShutterSource.register,
            ),
          );

    final int n = f.width * f.height;
    int minC = 1 << 30;
    int maxC = -1;
    int minI = 0;
    int maxI = 0;
    double sum = 0;
    double sumSq = 0;
    final Uint32List histogram = Uint32List(kTableSize);
    for (int i = 0; i < n; i++) {
      final int v = counts[i].clamp(0, kTableSize - 1);
      histogram[v]++;
      sum += v;
      sumSq += v.toDouble() * v;
      if (v < minC) {
        minC = v;
        minI = i;
      }
      if (v > maxC) {
        maxC = v;
        maxI = i;
      }
    }
    final double mean = sum / n;
    final double std = math.sqrt(math.max(0, sumSq / n - mean * mean));

    // Robust display range: 0.5 % / 99.5 % percentiles of the counts.
    final int lowCount = percentile(histogram, n, 0.005);
    final int highCount = percentile(histogram, n, 0.995);

    final (int, int) center = (f.width ~/ 2, f.height ~/ 2);
    final int centerCount = spotCount(counts, f.width, f.height, center);
    int? pointCount;
    if (point != null) {
      pointCount = spotCount(counts, f.width, f.height, point);
    }

    final bool showTemp =
        displaySource == DisplaySource.temperature &&
        !t.lookup(centerCount).isNaN;
    double low = t.lookup(lowCount);
    double high = t.lookup(highCount);
    if (low > high) (low, high) = (high, low);
    if (scale.fixedScale && scale.fixedMax > scale.fixedMin) {
      low = scale.fixedMin;
      high = scale.fixedMax;
    } else if (high - low < scale.minSpan) {
      final double mid = (high + low) / 2;
      low = mid - scale.minSpan / 2;
      high = mid + scale.minSpan / 2;
    }
    scaleLow = low;
    scaleHigh = high;
    _trackExtremes(counts, f.width, t, maxI, minI);

    stats = FrameStats(
      minCount: minC,
      maxCount: maxC,
      meanCount: mean,
      stdDev: std,
      centerCount: centerCount,
      minTemp: t.lookup(minC),
      maxTemp: t.lookup(maxC),
      centerTemp: t.lookup(centerCount),
      centerTempAlt: alt.lookup(centerCount),
      pointTempAlt: pointCount == null ? null : alt.lookup(pointCount),
      pointCount: pointCount,
      pointTemp: pointCount == null ? null : t.lookup(pointCount),
      hottest: (maxI % f.width, maxI ~/ f.width),
      coldest: (minI % f.width, minI ~/ f.width),
      nanCount: t.nanCount,
      scaleLow: showTemp ? low : lowCount.toDouble(),
      scaleHigh: showTemp ? high : highCount.toDouble(),
    );

    final Uint16List shown = displaySource == DisplaySource.rawCounts
        ? f.counts
        : counts;
    return (shown: shown, byTemperature: showTemp);
  }

  /// Moves the hottest/coldest markers: a new extreme only takes over when
  /// it beats the current spot by [markerHysteresis], and the drawn
  /// position glides towards its target.
  void _trackExtremes(
    Uint16List counts,
    int width,
    TemperatureTable t,
    int maxIndex,
    int minIndex,
  ) {
    double tempAt((int, int) p) => t.lookup(counts[p.$2 * width + p.$1]);
    final (int, int) newHot = (maxIndex % width, maxIndex ~/ width);
    final (int, int) newCold = (minIndex % width, minIndex ~/ width);
    final (int, int)? hot = _hotTarget;
    if (hot == null || tempAt(newHot) - tempAt(hot) > markerHysteresis) {
      _hotTarget = newHot;
    }
    final (int, int)? cold = _coldTarget;
    if (cold == null || tempAt(cold) - tempAt(newCold) > markerHysteresis) {
      _coldTarget = newCold;
    }
    hotMarker = _glide(hotMarker, _hotTarget!);
    coldMarker = _glide(coldMarker, _coldTarget!);
  }

  static (double, double) _glide((double, double)? from, (int, int) to) {
    if (from == null) return (to.$1.toDouble(), to.$2.toDouble());
    return (
      from.$1 + (to.$1 - from.$1) * markerSmoothing,
      from.$2 + (to.$2 - from.$2) * markerSmoothing,
    );
  }

  /// Temperature of the 3x3 neighbourhood around a sensor pixel of [f],
  /// read from the latest processed counts.
  double? temperatureAt(T2sFrame? f, int x, int y) {
    final Uint16List? counts = processedCounts;
    final TemperatureTable? t = table;
    if (f == null || counts == null || t == null) return null;
    return t.lookup(spotCount(counts, f.width, f.height, (x, y)));
  }

  /// Per-pixel temperatures of the latest frame in 1/50 °C (sensor
  /// orientation), -32768 where the model has no value. Used by the web
  /// viewer, which colours the image itself.
  Int16List? temperatureGrid() {
    final Uint16List? counts = processedCounts;
    final TemperatureTable? t = table;
    if (counts == null || t == null) return null;
    final Int16List lut = Int16List(kTableSize);
    for (int c = 0; c < kTableSize; c++) {
      final double v = t.values[c];
      lut[c] = v.isNaN ? -32768 : (v * 50).round().clamp(-32767, 32767);
    }
    final Int16List out = Int16List(counts.length);
    for (int i = 0; i < counts.length; i++) {
      out[i] = lut[counts[i].clamp(0, kTableSize - 1)];
    }
    return out;
  }
}

/// Count-to-°C table for a frame: the radiometric model for Xtherm
/// cameras, a plain linear table for cameras that deliver temperatures.
TemperatureTable tableFor(T2sFrame f, ModelSettings s) => f.meta == null
    ? TemperatureTable.linear(s)
    : TemperatureTable.build(f.meta!, f.profile!, s);

/// Smallest count whose cumulative share of [total] exceeds [q].
int percentile(Uint32List histogram, int total, double q) {
  final int target = (total * q).round();
  int acc = 0;
  for (int i = 0; i < histogram.length; i++) {
    acc += histogram[i];
    if (acc > target) return i;
  }
  return histogram.length - 1;
}

/// Mean count of the 3x3 neighbourhood around [at].
int spotCount(Uint16List counts, int w, int h, (int, int) at) {
  int sum = 0;
  int k = 0;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      final int x = (at.$1 + dx).clamp(0, w - 1);
      final int y = (at.$2 + dy).clamp(0, h - 1);
      sum += counts[y * w + x];
      k++;
    }
  }
  return sum ~/ k;
}
