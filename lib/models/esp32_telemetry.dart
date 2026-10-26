class Esp32Telemetry {
  final double speedKmh;
  final double rpm;
  final double odometerKm;
  final double coolantTempC;
  final double batteryVoltage;

  const Esp32Telemetry({
    required this.speedKmh,
    required this.rpm,
    required this.odometerKm,
    required this.coolantTempC,
    required this.batteryVoltage,
  });

  factory Esp32Telemetry.fromJson(Map<String, dynamic> json) {
    return Esp32Telemetry(
      speedKmh: _readNumber(json, 'speedKmh'),
      rpm: _readNumber(json, 'rpm'),
      odometerKm: _readNumber(json, 'odometerKm'),
      coolantTempC: _readNumber(json, 'coolantTempC'),
      batteryVoltage: _readNumber(json, 'batteryVoltage'),
    );
  }

  static double _readNumber(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is num) return value.toDouble();
    throw FormatException('Campo de telemetria inválido ou ausente: $key');
  }
}
