class FrameTelemetria {
  final int? id;
  final int logId;
  final DateTime capturedAt;
  final double speedKmh;
  final double rpm;
  final double odometerKm;
  final double coolantTempC;
  final double batteryVoltage;
  final String rawPayload;

  const FrameTelemetria({
    this.id,
    required this.logId,
    required this.capturedAt,
    required this.speedKmh,
    required this.rpm,
    required this.odometerKm,
    required this.coolantTempC,
    required this.batteryVoltage,
    required this.rawPayload,
  });

  factory FrameTelemetria.fromMap(Map<String, Object?> map) {
    final id = map['id'];
    final logId = map['log_id'];
    final capturedAt = map['captured_at'];
    final speedKmh = map['speed_kmh'];
    final rpm = map['rpm'];
    final odometerKm = map['odometer_km'];
    final coolantTempC = map['coolant_temp_c'];
    final batteryVoltage = map['battery_voltage'];
    final rawPayload = map['raw_payload'];

    if (id is! int ||
        logId is! int ||
        capturedAt is! String ||
        speedKmh is! num ||
        rpm is! num ||
        odometerKm is! num ||
        coolantTempC is! num ||
        batteryVoltage is! num ||
        rawPayload is! String) {
      throw const FormatException(
        'Formato de frame de telemetria inválido no banco de dados.',
      );
    }

    return FrameTelemetria(
      id: id,
      logId: logId,
      capturedAt: DateTime.parse(capturedAt),
      speedKmh: speedKmh.toDouble(),
      rpm: rpm.toDouble(),
      odometerKm: odometerKm.toDouble(),
      coolantTempC: coolantTempC.toDouble(),
      batteryVoltage: batteryVoltage.toDouble(),
      rawPayload: rawPayload,
    );
  }

  Map<String, Object> toMap() => {
        'log_id': logId,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'speed_kmh': speedKmh,
        'rpm': rpm,
        'odometer_km': odometerKm,
        'coolant_temp_c': coolantTempC,
        'battery_voltage': batteryVoltage,
        'raw_payload': rawPayload,
      };
}
