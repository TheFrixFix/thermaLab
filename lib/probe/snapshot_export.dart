import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../t2s/t2s_frame.dart';
import '../t2s/temperature_model.dart';
import 'probe_controller.dart';

/// Writes the current raw frame plus a JSON report and opens the share
/// sheet, so the data can be analysed elsewhere.
Future<void> exportDiagnostics(ProbeController c) async {
  final T2sFrame? f = c.frame;
  if (f == null) {
    c.log('Nothing to export yet');
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
    if (c.correction != null) {
      final File ref = File('${dir.path}/t2s_shutter_reference_$stamp.f32');
      await ref.writeAsBytes(c.correction!.reference.buffer.asUint8List());
      files.add(ref);
    }

    final TemperatureTable? t = c.table;
    final FrameStats? s = c.stats;
    final Map<String, Object?> report = <String, Object?>{
      'app': 'thermaLab diagnostics',
      'timestamp': DateTime.now().toIso8601String(),
      'device': c.device == null
          ? null
          : <String, Object?>{
              'usbId': usbId(c.device!.vendorId, c.device!.productId),
              'manufacturer': c.device!.manufacturerName,
              'product': c.device!.productName,
              'serial': c.device!.serialNumber,
            },
      'modes': c.modes.map((UvcCameraMode m) => m.label).toList(),
      'mode': c.mode?.label,
      'frame': <String, Object?>{
        'width': f.width,
        'imageHeight': f.height,
        'bytes': f.rawBytes.length,
        'fps': c.fps,
        'framesReceived': c.framesReceived,
        'undecodableFrames': c.undecodableFrames,
      },
      'settings': <String, Object?>{
        'revision': c.settings.revision.name,
        'range': c.settings.range.name,
        'shutterOffset': c.settings.shutterOffset,
        'userOffset': c.settings.userOffset,
        'shutterCorrection': c.correction != null,
        'deadPixels': c.correction?.deadPixels.length,
      },
      'family': c.family.name,
      'camera': c.cameraName,
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
              'point': c.point == null ? null : <int>[c.point!.$1, c.point!.$2],
              'pointTemp': s.pointTemp,
              'pointTempAlt': s.pointTempAlt,
            },
      'log': c.logLines,
    };
    final File json = File('${dir.path}/t2s_report_$stamp.json');
    await json.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    files.add(json);

    final ui.Image? img = c.image;
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
    c.log('Exported ${files.length} files');
  } catch (e) {
    c.log('Export failed: $e');
  }
}
