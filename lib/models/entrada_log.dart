class EntradaLog {
  final int? id;
  final String vehicle;
  final int durationSeconds;
  final String timestamp;
  final String summary;
  final String status;
  final String? sourceDevice;

  const EntradaLog({
    this.id,
    required this.vehicle,
    required this.durationSeconds,
    required this.timestamp,
    required this.summary,
    this.status = completedStatus,
    this.sourceDevice,
  });

  static const recordingStatus = 'recording';
  static const completedStatus = 'completed';
  static const interruptedStatus = 'interrupted';

  factory EntradaLog.fromMap(Map<String, Object?> map) {
    final id = map['id'];
    final vehicle = map['vehicle'];
    final durationSeconds = map['duration_seconds'];
    final timestamp = map['timestamp'];
    final summary = map['summary'];
    final status = map['status'] ?? completedStatus;
    final sourceDevice = map['source_device'];

    if (id is! int ||
        vehicle is! String ||
        durationSeconds is! int ||
        timestamp is! String ||
        summary is! String ||
        status is! String ||
        (sourceDevice != null && sourceDevice is! String)) {
      throw const FormatException('Formato de log inválido no banco de dados.');
    }

    return EntradaLog(
      id: id,
      vehicle: vehicle,
      durationSeconds: durationSeconds,
      timestamp: timestamp,
      summary: summary,
      status: status,
      sourceDevice: sourceDevice is String ? sourceDevice : null,
    );
  }

  factory EntradaLog.fromLegacyJson(Map<String, dynamic> json) {
    final vehicle = json['vehicle'];
    final durationSeconds = json['durationSeconds'];
    final timestamp = json['timestamp'];
    final summary = json['summary'];

    if (vehicle is! String ||
        durationSeconds is! int ||
        timestamp is! String ||
        summary is! String) {
      throw const FormatException('Formato de log salvo anteriormente inválido.');
    }

    return EntradaLog(
      vehicle: vehicle,
      durationSeconds: durationSeconds,
      timestamp: timestamp,
      summary: summary,
    );
  }

  Map<String, Object?> toMap() => {
        'vehicle': vehicle,
        'duration_seconds': durationSeconds,
        'timestamp': timestamp,
        'summary': summary,
        'status': status,
        'source_device': sourceDevice,
      };

  EntradaLog copyWith({
    int? id,
    String? vehicle,
    int? durationSeconds,
    String? timestamp,
    String? summary,
    String? status,
    String? sourceDevice,
  }) {
    return EntradaLog(
      id: id ?? this.id,
      vehicle: vehicle ?? this.vehicle,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      timestamp: timestamp ?? this.timestamp,
      summary: summary ?? this.summary,
      status: status ?? this.status,
      sourceDevice: sourceDevice ?? this.sourceDevice,
    );
  }
}
