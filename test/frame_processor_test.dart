// Pins the frame processing (statistics, colour scale, spot averaging,
// marker hysteresis) that used to live in ProbeController.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/probe/frame_processor.dart';
import 'package:t2s_thermal/t2s/flat_field.dart';
import 'package:t2s_thermal/t2s/shutter_correction.dart';
import 'package:t2s_thermal/t2s/t2s_frame.dart';
import 'package:t2s_thermal/t2s/temperature_model.dart';

import 't2s_fixture.dart';

/// Tiny1-C frame of w x h with the given linear counts (count / 20 - 40 °C).
T2sFrame tinyFrame(int w, int h, int Function(int x, int y) count) {
  final T2sFrame f = T2sFrame.decodeTiny1c(Uint8List(w * h * 4), w, h * 2)!;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      f.counts[y * w + x] = count(x, y);
    }
  }
  return f;
}

const ModelSettings v1 = ModelSettings(revision: HardwareRevision.v1);
const ScaleOptions autoScale = (
  fixedScale: false,
  fixedMin: 15,
  fixedMax: 40,
  minSpan: 10,
);

({Uint16List shown, bool byTemperature}) run(
  FrameProcessor p,
  T2sFrame f, {
  ModelSettings settings = v1,
  ShutterCorrection? correction,
  bool anchorToModel = true,
  FlatField? flatField,
  bool flatFieldEnabled = true,
  (int, int)? point,
  DisplaySource displaySource = DisplaySource.temperature,
  ScaleOptions scale = autoScale,
}) => p.process(
  f,
  settings: settings,
  correction: correction,
  anchorToModel: anchorToModel,
  flatField: flatField,
  flatFieldEnabled: flatFieldEnabled,
  point: point,
  displaySource: displaySource,
  scale: scale,
);

