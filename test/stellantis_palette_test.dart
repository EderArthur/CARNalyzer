import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:carnalyzer/data/banco_dados_local.dart';
import 'package:carnalyzer/main.dart';
import 'package:carnalyzer/models/entrada_log.dart';
import 'package:carnalyzer/models/frame_can.dart';
import 'package:carnalyzer/models/frame_telemetria.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('local preferences restore theme and vehicle', () async {
    final preferences = await SharedPreferences.getInstance();
    final persistence = PersistenciaLocal(preferences);

    await Future.wait([
      persistence.salvarTema(false),
      persistence.salvarVeiculo(
        const VeiculoPersistido(
          brand: 'Fastback',
          model: 'Impétus',
          year: '2026',
        ),
      ),
    ]);

    final restored = PersistenciaLocal(await SharedPreferences.getInstance());
    expect(restored.temaEscuro, isFalse);
    expect(restored.carregarVeiculo().brand, 'Fastback');
    expect(restored.carregarVeiculo().model, 'Impétus');
    expect(restored.carregarVeiculo().year, '2026');
  });

  testWidgets('dark mode uses Stellantis brand colors and light labels', (
    tester,
  ) async {
    final customDarkTheme = ThemeData.dark().copyWith(
      colorScheme: const ColorScheme.dark(
        primary: CoresAplicacao.primaryBlue,
        surface: CoresAplicacao.surface,
        onSurface: CoresAplicacao.text,
        onSurfaceVariant: CoresAplicacao.muted,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: customDarkTheme,
        home: const Scaffold(body: RotuloCampo('MODELO / MODEL')),
      ),
    );

    final label = tester.widget<Text>(find.text('MODELO / MODEL'));
    expect(label.style?.color, CoresAplicacao.muted);

    await tester.pumpWidget(const AplicativoCARNalyzer());
    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.theme?.colorScheme.primary, CoresAplicacao.orange);
    expect(materialApp.theme?.colorScheme.onSurface, CoresAplicacao.text);
  });

  testWidgets('light mode uses dark text for OBD status labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: Scaffold(
          body: PaginaVeiculo(
            connected: true,
            brand: 'Fastback',
            model: 'Impétus',
            year: '2026',
            isDarkMode: false,
            onThemeChanged: (_) {},
            onConnect: () {},
            onVehicleChanged: (_, __, ___) {},
          ),
        ),
      ),
    );

    final statusText = tester.widget<Text>(find.text('Status: Conectado'));
    final themeText = tester.widget<Text>(find.text('Tema'));

    expect(statusText.style?.color, CoresAplicacao.lightText);
    expect(themeText.style?.color, CoresAplicacao.lightText);
  });

  testWidgets('light mode keeps telemetry values readable', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: Scaffold(
          body: PaginaTelemetria(
            connected: true,
            brand: 'Fastback',
            model: 'Impétus',
            year: '2026',
            isDarkMode: false,
            onOpenLogs: () {},
            onLogRecorded: (_) {},
          ),
        ),
      ),
    );

    final speed = tester.widget<TextoNumericoAnimado>(
      find.descendant(
        of: find.byType(CartaoMedidor).first,
        matching: find.byType(TextoNumericoAnimado),
      ),
    );
    final label = tester.widget<Text>(find.text('VELOCIDADE'));

    expect(speed.style.color, CoresAplicacao.lightText);
    expect(label.style?.color, CoresAplicacao.lightMuted);
  });

  testWidgets('telemetry recording continues while changing tabs', (
    tester,
  ) async {
    await _pumpShell(tester);

    await tester.tap(find.text('INICIAR'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('GRAVANDO'), findsOneWidget);

    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();

    expect(find.textContaining('GRAVANDO'), findsOneWidget);

    await tester.tap(find.text('Veículo'));
    await tester.pumpAndSettle();

    expect(find.textContaining('GRAVANDO'), findsOneWidget);
  });

  testWidgets('telemetry creates a new log when stopping recording', (
    tester,
  ) async {
    EntradaLog? createdLog;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaginaTelemetria(
            connected: true,
            brand: 'Fastback',
            model: 'Impétus',
            year: '2026',
            isDarkMode: true,
            onOpenLogs: () {},
            onLogRecorded: (log) => createdLog = log,
          ),
        ),
      ),
    );

    await tester.tap(find.text('INICIAR'));
    await tester.pump();
    await tester.tap(find.text('PARAR'));
    await tester.pump();

    expect(createdLog, isNotNull);
    expect(createdLog!.vehicle, 'Fastback Impétus');
    expect(createdLog!.durationSeconds, greaterThanOrEqualTo(0));
  });

  testWidgets(
    'home screen log button is synchronized with telemetry recording',
    (tester) async {
      await _pumpShell(tester);

      await tester.tap(find.text('Veículo'));
      await tester.pump();

      expect(find.text('GRAVAR LOG'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('GRAVAR LOG'), 100);

      await tester.tap(find.text('GRAVAR LOG'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();

      expect(find.text('PARAR LOG'), findsOneWidget);

      await tester.tap(find.text('Telemetria'));
      await tester.pumpAndSettle();

      expect(find.text('PARAR'), findsOneWidget);
    },
  );

  testWidgets('logs light mode keeps text visible', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: Scaffold(
          body: PaginaLogs(
            logs: const [],
            onUpdateLog: (_) async {},
            onDeleteLog: (_) async => true,
          ),
        ),
      ),
    );

    expect(find.text('Nenhum log gravado ainda.'), findsOneWidget);
    expect(find.text('BCM_DIAG_RES_652'), findsNothing);
  });

  testWidgets(
    'telemetry resets values when recording is started from shell state',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaginaTelemetria(
              connected: true,
              brand: 'Fastback',
              model: 'Impétus',
              year: '2026',
              isDarkMode: true,
              isRecording: false,
              recordingSeconds: 0,
              onOpenLogs: () {},
              onLogRecorded: (_) {},
              onToggleRecording: () {},
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaginaTelemetria(
              connected: true,
              brand: 'Fastback',
              model: 'Impétus',
              year: '2026',
              isDarkMode: true,
              isRecording: true,
              recordingSeconds: 0,
              onOpenLogs: () {},
              onLogRecorded: (_) {},
              onToggleRecording: () {},
            ),
          ),
        ),
      );

      final gauge = tester.widget<CartaoMedidor>(
        find.byType(CartaoMedidor).first,
      );
      expect(gauge.value, 0);
    },
  );

  testWidgets('logs details show only after tapping view', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaginaLogs(
            logs: const [
              EntradaLog(
                vehicle: 'Fastback Impétus',
                durationSeconds: 12,
                timestamp: '06/09/2026 • 12:30',
                summary: 'Sessão gravada com OBD-II ativo',
              ),
            ],
            onUpdateLog: (_) async {},
            onDeleteLog: (_) async => true,
          ),
        ),
      ),
    );

    expect(find.textContaining('Frames de telemetria'), findsNothing);

    await tester.tap(find.text('Visualizar').first);
    await tester.pump();

    expect(find.text('Frames de telemetria (0)'), findsOneWidget);
  });

  testWidgets('tapping the selected log again closes its details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaginaLogs(
            logs: const [
              EntradaLog(
                vehicle: 'Fastback Impétus',
                durationSeconds: 12,
                timestamp: '06/09/2026 • 12:30',
                summary: 'Sessão gravada com OBD-II ativo',
              ),
            ],
            onUpdateLog: (_) async {},
            onDeleteLog: (_) async => true,
          ),
        ),
      ),
    );

    final visualize = find.text('Visualizar');
    await tester.tap(visualize);
    await tester.pump();
    expect(find.text('Frames de telemetria (0)'), findsOneWidget);

    await tester.tap(visualize);
    await tester.pump();
    expect(find.textContaining('Frames de telemetria'), findsNothing);
  });

  testWidgets('log details display persisted telemetry frames', (tester) async {
    final log = const EntradaLog(
      id: 8,
      vehicle: 'Fastback Impétus 2026',
      durationSeconds: 10,
      timestamp: '06/09/2026 • 12:30',
      summary: 'Sessão gravada com telemetria BLE ativa',
      sourceDevice: 'CARNalyzer-ESP32',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaginaLogs(
            logs: [log],
            onLoadFrames: (id) async => [
              FrameTelemetria(
                logId: id,
                capturedAt: DateTime.utc(2026, 10, 25, 21),
                speedKmh: 42,
                rpm: 1850,
                odometerKm: 14285.5,
                coolantTempC: 91,
                batteryVoltage: 14.1,
                rawPayload:
                    '{"speedKmh":42,"rpm":1850,"odometerKm":14285.5,'
                    '"coolantTempC":91,"batteryVoltage":14.1}',
              ),
            ],
            onUpdateLog: (_) async {},
            onDeleteLog: (_) async => true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Visualizar').first);
    await tester.pumpAndSettle();

    expect(find.text('Frames de telemetria (1)'), findsOneWidget);
    expect(find.text('42.0'), findsOneWidget);
    expect(find.text('1850'), findsOneWidget);
    expect(find.text('CARNalyzer-ESP32'), findsOneWidget);
  });

  testWidgets('log details display received CAN frames', (tester) async {
    final log = const EntradaLog(
      id: 9,
      vehicle: 'Fastback Impétus 2026',
      durationSeconds: 10,
      timestamp: '06/09/2026 • 12:30',
      summary: 'Sessão com frames CAN',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaginaLogs(
            logs: [log],
            onLoadCanFrames: (id) async => [
              FrameCan.fromJson(
                logId: id,
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
              ),
            ],
            onUpdateLog: (_) async {},
            onDeleteLog: (_) async => true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Visualizar').first);
    await tester.pumpAndSettle();

    expect(find.text('Frames CAN (1)'), findsOneWidget);
    expect(find.text('0x123'), findsOneWidget);
    expect(find.text('021001'), findsOneWidget);
  });
}

Future<BancoDadosLocal> _pumpShell(WidgetTester tester) async {
  final database = await tester.runAsync(
    () => BancoDadosLocal.abrir(caminho: inMemoryDatabasePath),
  );
  if (database == null) {
    throw StateError('SQLite test database did not open.');
  }

  await tester.pumpWidget(
    MaterialApp(
      home: ShellPrincipal(
        isDarkMode: true,
        onThemeChanged: (_) {},
        bancoDados: database,
        logsIniciais: const [],
      ),
    ),
  );
  return database;
}
