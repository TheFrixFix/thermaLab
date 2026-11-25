import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../render/palette.dart';
import '../render/scene_layout.dart';
import '../t2s/temperature_unit.dart';
import 'frame_processor.dart';

/// Display settings (how the picture and its overlays look) and their
/// preferences. Shared by the settings page, the edit panel and the web
/// remote through [apply].
class ViewSettings {
  ViewSettings({required this.notify, required this.setAutoShutter});

  /// Tells listeners that a setting changed.
  final void Function() notify;

  /// `autoShutter` is listed with the display settings for the web remote
  /// but belongs to the shutter control.
  final Future<void> Function(bool value) setAutoShutter;

  DisplaySource displaySource = DisplaySource.temperature;
  Palette palette = Palette.iron;

  /// Clockwise quarter turns applied to the displayed image.
  int quarterTurns = 1;

  /// Smallest temperature span the colour scale is stretched over, so a
  /// uniform scene does not turn into colourful sensor noise.
  double minSpan = 10.0;

  /// Fixed colour scale instead of following the scene.
  bool fixedScale = false;
  double fixedMin = 15;
  double fixedMax = 40;

  /// Which overlay elements are shown and where clock and scale sit.
  SceneLayout layout = const SceneLayout();

  /// Clockwise quarter turns of the whole display (image, scale, clock and
  /// markers together) on the phone screen, for portrait or landscape use.
  /// Photos, videos and the stream keep the reading orientation.
  int viewTurns = 0;

  /// Outline around marker labels: 0 shadow only, 1 normal, 2 thick.
  int labelOutline = 1;

  /// Look of the colour bar and, for the simple one, where its unit sits.
  ScaleStyle scaleStyle = ScaleStyle.detailed;
  ScaleUnit scaleUnit = ScaleUnit.side;

  /// Unit temperatures are shown and exported in. Settings stay in °C.
  TemperatureUnit temperatureUnit = TemperatureUnit.celsius;

  /// Apply the lens shading correction, if one was measured.
  bool flatFieldEnabled = true;

  /// Flip the thermal image horizontally (after rotation).
  bool mirror = false;

  ScaleOptions get scale => (
    fixedScale: fixedScale,
    fixedMin: fixedMin,
    fixedMax: fixedMax,
    minSpan: minSpan,
  );

  /// Reads the saved settings; the caller notifies.
  void load(SharedPreferences prefs) {
    quarterTurns = prefs.getInt('quarterTurns') ?? 1;
    minSpan = prefs.getDouble('minSpan') ?? 10.0;
    fixedScale = prefs.getBool('fixedScale') ?? false;
    fixedMin = prefs.getDouble('fixedMin') ?? 15;
    fixedMax = prefs.getDouble('fixedMax') ?? 40;
    final String? layoutJson = prefs.getString('layout');
    final int? oldCorner = prefs.getInt('timestampCorner');
    layout = layoutJson != null
        ? SceneLayout.fromJson(jsonDecode(layoutJson) as Map<String, dynamic>)
        : (oldCorner != null
              ? SceneLayout.fromTimestampCorner(oldCorner)
              : const SceneLayout());
    labelOutline = prefs.getInt('labelOutline') ?? 1;
    scaleStyle = enumByName(
      ScaleStyle.values,
      prefs.getString('scaleStyle'),
      ScaleStyle.detailed,
    );
    scaleUnit = enumByName(
      ScaleUnit.values,
      prefs.getString('scaleUnit'),
      ScaleUnit.side,
    );
    temperatureUnit = enumByName(
      TemperatureUnit.values,
      prefs.getString('temperatureUnit'),
      TemperatureUnit.celsius,
    );
    mirror = prefs.getBool('mirror') ?? false;
    viewTurns = prefs.getInt('viewTurns') ?? 0;
    flatFieldEnabled = prefs.getBool('flatFieldEnabled') ?? true;
    final String? paletteName = prefs.getString('palette');
    palette = Palette.all.firstWhere(
      (Palette p) => p.name == paletteName,
      orElse: () => Palette.iron,
    );
  }

