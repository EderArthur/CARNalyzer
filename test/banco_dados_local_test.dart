import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:carnalyzer/data/banco_dados_local.dart';
import 'package:carnalyzer/models/frame_can.dart';
import 'package:carnalyzer/models/entrada_log.dart';
import 'package:carnalyzer/models/frame_telemetria.dart';

void main() {
  late BancoDadosLocal database;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    database = await BancoDadosLocal.abrir(caminho: inMemoryDatabasePath);
  });

  tearDown(() async {
    await database.fechar();
  });

  test('creates, lists, updates and deletes logs', () async {
    final created = await database.criarLog(
      const EntradaLog(
        vehicle: 'Fastback Impétus',
        durationSeconds: 42,
        timestamp: '2026-10-25 18:00',
        summary: 'Sessão gravada com OBD-II ativo',
      ),
    );

    expect(created.id, isNotNull);
    var logs = await database.listarLogs();
    expect(logs, hasLength(1));
    expect(logs.single.id, created.id);
    expect(logs.single.vehicle, created.vehicle);
    expect(logs.single.durationSeconds, created.durationSeconds);

    final updated = created.copyWith(
      vehicle: 'Toro Limited',
      durationSeconds: 60,
      summary: 'Resumo atualizado',
    );
    await database.atualizarLog(updated);
    logs = await database.listarLogs();
    expect(logs, hasLength(1));
    expect(logs.single.vehicle, updated.vehicle);
    expect(logs.single.durationSeconds, updated.durationSeconds);
    expect(logs.single.summary, updated.summary);

    await database.excluirLog(created.id!);
    expect(await database.listarLogs(), isEmpty);
  });

  test('imports existing SharedPreferences logs once', () async {
    const legacyJson = '''
      [
        {
          "vehicle": "Pulse Audace",
          "durationSeconds": 15,
          "timestamp": "2026-10-25 17:00",
          "summary": "Sessão antiga"
        }
      ]
    ''';

    await database.importarLogsLegados(legacyJson);
    await database.importarLogsLegados(legacyJson);

    final logs = await database.listarLogs();
    expect(logs, hasLength(1));
    expect(logs.single.vehicle, 'Pulse Audace');
    expect(logs.single.summary, 'Sessão antiga');
  });

  test('stores telemetry frames with their recording and deletes them with it',
      () async {
    final recording = await database.iniciarLog(
      const EntradaLog(
        vehicle: 'Fastback Impétus 2026',
        durationSeconds: 0,
        timestamp: '2026-10-25 18:00',
        summary: 'Gravação em andamento',
        status: EntradaLog.recordingStatus,
        sourceDevice: 'CARNalyzer-ESP32',
      ),
    );

    final frame = FrameTelemetria(
      logId: recording.id!,
      capturedAt: DateTime.utc(2026, 10, 25, 21),
      speedKmh: 42,
      rpm: 1850,
      odometerKm: 14285.5,
      coolantTempC: 91,
      batteryVoltage: 14.1,
      rawPayload:
          '{"speedKmh":42,"rpm":1850,"odometerKm":14285.5,'
          '"coolantTempC":91,"batteryVoltage":14.1}',
    );
    await database.salvarFrame(frame);

    final frames = await database.listarFrames(recording.id!);
    expect(frames, hasLength(1));
    expect(frames.single.speedKmh, 42);
    expect(frames.single.rawPayload, contains('"rpm":1850'));
    expect(frames.single.logId, recording.id);

    await database.finalizarLog(
      id: recording.id!,
      durationSeconds: 1,
      summary: 'Sessão gravada com telemetria BLE ativa',
    );
    final logs = await database.listarLogs();
    expect(logs.single.status, EntradaLog.completedStatus);
    expect(logs.single.sourceDevice, 'CARNalyzer-ESP32');
    expect(logs.single.durationSeconds, 1);

    await database.excluirLog(recording.id!);
    expect(await database.listarFrames(recording.id!), isEmpty);
  });

  test('stores CAN frames with their CAN id, DLC and payload', () async {
    final recording = await database.iniciarLog(
      const EntradaLog(
        vehicle: 'Fastback Impétus 2026',
        durationSeconds: 0,
        timestamp: '2026-10-25 18:00',
        summary: 'Gravação em andamento',
        status: EntradaLog.recordingStatus,
      ),
    );
    final frame = FrameCan.fromJson(
      logId: recording.id!,
      capturedAt: DateTime.utc(2026, 10, 25, 21),
      json: {
        'type': 'can_frame',
        'timestampMs': 12000,
        'id': 291,
        'extended': false,
        'rtr': false,
        'dlc': 3,
        'data': '021001',
      },
      rawPayload:
          '{"type":"can_frame","timestampMs":12000,"id":291,'
          '"extended":false,"rtr":false,"dlc":3,"data":"021001"}',
    );

    await database.salvarFrameCan(frame);

    final storedFrames = await database.listarFramesCan(recording.id!);
    expect(storedFrames, hasLength(1));
    expect(storedFrames.single.formattedCanId, '0x123');
    expect(storedFrames.single.dlc, 3);
    expect(storedFrames.single.dataHex, '021001');
    expect(storedFrames.single.deviceTimestampMs, 12000);

    await database.excluirLog(recording.id!);
    expect(await database.listarFramesCan(recording.id!), isEmpty);
  });

  test('marks unfinished recordings as interrupted after app restart',
      () async {
    final recording = await database.iniciarLog(
      const EntradaLog(
        vehicle: 'Pulse Audace 2025',
        durationSeconds: 0,
        timestamp: '2026-10-25 18:00',
        summary: 'Gravação em andamento',
        status: EntradaLog.recordingStatus,
      ),
    );

    await database.marcarGravacoesInterrompidas();

    final logs = await database.listarLogs();
    expect(logs.single.id, recording.id);
    expect(logs.single.status, EntradaLog.interruptedStatus);
    expect(logs.single.summary, contains('interrompida'));
  });

  test('upgrades existing version 1 databases and preserves old sessions',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('carnalyzer-db-migration-');
    final path = '${directory.path}${Platform.pathSeparator}legacy.db';
    final legacyDatabase = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              vehicle TEXT NOT NULL,
              duration_seconds INTEGER NOT NULL,
              timestamp TEXT NOT NULL,
              summary TEXT NOT NULL
            )
          ''');
          await db.insert('logs', {
            'vehicle': 'Fastback Impétus',
            'duration_seconds': 45,
            'timestamp': '2026-10-25 18:00',
            'summary': 'Histórico antigo',
          });
        },
      ),
    );
    await legacyDatabase.close();

    final migratedDatabase = await BancoDadosLocal.abrir(caminho: path);
    try {
      final logs = await migratedDatabase.listarLogs();
      expect(logs, hasLength(1));
      expect(logs.single.vehicle, 'Fastback Impétus');
      expect(logs.single.status, EntradaLog.completedStatus);
      expect(await migratedDatabase.listarFrames(logs.single.id!), isEmpty);
    } finally {
      await migratedDatabase.fechar();
      await directory.delete(recursive: true);
    }
  });
}
