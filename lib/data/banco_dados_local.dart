import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/entrada_log.dart';
import '../models/frame_can.dart';
import '../models/frame_telemetria.dart';
import 'database_factory.dart';

class BancoDadosLocal {
  static const _databaseName = 'carnalyzer.db';
  static const _logsTable = 'logs';
  static const _framesTable = 'log_frames';
  static const _canFramesTable = 'can_frames';

  final Database _database;

  BancoDadosLocal._(this._database);

  static Future<BancoDadosLocal> abrir({String? caminho}) async {
    await configureDatabaseFactory();
    final databasePath =
        caminho ??
        (kIsWeb ? _databaseName : '${await getDatabasesPath()}/$_databaseName');
    final database = await openDatabase(
      databasePath,
      version: 3,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE $_logsTable ADD COLUMN status TEXT NOT NULL "
            "DEFAULT '${EntradaLog.completedStatus}' "
            "CHECK (status IN ('${EntradaLog.recordingStatus}', "
            "'${EntradaLog.completedStatus}', "
            "'${EntradaLog.interruptedStatus}'))",
          );
          await db.execute(
            'ALTER TABLE $_logsTable ADD COLUMN source_device TEXT',
          );
          await _createFramesTable(db);
        }
        if (oldVersion < 3) {
          await _createCanFramesTable(db);
        }
      },
    );
    return BancoDadosLocal._(database);
  }

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $_logsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        vehicle TEXT NOT NULL,
        duration_seconds INTEGER NOT NULL CHECK (duration_seconds >= 0),
        timestamp TEXT NOT NULL,
        summary TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT '${EntradaLog.completedStatus}'
          CHECK (status IN ('${EntradaLog.recordingStatus}',
            '${EntradaLog.completedStatus}', '${EntradaLog.interruptedStatus}')),
        source_device TEXT
      )
    ''');
    await _createFramesTable(db);
    await _createCanFramesTable(db);
  }

  static Future<void> _createFramesTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $_framesTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        log_id INTEGER NOT NULL,
        captured_at TEXT NOT NULL,
        speed_kmh REAL NOT NULL,
        rpm REAL NOT NULL,
        odometer_km REAL NOT NULL,
        coolant_temp_c REAL NOT NULL,
        battery_voltage REAL NOT NULL,
        raw_payload TEXT NOT NULL,
        FOREIGN KEY (log_id) REFERENCES $_logsTable(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_log_frames_log_time '
      'ON $_framesTable (log_id, captured_at)',
    );
  }

  static Future<void> _createCanFramesTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $_canFramesTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        log_id INTEGER NOT NULL,
        captured_at TEXT NOT NULL,
        can_id INTEGER NOT NULL,
        extended INTEGER NOT NULL CHECK (extended IN (0, 1)),
        remote_request INTEGER NOT NULL CHECK (remote_request IN (0, 1)),
        dlc INTEGER NOT NULL CHECK (dlc BETWEEN 0 AND 8),
        data_hex TEXT NOT NULL,
        device_timestamp_ms INTEGER,
        raw_payload TEXT NOT NULL,
        FOREIGN KEY (log_id) REFERENCES $_logsTable(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_can_frames_log_time '
      'ON $_canFramesTable (log_id, captured_at)',
    );
    await db.execute(
      'CREATE INDEX idx_can_frames_log_id '
      'ON $_canFramesTable (log_id, can_id)',
    );
  }

  Future<List<EntradaLog>> listarLogs() async {
    final rows = await _database.query(_logsTable, orderBy: 'id DESC');
    return rows.map(EntradaLog.fromMap).toList();
  }

  Future<EntradaLog> criarLog(EntradaLog log) async {
    final id = await _database.insert(_logsTable, log.toMap());
    return log.copyWith(id: id);
  }

  Future<EntradaLog> iniciarLog(EntradaLog log) async {
    if (log.status != EntradaLog.recordingStatus) {
      throw ArgumentError.value(
        log.status,
        'log.status',
        'Uma gravação deve ser iniciada com status recording.',
      );
    }
    return criarLog(log);
  }

  Future<void> finalizarLog({
    required int id,
    required int durationSeconds,
    required String summary,
  }) async {
    final updatedRows = await _database.update(
      _logsTable,
      {
        'duration_seconds': durationSeconds,
        'summary': summary,
        'status': EntradaLog.completedStatus,
      },
      where: 'id = ? AND status = ?',
      whereArgs: [id, EntradaLog.recordingStatus],
    );
    if (updatedRows != 1) {
      throw StateError(
        'A gravação $id não foi encontrada ou já foi finalizada.',
      );
    }
  }

  Future<void> marcarGravacoesInterrompidas() async {
    await _database.update(
      _logsTable,
      {
        'status': EntradaLog.interruptedStatus,
        'summary': 'Gravação interrompida antes de ser finalizada',
      },
      where: 'status = ?',
      whereArgs: [EntradaLog.recordingStatus],
    );
  }

  Future<void> salvarFrame(FrameTelemetria frame) async {
    await _database.insert(_framesTable, frame.toMap());
  }

  Future<List<FrameTelemetria>> listarFrames(int logId) async {
    final rows = await _database.query(
      _framesTable,
      where: 'log_id = ?',
      whereArgs: [logId],
      orderBy: 'captured_at ASC, id ASC',
    );
    return rows.map(FrameTelemetria.fromMap).toList();
  }

  Future<void> salvarFrameCan(FrameCan frame) async {
    await _database.insert(_canFramesTable, frame.toMap());
  }

  Future<List<FrameCan>> listarFramesCan(int logId) async {
    final rows = await _database.query(
      _canFramesTable,
      where: 'log_id = ?',
      whereArgs: [logId],
      orderBy: 'captured_at ASC, id ASC',
    );
    return rows.map(FrameCan.fromMap).toList();
  }

  Future<void> atualizarLog(EntradaLog log) async {
    final id = log.id;
    if (id == null) {
      throw ArgumentError.value(id, 'log.id', 'O log precisa estar salvo.');
    }

    final updatedRows = await _database.update(
      _logsTable,
      log.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updatedRows != 1) {
      throw StateError('O log $id não foi encontrado para atualização.');
    }
  }

  Future<void> excluirLog(int id) async {
    final deletedRows = await _database.transaction((transaction) async {
      await transaction.delete(
        _framesTable,
        where: 'log_id = ?',
        whereArgs: [id],
      );
      await transaction.delete(
        _canFramesTable,
        where: 'log_id = ?',
        whereArgs: [id],
      );
      return transaction.delete(_logsTable, where: 'id = ?', whereArgs: [id]);
    });
    if (deletedRows != 1) {
      throw StateError('O log $id não foi encontrado para exclusão.');
    }
  }

  Future<void> importarLogsLegados(String? legacyJson) async {
    if (legacyJson == null) return;

    final decoded = jsonDecode(legacyJson);
    if (decoded is! List) {
      throw const FormatException('Formato do histórico legado inválido.');
    }
    final logs = decoded.map((entry) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Formato de log legado inválido.');
      }
      return EntradaLog.fromLegacyJson(entry);
    }).toList();

    await _database.transaction((transaction) async {
      final existingLogs = await transaction.query(_logsTable, limit: 1);
      if (existingLogs.isNotEmpty) return;
      for (final log in logs) {
        await transaction.insert(_logsTable, log.toMap());
      }
    });
  }

  Future<void> fechar() => _database.close();
}
