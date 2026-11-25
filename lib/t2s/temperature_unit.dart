/// Unit temperatures are shown and exported in.
///
/// Everything inside the app (models, statistics, settings, the stream's
/// wire format) stays in °C; values are converted only where people read
/// or export them.
enum TemperatureUnit {
  celsius('°C', 'C', 'degrees Celsius'),
  fahrenheit('°F', 'F', 'degrees Fahrenheit'),
  kelvin('K', 'K', 'kelvin');

  const TemperatureUnit(this.symbol, this.letter, this.longName);

  /// Unit sign shown next to values, e.g. on the colour bar.
  final String symbol;

  /// Plain letter for column names and file names.
  final String letter;

  /// Spelled out, for the CSV comment line.
  final String longName;

  /// Converts an absolute temperature from °C.
  double fromCelsius(double c) => switch (this) {
    celsius => c,
    fahrenheit => c * 9 / 5 + 32,
    kelvin => c + 273.15,
  };

  /// Converts an absolute temperature in this unit to °C.
  double toCelsius(double v) => switch (this) {
    celsius => v,
    fahrenheit => (v - 32) * 5 / 9,
    kelvin => v - 273.15,
  };

  /// Converts a temperature difference from °C (no offset).
  double spanFromCelsius(double c) => this == fahrenheit ? c * 9 / 5 : c;

  /// Converts a temperature difference in this unit to °C.
  double spanToCelsius(double v) => this == fahrenheit ? v * 5 / 9 : v;

  /// Short mark after a marker value: a bare degree sign for °C and °F,
  /// as the colour bar names the scale, and " K" for kelvin.
  String get markSuffix => this == kelvin ? ' K' : '°';

  /// [c] (in °C) converted and written with [digits] decimals and the unit
  /// symbol, e.g. "71.6 °F".
  String format(double c, {int digits = 1}) =>
      '${fromCelsius(c).toStringAsFixed(digits)} $symbol';

  /// Same as [format] for a temperature difference.
  String formatSpan(double c, {int digits = 1}) =>
      '${spanFromCelsius(c).toStringAsFixed(digits)} $symbol';
}
