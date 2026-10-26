class FrameCan {
  final int? id;
  final int logId;
  final DateTime capturedAt;
  final int canId;
  final bool extended;
  final bool remoteRequest;
  final int dlc;
  final String dataHex;
  final int? deviceTimestampMs;
  final String rawPayload;

  const FrameCan({
    this.id,
    required this.logId,
    required this.capturedAt,
    required this.canId,
    required this.extended,
    required this.remoteRequest,
    required this.dlc,
    required this.dataHex,
    this.deviceTimestampMs,
    required this.rawPayload,
  });

  factory FrameCan.fromJson({
    required int logId,
    required DateTime capturedAt,
    required Map<String, dynamic> json,
    required String rawPayload,
  }) {
    final canId = json['id'];
    final extended = json['extended'];
    final remoteRequest = json['rtr'];
    final dlc = json['dlc'];
    final dataHex = json['data'];
    final deviceTimestampMs = json['timestampMs'];

    if (canId is! int ||
        canId < 0 ||
        extended is! bool ||
        remoteRequest is! bool ||
        dlc is! int ||
        dlc < 0 ||
        dlc > 8 ||
        dataHex is! String ||
        (remoteRequest ? dataHex.isNotEmpty : dataHex.length != dlc * 2) ||
        !RegExp(r'^[0-9A-Fa-f]*$').hasMatch(dataHex) ||
        (deviceTimestampMs != null && deviceTimestampMs is! int)) {
      throw const FormatException('Frame CAN inválido ou incompleto.');
    }

    final maxId = extended ? 0x1FFFFFFF : 0x7FF;
    if (canId > maxId) {
      throw const FormatException('Identificador CAN fora do intervalo.');
    }

    return FrameCan(
      logId: logId,
      capturedAt: capturedAt,
      canId: canId,
      extended: extended,
      remoteRequest: remoteRequest,
      dlc: dlc,
      dataHex: dataHex.toUpperCase(),
      deviceTimestampMs: deviceTimestampMs is int ? deviceTimestampMs : null,
      rawPayload: rawPayload,
    );
  }

  factory FrameCan.fromMap(Map<String, Object?> map) {
    final id = map['id'];
    final logId = map['log_id'];
    final capturedAt = map['captured_at'];
    final canId = map['can_id'];
    final extended = map['extended'];
    final remoteRequest = map['remote_request'];
    final dlc = map['dlc'];
    final dataHex = map['data_hex'];
    final deviceTimestampMs = map['device_timestamp_ms'];
    final rawPayload = map['raw_payload'];

    if (id is! int ||
        logId is! int ||
        capturedAt is! String ||
        canId is! int ||
        extended is! int ||
        remoteRequest is! int ||
        dlc is! int ||
        dataHex is! String ||
        (deviceTimestampMs != null && deviceTimestampMs is! int) ||
        rawPayload is! String) {
      throw const FormatException('Frame CAN inválido no banco de dados.');
    }

    return FrameCan(
      id: id,
      logId: logId,
      capturedAt: DateTime.parse(capturedAt),
      canId: canId,
      extended: extended != 0,
      remoteRequest: remoteRequest != 0,
      dlc: dlc,
      dataHex: dataHex,
      deviceTimestampMs: deviceTimestampMs is int ? deviceTimestampMs : null,
      rawPayload: rawPayload,
    );
  }

  Map<String, Object?> toMap() => {
        'log_id': logId,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'can_id': canId,
        'extended': extended ? 1 : 0,
        'remote_request': remoteRequest ? 1 : 0,
        'dlc': dlc,
        'data_hex': dataHex,
        'device_timestamp_ms': deviceTimestampMs,
        'raw_payload': rawPayload,
      };

  String get formattedCanId =>
      '0x${canId.toRadixString(16).toUpperCase().padLeft(extended ? 8 : 3, '0')}';
}
