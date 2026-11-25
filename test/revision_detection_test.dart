// Pins how an Xtherm camera of unknown revision is judged from a frame.

import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/probe/shutter_control.dart';
import 'package:t2s_thermal/t2s/t2s_frame.dart';
import 'package:t2s_thermal/t2s/temperature_model.dart';

import 't2s_fixture.dart';

/// 256x192 fixture frame with counts from [count].
T2sFrame frame(int Function(int x, int y) count) {
  final T2sFrame f = T2sFrame.decode(buildFrame(), 256, 196)!;
  for (int y = 0; y < f.height; y++) {
    for (int x = 0; x < f.width; x++) {
      f.counts[y * f.width + x] = count(x, y);
    }
  }
  return f;
}

void main() {
  test('a uniform frame has no pixel noise: V1', () {
    final double noise = pixelNoise(frame((int x, int y) => 9000));
    expect(noise, 0);
    expect(revisionFromNoise(noise), HardwareRevision.v1);
  });

  test('column stripes: V2', () {
    final double noise = pixelNoise(
      frame((int x, int y) => 9000 + (x.isOdd ? 100 : 0)),
    );
    expect(noise, 100);
    expect(revisionFromNoise(noise), HardwareRevision.v2);
  });

  test('the threshold is exclusive', () {
    expect(
      pixelNoise(frame((int x, int y) => 9000 + (x.isOdd ? 40 : 0))),
      40,
    );
    expect(revisionFromNoise(40), HardwareRevision.v1);
    expect(revisionFromNoise(40.01), HardwareRevision.v2);
  });

  test('only every second row counts, starting at the first', () {
    // Wild odd rows, calm even rows.
    expect(
      pixelNoise(frame((int x, int y) => 9000 + (y.isOdd && x.isOdd ? 500 : 0))),
      0,
    );
    // A gradient along x: neighbours differ by 1 everywhere.
    expect(pixelNoise(frame((int x, int y) => 8000 + x)), 1);
  });
}
