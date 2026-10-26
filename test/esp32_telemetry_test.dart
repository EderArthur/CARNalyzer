import 'package:carnalyzer/main.dart';
import 'package:carnalyzer/models/esp32_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses telemetry fields sent by the ESP32', () {
    final telemetry = Esp32Telemetry.fromJson({
      'speedKmh': 42,
      'rpm': 1850,
      'odometerKm': 14285.5,
      'coolantTempC': 91,
      'batteryVoltage': 14.1,
    });

    expect(telemetry.speedKmh, 42);
    expect(telemetry.rpm, 1850);
    expect(telemetry.odometerKm, 14285.5);
    expect(telemetry.coolantTempC, 91);
    expect(telemetry.batteryVoltage, 14.1);
  });

  test('rejects missing or non-numeric telemetry fields', () {
    expect(
      () => Esp32Telemetry.fromJson({'speedKmh': '42'}),
      throwsFormatException,
    );
  });

  testWidgets('telemetry screen displays the received ESP32 gauge values', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PaginaTelemetria(
          connected: true,
          brand: 'Fastback',
          model: 'Impétus',
          year: '2026',
          isDarkMode: true,
          telemetry: const Esp32Telemetry(
            speedKmh: 42,
            rpm: 1850,
            odometerKm: 14285,
            coolantTempC: 91,
            batteryVoltage: 14.1,
          ),
          onOpenLogs: () {},
          onLogRecorded: (_) {},
        ),
      ),
    );

    expect(find.text('42'), findsOneWidget);
    expect(find.text('1850'), findsOneWidget);
    expect(find.text('BLE OK'), findsOneWidget);
  });
}