void main() {
  // 16x8 ramp: count 1200 + index, 20.00 °C .. 26.35 °C.
  T2sFrame ramp() => tinyFrame(16, 8, (int x, int y) => 1200 + y * 16 + x);

  group('statistics', () {
    test('min, max, mean, spread, centre and extremes', () {
      final FrameProcessor p = FrameProcessor();
      run(p, ramp());
      final FrameStats s = p.stats!;
      expect(s.minCount, 1200);
      expect(s.maxCount, 1327);
      expect(s.meanCount, 1263.5);
      // Uniform 0..127: sqrt((128^2 - 1) / 12).
      expect(s.stdDev, closeTo(36.9493, 1e-4));
      // 3x3 around (8, 4) averages to the middle pixel.
      expect(s.centerCount, 1272);
      expect(s.minTemp, closeTo(20.0, 1e-4));
      expect(s.maxTemp, closeTo(26.35, 1e-4));
      expect(s.centerTemp, closeTo(23.6, 1e-4));
      // Linear table: the other shutter source changes nothing.
      expect(s.centerTempAlt, s.centerTemp);
      expect(s.hottest, (15, 7));
      expect(s.coldest, (0, 0));
      expect(s.nanCount, 0);
      expect(s.pointCount, isNull);
      expect(s.pointTemp, isNull);
      expect(s.pointTempAlt, isNull);
      expect(p.table, isNotNull);
      expect(p.processedCounts, same(p.preFlatCounts));
    });

    test('measurement point averages 3x3, clamped at the edge', () {
      final FrameProcessor p = FrameProcessor();
      run(p, ramp(), point: (0, 0));
      // (0,0) x4, (1,0) x2, (0,1) x2, (1,1) x1: (0+2+32+17) ~/ 9 = 5.
      expect(p.stats!.pointCount, 1205);
      expect(p.stats!.pointTemp, closeTo(20.25, 1e-4));
      expect(p.stats!.pointTempAlt, p.stats!.pointTemp);
    });

    test('percentile picks the first count past the share', () {
      final Uint32List h = Uint32List(10)
        ..[2] = 1
        ..[5] = 98
        ..[7] = 1;
      expect(percentile(h, 100, 0.005), 5); // target 1: needs more than 1
      expect(percentile(h, 100, 0.99), 7);
      // Never exceeded: the last count. (100 * 0.995 rounds to 100.)
      expect(percentile(h, 100, 0.995), 9);
      expect(percentile(Uint32List(10), 100, 0.5), 9);
    });

    test('spot count is the integer mean of 3x3', () {
      final Uint16List c = Uint16List.fromList(<int>[
        1, 2, 3, //
        4, 5, 6, //
        7, 8, 10,
      ]);
      expect(spotCount(c, 3, 3, (1, 1)), 46 ~/ 9);
      expect(spotCount(c, 3, 3, (2, 2)), (5 + 6 * 2 + 8 * 2 + 10 * 4) ~/ 9);
    });
  });

  group('colour scale', () {
    test('robust range widened to the minimum span', () {
      final FrameProcessor p = FrameProcessor();
      final ({Uint16List shown, bool byTemperature}) r = run(p, ramp());
      // 0.5 % / 99.5 % percentiles: counts 1201 and 1327, 20.05..26.35 °C,
      // span 6.3 widened to 10 around the middle.
      expect(r.byTemperature, isTrue);
      expect(p.scaleLow, closeTo(18.2, 1e-4));
      expect(p.scaleHigh, closeTo(28.2, 1e-4));
      expect(p.stats!.scaleLow, p.scaleLow);
      expect(p.stats!.scaleHigh, p.scaleHigh);
    });

    test('robust range kept when wider than the minimum span', () {
      final FrameProcessor p = FrameProcessor();
      run(p, ramp(), scale: (
        fixedScale: false,
        fixedMin: 15,
        fixedMax: 40,
        minSpan: 2,
      ));
      expect(p.scaleLow, closeTo(20.05, 1e-4));
      expect(p.scaleHigh, closeTo(26.35, 1e-4));
    });

    test('fixed scale wins, unless its range is empty', () {
      final FrameProcessor p = FrameProcessor();
      run(p, ramp(), scale: (
        fixedScale: true,
        fixedMin: 15,
        fixedMax: 40,
        minSpan: 10,
      ));
      expect((p.scaleLow, p.scaleHigh), (15.0, 40.0));
      run(p, ramp(), scale: (
        fixedScale: true,
        fixedMin: 30,
        fixedMax: 30,
        minSpan: 10,
      ));
      expect(p.scaleLow, closeTo(18.2, 1e-4));
    });

    test('count display reports the scale in counts', () {
      final FrameProcessor p = FrameProcessor();
      final T2sFrame f = ramp();
      final ({Uint16List shown, bool byTemperature}) r = run(
        p,
        f,
        displaySource: DisplaySource.correctedCounts,
      );
      expect(r.byTemperature, isFalse);
      expect(p.stats!.scaleLow, 1201.0);
      expect(p.stats!.scaleHigh, 1327.0);
      // The °C scale is still computed.
      expect(p.scaleLow, closeTo(18.2, 1e-4));
    });

    test('raw display shows the uncorrected counts', () {
      final FlatField ff = FlatField.fromCoefficients(16, 8, <double>[
        for (int i = 0; i < 15; i++) i == 3 ? 50 : 0,
      ])!;
      final T2sFrame f = ramp();
      final FrameProcessor p = FrameProcessor();
      final ({Uint16List shown, bool byTemperature}) corrected = run(
        p,
        f,
        flatField: ff,
      );
      expect(corrected.shown, same(p.processedCounts));
      expect(p.processedCounts, isNot(equals(f.counts)));
      expect(p.preFlatCounts, same(f.counts));
      final ({Uint16List shown, bool byTemperature}) raw = run(
        p,
        f,
        flatField: ff,
        displaySource: DisplaySource.rawCounts,
      );
      expect(raw.shown, same(f.counts));
    });

    test('lens shading skipped when disabled or of another size', () {
      final FrameProcessor p = FrameProcessor();
      final T2sFrame f = ramp();
      List<double> coeffs() => <double>[
        for (int i = 0; i < 15; i++) i == 3 ? 50 : 0,
      ];
      run(p, f, flatField: FlatField.fromCoefficients(16, 8, coeffs()),
          flatFieldEnabled: false);
      expect(p.processedCounts, same(f.counts));
      run(p, f, flatField: FlatField.fromCoefficients(16, 4, coeffs()));
      expect(p.processedCounts, same(f.counts));
    });
  });

  group('hottest and coldest markers', () {
    // 20 °C background, hot spot A (2, 2) at 25 °C, cold spot (3, 6) at 15 °C.
    T2sFrame scene({int bCount = 0}) => tinyFrame(16, 8, (int x, int y) {
      if (x == 2 && y == 2) return 1300;
      if (x == 10 && y == 5 && bCount > 0) return bCount;
      if (x == 3 && y == 6) return 1100;
      return 1200;
    });

    test('first frame places them directly', () {
      final FrameProcessor p = FrameProcessor();
      run(p, scene());
      expect(p.hotMarker, (2.0, 2.0));
      expect(p.coldMarker, (3.0, 6.0));
    });

    test('a new extreme takes over only beyond the hysteresis', () {
      final FrameProcessor p = FrameProcessor();
      run(p, scene());
      // B is 0.15 °C hotter than A: below the 0.2 °C hysteresis.
      run(p, scene(bCount: 1303));
      expect(p.stats!.hottest, (10, 5));
      expect(p.hotMarker, (2.0, 2.0));
      // 0.25 °C hotter: B becomes the target, the marker glides 35 %.
      run(p, scene(bCount: 1305));
      expect(p.hotMarker!.$1, closeTo(2 + 8 * 0.35, 1e-9));
      expect(p.hotMarker!.$2, closeTo(2 + 3 * 0.35, 1e-9));
      run(p, scene(bCount: 1305));
      expect(p.hotMarker!.$1, closeTo(4.8 + 5.2 * 0.35, 1e-9));
      expect(p.hotMarker!.$2, closeTo(3.05 + 1.95 * 0.35, 1e-9));
      expect(p.coldMarker, (3.0, 6.0));
    });

    test('the target stays even after its spot cools down', () {
      final FrameProcessor p = FrameProcessor();
      run(p, scene());
      // A drops to background level; the hottest pixel is now the first
      // background pixel, which is not hotter than A's spot.
      run(p, tinyFrame(16, 8, (int x, int y) => 1200));
      expect(p.hotMarker, (2.0, 2.0));
      expect(p.coldMarker, (3.0, 6.0));
    });

    test('reset forgets markers and results, keeps the scale', () {
      final FrameProcessor p = FrameProcessor();
      run(p, scene());
      final double low = p.scaleLow;
      final Uint16List? preFlat = p.preFlatCounts;
      p.reset();
      expect(p.hotMarker, isNull);
      expect(p.coldMarker, isNull);
      expect(p.stats, isNull);
      expect(p.table, isNull);
      expect(p.processedCounts, isNull);
      expect(p.scaleLow, low);
      expect(p.preFlatCounts, same(preFlat));
      run(p, scene(bCount: 1301));
      expect(p.hotMarker, (10.0, 5.0));
    });
  });

  group('temperatures for readers', () {
    test('temperatureAt and temperatureGrid', () {
      final FrameProcessor p = FrameProcessor();
      final T2sFrame f = ramp();
      expect(p.temperatureAt(f, 0, 0), isNull);
      expect(p.temperatureGrid(), isNull);
      run(p, f);
      expect(p.temperatureAt(null, 0, 0), isNull);
      expect(p.temperatureAt(f, 0, 0), closeTo(20.25, 1e-4));
      final Int16List grid = p.temperatureGrid()!;
      expect(grid.length, 128);
      expect(grid[0], 1000); // 20.00 °C in 1/50 °C
      expect(grid[127], 1318); // 26.35 °C
    });
  });

  group('Xtherm frames', () {
    T2sFrame xtherm() =>
        T2sFrame.decode(buildFrame(shutterRaw: 3100, fpaRaw: 8700), 256, 196)!;
    const ModelSettings v2 = ModelSettings(revision: HardwareRevision.v2);

    test('other shutter source gives the comparison values', () {
      final FrameProcessor p = FrameProcessor();
      final T2sFrame f = xtherm();
      run(p, f, settings: v2, point: (5, 5));
      final TemperatureTable alt = TemperatureTable.build(
        f.meta!,
        f.profile!,
        v2.copyWith(shutterSource: ShutterSource.fpa), // default: register
      );
      expect(p.stats!.centerTempAlt, alt.lookup(p.stats!.centerCount));
      expect(p.stats!.pointTempAlt, alt.lookup(p.stats!.pointCount!));
      expect(
        p.stats!.centerTemp,
        tableFor(f, v2).lookup(p.stats!.centerCount),
      );
    });

    test('V2 shutter reference anchored at the model or reference mean', () {
      final T2sFrame f = xtherm();
      final Uint16List ref = Uint16List(f.counts.length);
      for (int i = 0; i < ref.length; i++) {
        ref[i] = 8900 + (i % 3) * 10;
      }
      final ShutterCorrection c = ShutterCorrection.fromFrames(
        <Uint16List>[ref],
        f.width,
        f.height,
      );
      final FrameProcessor p = FrameProcessor();
      run(p, f, settings: v2, correction: c);
      final double level = p.table!.shutterLevel;
      expect(p.processedCounts, c.apply(f.counts, level: level));
      run(p, f, settings: v2, correction: c, anchorToModel: false);
      expect(p.processedCounts, c.apply(f.counts));
      // V1 cameras correct themselves: the reference is ignored.
      run(p, f, settings: v2.copyWith(revision: HardwareRevision.v1),
          correction: c);
      expect(p.processedCounts, same(f.counts));
    });
  });
}
