import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:carnalyzer/data/banco_dados_local.dart';
import 'package:carnalyzer/main.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('shell opens the telemetry screen with SQLite', (tester) async {
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

    expect(find.text('RPM MOTOR'), findsOneWidget);
  });

  testWidgets('shell opens the ESP32 BLE device chooser', (tester) async {
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

    await tester.tap(find.text('Veículo'));
    await tester.pumpAndSettle();
    final connectButton = find.text('CONECTAR ESP32 VIA BLE');
    await tester.ensureVisible(connectButton);
    await tester.tap(connectButton);
    await tester.pumpAndSettle();

    expect(find.text('Conectar ao ESP32'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
  });
}