  /// Display settings shared with the web remote.
  Map<String, Object> toMap({
    required bool autoShutter,
    required bool flatFieldCalibrated,
  }) => <String, Object>{
    'palette': palette.name,
    'quarterTurns': quarterTurns,
    'minSpan': minSpan,
    'fixedScale': fixedScale,
    'fixedMin': fixedMin,
    'fixedMax': fixedMax,
    'layout': layout.toJson(),
    'labelOutline': labelOutline,
    'scaleStyle': scaleStyle.name,
    'scaleUnit': scaleUnit.name,
    'temperatureUnit': temperatureUnit.name,
    'autoShutter': autoShutter,
    'mirror': mirror,
    'flatField': flatFieldEnabled,
    'flatFieldCalibrated': flatFieldCalibrated,
  };

  /// Applies one display setting by name (from the settings page or the
  /// web remote) and persists it. Unknown keys are ignored.
  Future<void> apply(String key, Object? value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    double? asDouble() => value is num ? value.toDouble() : null;
    int? asInt() => value is num ? value.round() : null;
    switch (key) {
      case 'palette':
        final Palette? p = Palette.all
            .where((Palette p) => p.name == value)
            .firstOrNull;
        if (p != null) await setPalette(p);
        return;
      case 'quarterTurns':
        final int? v = asInt();
        if (v == null) return;
        quarterTurns = v % 4;
        await prefs.setInt('quarterTurns', quarterTurns);
      case 'minSpan':
        final double? v = asDouble();
        if (v == null) return;
        minSpan = v.clamp(0, 50).toDouble();
        await prefs.setDouble('minSpan', minSpan);
      case 'fixedScale':
        if (value is! bool) return;
        fixedScale = value;
        await prefs.setBool('fixedScale', value);
      case 'fixedMin':
        final double? v = asDouble();
        if (v == null) return;
        fixedMin = v;
        await prefs.setDouble('fixedMin', v);
      case 'fixedMax':
        final double? v = asDouble();
        if (v == null) return;
        fixedMax = v;
        await prefs.setDouble('fixedMax', v);
      case 'layout':
        if (value is! Map) return;
        await setLayout(
          SceneLayout.fromJson(Map<String, dynamic>.from(value), layout),
        );
        return;
      case 'labelOutline':
        final int? v = asInt();
        if (v == null) return;
        labelOutline = v.clamp(0, 2);
        await prefs.setInt('labelOutline', labelOutline);
      case 'scaleStyle':
        scaleStyle = enumByName(ScaleStyle.values, value, scaleStyle);
        await prefs.setString('scaleStyle', scaleStyle.name);
      case 'scaleUnit':
        scaleUnit = enumByName(ScaleUnit.values, value, scaleUnit);
        await prefs.setString('scaleUnit', scaleUnit.name);
      case 'temperatureUnit':
        temperatureUnit = enumByName(
          TemperatureUnit.values,
          value,
          temperatureUnit,
        );
        await prefs.setString('temperatureUnit', temperatureUnit.name);
      case 'autoShutter':
        if (value is bool) await setAutoShutter(value);
        return;
      case 'flatField':
        if (value is! bool) return;
        flatFieldEnabled = value;
        await prefs.setBool('flatFieldEnabled', value);
      case 'viewTurns':
        final int? v = asInt();
        if (v == null) return;
        viewTurns = v % 4;
        await prefs.setInt('viewTurns', viewTurns);
      case 'mirror':
        if (value is! bool) return;
        mirror = value;
        await prefs.setBool('mirror', value);
      default:
        return;
    }
    notify();
  }

  /// Changes the overlay layout; [persist] false while dragging.
  Future<void> setLayout(SceneLayout value, {bool persist = true}) async {
    layout = value;
    notify();
    if (!persist) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('layout', jsonEncode(value.toJson()));
  }

  Future<void> setMinSpan(double value) async {
    minSpan = value;
    notify();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('minSpan', value);
  }

  void setDisplaySource(DisplaySource source) {
    displaySource = source;
    notify();
  }

  Future<void> setPalette(Palette p) async {
    palette = p;
    notify();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('palette', p.name);
  }

  Future<void> rotate() async {
    quarterTurns = (quarterTurns + 1) % 4;
    notify();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('quarterTurns', quarterTurns);
  }
}
