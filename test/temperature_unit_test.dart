import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/t2s/temperature_unit.dart';

void main() {
  test('converts absolute temperatures from and to Celsius', () {
    expect(TemperatureUnit.celsius.fromCelsius(21.5), 21.5);
    expect(TemperatureUnit.fahrenheit.fromCelsius(100), closeTo(212, 1e-9));
    expect(TemperatureUnit.fahrenheit.fromCelsius(-40), closeTo(-40, 1e-9));
    expect(TemperatureUnit.kelvin.fromCelsius(0), closeTo(273.15, 1e-9));
    for (final TemperatureUnit u in TemperatureUnit.values) {
      for (final double c in <double>[-20, 0, 36.6, 450]) {
        expect(u.toCelsius(u.fromCelsius(c)), closeTo(c, 1e-9));
      }
    }
  });

  test('converts spans without the offset', () {
    expect(TemperatureUnit.fahrenheit.spanFromCelsius(10), closeTo(18, 1e-9));
    expect(TemperatureUnit.kelvin.spanFromCelsius(10), 10);
    expect(TemperatureUnit.fahrenheit.spanToCelsius(18), closeTo(10, 1e-9));
  });

  test('formats with the unit symbol', () {
    expect(TemperatureUnit.celsius.format(22), '22.0 °C');
    expect(TemperatureUnit.fahrenheit.format(22), '71.6 °F');
    expect(TemperatureUnit.kelvin.format(22), '295.1 K');
    expect(TemperatureUnit.fahrenheit.formatSpan(10, digits: 0), '18 °F');
  });
}
