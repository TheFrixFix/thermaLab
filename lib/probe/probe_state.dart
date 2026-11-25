import 'package:flutter/foundation.dart';

import '../t2s/temperature_model.dart';

/// State that the camera connection, shutter control and calibration all
/// read and change, plus the diagnostics log. [ProbeController] owns one
/// and hands it to each part, so the parts do not depend on the controller.
class ProbeState {
  ProbeState({required this.notify});

  /// Tells the controller's listeners that something changed.
  final void Function() notify;

  // Wall measurements (2026-11-06): with the closed shutter anchored at the
  // model level, taking the shutter temperature from the sensor reads about
  // 5 °C above the shutter register, matching the vendor app.
  ModelSettings settings = const ModelSettings(
    revision: HardwareRevision.v2,
    shutterSource: ShutterSource.fpa,
  );

  /// A long operation (connecting, shutter correction, measuring) runs.
  bool busy = false;
  String status = 'Not connected';

  final List<String> logLines = <String>[];

  void log(String message) {
    final DateTime now = DateTime.now();
    final String ts =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    logLines.add('$ts $message');
    if (logLines.length > 300) logLines.removeAt(0);
    debugPrint('[probe] $message');
    notify();
  }
}
