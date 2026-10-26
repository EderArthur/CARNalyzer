import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/banco_dados_local.dart';
import 'models/esp32_telemetry.dart';
import 'models/entrada_log.dart';
import 'models/frame_can.dart';
import 'models/frame_telemetria.dart';
import 'services/esp32_ble_client.dart';

void main() {
  runApp(const AplicativoCARNalyzer());
}

class CoresAplicacao {
  static const primaryBlue = Color(0xFF243782);
  static const deepBlue = Color(0xFF001E50);
  static const tangerine = Color(0xFFE94E24);
  static const mint = Color(0xFF43AAA0);
  static const brandOrange = Color(0xFFECA935);
  static const anthracite = Color(0xFF282B34);

  static const background = Color(0xFF080808);
  static const surface = Color(0xFF001E50);
  static const surface2 = Color(0xFF171719);
  static const card = Color(0xFFFFFFFF);
  static const border = Color(0xFF75787B);
  static const text = Color(0xFFF5F5F7);
  static const muted = Color(0xFF75787B);
  static const orange = Color(0xFFFF6A00);
  static const yellow = Color(0xFFFFC400);
  static const blue = Color(0xFF243782);
  static const red = Color(0xFFFF3B3B);
  static const green = Color(0xFF20C76A);

  static const lightBackground = Color(0xFFEAF2FA);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurface2 = Color(0xFFF1F5FB);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightBorder = Color(0xFFCDD5E3);
  static const lightText = Color(0xFF001E50);
  static const lightMuted = Color(0xFF75787B);
  static const lightBlue = primaryBlue;
}

class VeiculoPersistido {
  final String brand;
  final String model;
  final String year;

  const VeiculoPersistido({
    required this.brand,
    required this.model,
    required this.year,
  });
}

class PersistenciaLocal {
  static const _themeKey = 'carnalyzer.theme.dark';
  static const _vehicleKey = 'carnalyzer.vehicle';

  final SharedPreferences _preferences;
  Future<void> _saveQueue = Future<void>.value();

  PersistenciaLocal(this._preferences);

  bool get temaEscuro => _preferences.getBool(_themeKey) ?? true;

  VeiculoPersistido carregarVeiculo() {
    final rawVehicle = _preferences.getString(_vehicleKey);
    if (rawVehicle == null) {
      return const VeiculoPersistido(
        brand: 'Fastback',
        model: 'Impétus',
        year: '2026',
      );
    }

    try {
      final decoded = jsonDecode(rawVehicle);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Formato de veículo inválido.');
      }
      final brand = decoded['brand'];
      final model = decoded['model'];
      final year = decoded['year'];
      if (brand is! String || model is! String || year is! String) {
        throw const FormatException('Formato de veículo inválido.');
      }
      return VeiculoPersistido(brand: brand, model: model, year: year);
    } on FormatException catch (error, stackTrace) {
      debugPrint(
        'Não foi possível carregar o veículo salvo: $error\n$stackTrace',
      );
      return const VeiculoPersistido(
        brand: 'Fastback',
        model: 'Impétus',
        year: '2026',
      );
    }
  }

  Future<void> salvarTema(bool isDarkMode) =>
      _enqueueSave('tema', () => _preferences.setBool(_themeKey, isDarkMode));

  Future<void> salvarVeiculo(VeiculoPersistido vehicle) => _enqueueSave(
    'veículo',
    () => _preferences.setString(
      _vehicleKey,
      jsonEncode({
        'brand': vehicle.brand,
        'model': vehicle.model,
        'year': vehicle.year,
      }),
    ),
  );

  Future<void> _enqueueSave(String item, Future<bool> Function() save) {
    _saveQueue = _saveQueue.then((_) async {
      try {
        if (!await save()) {
          debugPrint('Não foi possível salvar $item no armazenamento local.');
        }
      } on Exception catch (error, stackTrace) {
        debugPrint('Erro ao salvar $item: $error\n$stackTrace');
      }
    });
    return _saveQueue;
  }
}

class AplicativoCARNalyzer extends StatefulWidget {
  const AplicativoCARNalyzer({super.key});

  @override
  State<AplicativoCARNalyzer> createState() => _AplicativoCARNalyzerState();
}

class _AplicativoCARNalyzerState extends State<AplicativoCARNalyzer> {
  bool isDarkMode = true;
  bool _isLoadingPreferences = true;
  String? _initializationError;
  PersistenciaLocal? _persistencia;
  BancoDadosLocal? _bancoDados;
  List<EntradaLog> _logsIniciais = [];

  @override
  void dispose() {
    final database = _bancoDados;
    if (database != null) unawaited(database.fechar());
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_carregarPreferencias());
  }

  Future<void> _carregarPreferencias() async {
    setState(() {
      _isLoadingPreferences = true;
      _initializationError = null;
    });
    BancoDadosLocal? database;
    try {
      final preferences = await SharedPreferences.getInstance();
      database = await BancoDadosLocal.abrir();
      const legacyLogsKey = 'carnalyzer.logs';
      final legacyLogs = preferences.getString(legacyLogsKey);
      await database.importarLogsLegados(legacyLogs);
      await database.marcarGravacoesInterrompidas();
      if (legacyLogs != null && !await preferences.remove(legacyLogsKey)) {
        throw const FormatException(
          'O histórico antigo não pôde ser removido.',
        );
      }
      final logs = await database.listarLogs();
      if (!mounted) {
        await database.fechar();
        return;
      }
      final persistence = PersistenciaLocal(preferences);
      setState(() {
        _persistencia = persistence;
        _bancoDados = database;
        _logsIniciais = logs;
        isDarkMode = persistence.temaEscuro;
        _isLoadingPreferences = false;
      });
    } on Exception catch (error, stackTrace) {
      debugPrint(
        'Não foi possível inicializar a persistência local: $error\n$stackTrace',
      );
      if (database != null) await database.fechar();
      if (!mounted) return;
      setState(() {
        _initializationError = error.toString();
        _isLoadingPreferences = false;
      });
    }
  }

  void _atualizarTema(bool value) {
    setState(() => isDarkMode = value);
    final persistence = _persistencia;
    if (persistence != null) {
      unawaited(persistence.salvarTema(value));
    }
  }

  ThemeData _buildTheme() {
    final isLight = !isDarkMode;
    final textColor = isLight ? CoresAplicacao.lightText : CoresAplicacao.text;

    return ThemeData(
      brightness: isDarkMode ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: isLight
          ? CoresAplicacao.lightBackground
          : CoresAplicacao.background,
      fontFamily: 'Arial',
      colorScheme: isDarkMode
          ? const ColorScheme.dark(
              primary: CoresAplicacao.orange,
              surface: CoresAplicacao.surface,
              onSurface: CoresAplicacao.text,
              onSurfaceVariant: CoresAplicacao.muted,
            )
          : const ColorScheme.light(
              primary: CoresAplicacao.primaryBlue,
              surface: CoresAplicacao.lightSurface,
              onSurface: CoresAplicacao.lightText,
              onSurfaceVariant: CoresAplicacao.lightMuted,
            ),
      textTheme:
          ThemeData(
            brightness: isDarkMode ? Brightness.dark : Brightness.light,
          ).textTheme.apply(
            bodyColor: textColor,
            displayColor: textColor,
            decorationColor: textColor,
          ),
      iconTheme: IconThemeData(
        color: isLight ? CoresAplicacao.lightText : CoresAplicacao.text,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isLight
            ? CoresAplicacao.lightSurface
            : CoresAplicacao.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isLight ? CoresAplicacao.lightBorder : CoresAplicacao.border,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isLight ? CoresAplicacao.lightBorder : CoresAplicacao.border,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: CoresAplicacao.orange),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: isLight
            ? CoresAplicacao.lightBackground
            : const Color(0xFF111113),
        selectedItemColor: isLight
            ? CoresAplicacao.lightBlue
            : const Color(0xFF9BB4FF),
        unselectedItemColor: isLight
            ? CoresAplicacao.lightMuted
            : CoresAplicacao.muted,
      ),
      dividerColor: isLight
          ? CoresAplicacao.lightBorder
          : CoresAplicacao.border,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: CoresAplicacao.orange,
        selectionColor: CoresAplicacao.orange.withValues(alpha: .22),
        selectionHandleColor: CoresAplicacao.orange,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CARNalyzer',
      theme: _buildTheme(),
      darkTheme: _buildTheme(),
      themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: _isLoadingPreferences
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _initializationError != null
          ? Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Não foi possível abrir o banco de dados local.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(_initializationError!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _carregarPreferencias,
                        child: const Text('Tentar novamente'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : ShellPrincipal(
              isDarkMode: isDarkMode,
              onThemeChanged: _atualizarTema,
              persistencia: _persistencia,
              bancoDados: _bancoDados!,
              logsIniciais: _logsIniciais,
            ),
    );
  }
}

class ShellPrincipal extends StatefulWidget {
  final bool isDarkMode;
  final ValueChanged<bool> onThemeChanged;
  final PersistenciaLocal? persistencia;
  final BancoDadosLocal bancoDados;
  final List<EntradaLog> logsIniciais;

  const ShellPrincipal({
    super.key,
    required this.isDarkMode,
    required this.onThemeChanged,
    this.persistencia,
    required this.bancoDados,
    required this.logsIniciais,
  });

  @override
  State<ShellPrincipal> createState() => _ShellPrincipalState();
}

class _ShellPrincipalState extends State<ShellPrincipal> {
  int selected = 1;
  bool connected = false;
  bool _isConnecting = false;
  bool _disconnectRequested = false;
  bool _isFinalizingRecording = false;
  bool isRecording = false;
  int recordingSeconds = 0;
  Timer? _recordingTimer;
  String brand = 'Fastback';
  String model = 'Impétus';
  String year = '2026';
  final List<EntradaLog> logs = [];
  final Esp32BleClient _bleClient = Esp32BleClient();
  final List<int> _telemetryBytes = [];
  Future<void> _frameSaveQueue = Future<void>.value();
  int? _activeLogId;
  EntradaLog? _activeLog;
  bool _frameSaveErrorShown = false;
  BleDevice? _connectedDevice;
  Esp32Telemetry? _telemetry;
  StreamSubscription<Uint8List>? _telemetrySubscription;
  StreamSubscription<bool>? _connectionSubscription;

  @override
  void initState() {
    super.initState();
    logs.addAll(widget.logsIniciais);
    final persistence = widget.persistencia;
    if (persistence == null) return;

    final vehicle = persistence.carregarVeiculo();
    brand = vehicle.brand;
    model = vehicle.model;
    year = vehicle.year;
  }

  String _formatDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> conectar() async {
    if (_isConnecting) return;
    if (connected) {
      await _disconnectEsp32();
      return;
    }

    final device = await showDialog<BleDevice>(
      context: context,
      builder: (context) => _DialogoDispositivosBle(client: _bleClient),
    );
    if (device == null || !mounted) return;

    setState(() => _isConnecting = true);
    try {
      await _bleClient.connect(device);
      if (!mounted) {
        await _bleClient.disconnect();
        return;
      }
      setState(() {
        connected = true;
        _connectedDevice = device;
        _telemetry = null;
        _telemetryBytes.clear();
      });
      _telemetrySubscription = _bleClient
          .telemetryStream(device.deviceId)
          .listen(_receberTelemetria, onError: _onErroTelemetria);
      _connectionSubscription = _bleClient
          .connectionChanges(device.deviceId)
          .listen(_onEstadoConexao, onError: _onErroTelemetria);
    } catch (error, stackTrace) {
      debugPrint('Não foi possível conectar ao ESP32: $error\n$stackTrace');
      _mostrarErroBluetooth('Não foi possível conectar ao ESP32: $error');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnectEsp32() async {
    setState(() => _isConnecting = true);
    _disconnectRequested = true;
    try {
      await _bleClient.disconnect();
      _limparEstadoConexao();
    } catch (error, stackTrace) {
      debugPrint('Não foi possível desconectar do ESP32: $error\n$stackTrace');
      _mostrarErroBluetooth('Não foi possível desconectar do ESP32: $error');
    } finally {
      _disconnectRequested = false;
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnectOnDispose() async {
    try {
      await _bleClient.disconnect();
    } catch (error, stackTrace) {
      debugPrint('Erro ao encerrar BLE durante dispose: $error\n$stackTrace');
    }
  }

  void _limparEstadoConexao() {
    unawaited(_telemetrySubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    _telemetrySubscription = null;
    _connectionSubscription = null;
    _connectedDevice = null;
    _telemetryBytes.clear();
    if (mounted) {
      setState(() {
        connected = false;
        _telemetry = null;
      });
    }
  }

  void _onEstadoConexao(bool isConnected) {
    if (!isConnected && mounted && connected && !_disconnectRequested) {
      _limparEstadoConexao();
      unawaited(_disconnectOnDispose());
      _mostrarErroBluetooth('A conexão Bluetooth com o ESP32 foi encerrada.');
    }
  }

  void _receberTelemetria(Uint8List chunk) {
    for (final byte in chunk) {
      if (byte == 10) {
        if (_telemetryBytes.isEmpty) continue;
        String line;
        try {
          line = utf8.decode(_telemetryBytes, allowMalformed: false).trim();
        } on FormatException catch (error, stackTrace) {
          _telemetryBytes.clear();
          debugPrint('Texto BLE de telemetria inválido: $error\n$stackTrace');
          continue;
        }
        _telemetryBytes.clear();
        if (line.isNotEmpty) _processarLinhaTelemetria(line);
      } else if (byte != 13) {
        _telemetryBytes.add(byte);
        if (_telemetryBytes.length > 1024) {
          _telemetryBytes.clear();
          debugPrint('Pacote de telemetria excedeu o limite de 1024 bytes.');
        }
      }
    }
  }

  void _processarLinhaTelemetria(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('O pacote não é um objeto JSON.');
      }
      if (decoded['type'] == 'can_frame') {
        _processarFrameCan(decoded, line);
        return;
      }
      final telemetry = Esp32Telemetry.fromJson(decoded);
      if (mounted) setState(() => _telemetry = telemetry);
      _salvarFrameDeTelemetria(telemetry, line);
    } on FormatException catch (error, stackTrace) {
      debugPrint('Pacote BLE de telemetria inválido: $error\n$stackTrace');
    }
  }

  void _processarFrameCan(Map<String, dynamic> json, String payload) {
    final logId = _activeLogId;
    if (!isRecording || _isFinalizingRecording || logId == null) return;

    final frame = FrameCan.fromJson(
      logId: logId,
      capturedAt: DateTime.now().toUtc(),
      json: json,
      rawPayload: payload,
    );
    _frameSaveQueue = _frameSaveQueue.then((_) async {
      try {
        await widget.bancoDados.salvarFrameCan(frame);
      } on Exception catch (error, stackTrace) {
        debugPrint('Não foi possível salvar um frame CAN: $error\n$stackTrace');
        if (!_frameSaveErrorShown && mounted) {
          _frameSaveErrorShown = true;
          _mostrarErroBluetooth('Um frame CAN não pôde ser salvo: $error');
        }
      }
    });
  }

  void _salvarFrameDeTelemetria(Esp32Telemetry telemetry, String payload) {
    final logId = _activeLogId;
    if (!isRecording || _isFinalizingRecording || logId == null) return;

    final frame = FrameTelemetria(
      logId: logId,
      capturedAt: DateTime.now().toUtc(),
      speedKmh: telemetry.speedKmh,
      rpm: telemetry.rpm,
      odometerKm: telemetry.odometerKm,
      coolantTempC: telemetry.coolantTempC,
      batteryVoltage: telemetry.batteryVoltage,
      rawPayload: payload,
    );

    _frameSaveQueue = _frameSaveQueue.then((_) async {
      try {
        await widget.bancoDados.salvarFrame(frame);
      } on Exception catch (error, stackTrace) {
        debugPrint('Não foi possível salvar um frame BLE: $error\n$stackTrace');
        if (!_frameSaveErrorShown && mounted) {
          _frameSaveErrorShown = true;
          _mostrarErroBluetooth(
            'Um frame recebido não pôde ser salvo no log: $error',
          );
        }
      }
    });
  }

  void _onErroTelemetria(Object error, StackTrace stackTrace) {
    debugPrint('Erro no fluxo BLE do ESP32: $error\n$stackTrace');
    _mostrarErroBluetooth('A conexão BLE apresentou um erro: $error');
  }

  void _mostrarErroBluetooth(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void atualizarVeiculo(String nextBrand, String nextModel, String nextYear) {
    setState(() {
      brand = nextBrand;
      model = nextModel;
      year = nextYear;
    });
    final persistence = widget.persistencia;
    if (persistence != null) {
      unawaited(
        persistence.salvarVeiculo(
          VeiculoPersistido(brand: nextBrand, model: nextModel, year: nextYear),
        ),
      );
    }
  }

  Future<void> adicionarLog(EntradaLog log) async {
    try {
      final savedLog = await widget.bancoDados.criarLog(log);
      if (!mounted) return;
      setState(() => logs.insert(0, savedLog));
    } on Exception catch (error, stackTrace) {
      _mostrarErroPersistencia('salvar o log', error, stackTrace);
    }
  }

  Future<void> atualizarLog(EntradaLog log) async {
    try {
      await widget.bancoDados.atualizarLog(log);
      if (!mounted) return;
      setState(() {
        final index = logs.indexWhere((existing) => existing.id == log.id);
        if (index >= 0) logs[index] = log;
      });
    } on Exception catch (error, stackTrace) {
      _mostrarErroPersistencia('atualizar o log', error, stackTrace);
    }
  }

  Future<bool> excluirLog(EntradaLog log) async {
    final id = log.id;
    if (id == null) return false;
    try {
      await widget.bancoDados.excluirLog(id);
      if (!mounted) return true;
      setState(() => logs.removeWhere((entry) => entry.id == id));
      return true;
    } on Exception catch (error, stackTrace) {
      _mostrarErroPersistencia('excluir o log', error, stackTrace);
      return false;
    }
  }

  void _mostrarErroPersistencia(
    String acao,
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint('Não foi possível $acao: $error\n$stackTrace');
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Não foi possível $acao: $error')));
  }

  void alternarGravacao() => unawaited(_alternarGravacao());

  Future<void> _alternarGravacao() async {
    if (isRecording) {
      if (_isFinalizingRecording) return;
      final activeLog = _activeLog;
      final activeLogId = _activeLogId;
      if (activeLog == null || activeLogId == null) {
        _mostrarErroBluetooth('Não foi possível identificar a gravação ativa.');
        return;
      }
      _isFinalizingRecording = true;
      try {
        await _frameSaveQueue;
        final summary = connected
            ? 'Sessão gravada com telemetria BLE ativa'
            : 'Sessão gravada sem conexão BLE';
        await widget.bancoDados.finalizarLog(
          id: activeLogId,
          durationSeconds: recordingSeconds,
          summary: summary,
        );
        final completedLog = activeLog.copyWith(
          durationSeconds: recordingSeconds,
          summary: summary,
          status: EntradaLog.completedStatus,
        );
        _recordingTimer?.cancel();
        _recordingTimer = null;
        _activeLogId = null;
        _activeLog = null;
        _frameSaveErrorShown = false;
        if (mounted) {
          setState(() {
            isRecording = false;
            logs.insert(0, completedLog);
          });
        }
      } on Exception catch (error, stackTrace) {
        _mostrarErroPersistencia('finalizar a gravação', error, stackTrace);
      } finally {
        _isFinalizingRecording = false;
      }
      return;
    }

    final startedAt = DateTime.now();
    final log = EntradaLog(
      vehicle: '$brand $model $year',
      durationSeconds: 0,
      timestamp: startedAt
          .toLocal()
          .toString()
          .substring(0, 16)
          .replaceFirst('T', ' '),
      summary: 'Gravação em andamento',
      status: EntradaLog.recordingStatus,
      sourceDevice: _connectedDevice?.name ?? _connectedDevice?.deviceId,
    );
    try {
      final savedLog = await widget.bancoDados.iniciarLog(log);
      if (!mounted) return;
      _activeLog = savedLog;
      _activeLogId = savedLog.id;
      _frameSaveQueue = Future<void>.value();
      _frameSaveErrorShown = false;
      setState(() {
        isRecording = true;
        recordingSeconds = 0;
      });

      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) {
          _recordingTimer?.cancel();
          _recordingTimer = null;
          return;
        }

        setState(() {
          recordingSeconds += 1;
        });
      });
    } on Exception catch (error, stackTrace) {
      _mostrarErroPersistencia('iniciar a gravação', error, stackTrace);
    }
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    unawaited(_telemetrySubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    unawaited(_disconnectOnDispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      PaginaVeiculo(
        connected: connected,
        brand: brand,
        model: model,
        year: year,
        isDarkMode: widget.isDarkMode,
        isRecording: isRecording,
        onThemeChanged: widget.onThemeChanged,
        onConnect: () => unawaited(conectar()),
        isConnecting: _isConnecting,
        deviceName: _connectedDevice?.name,
        onVehicleChanged: atualizarVeiculo,
        onToggleRecording: alternarGravacao,
      ),
      PaginaTelemetria(
        connected: connected,
        brand: brand,
        model: model,
        year: year,
        isDarkMode: widget.isDarkMode,
        isRecording: isRecording,
        recordingSeconds: recordingSeconds,
        telemetry: _telemetry,
        onOpenLogs: () => setState(() => selected = 2),
        onLogRecorded: (log) => unawaited(adicionarLog(log)),
        onRecordingStateChanged: (recording, seconds) {
          setState(() {
            isRecording = recording;
            recordingSeconds = seconds;
          });
        },
        onToggleRecording: alternarGravacao,
      ),
      PaginaLogs(
        logs: logs,
        onLoadFrames: widget.bancoDados.listarFrames,
        onLoadCanFrames: widget.bancoDados.listarFramesCan,
        onUpdateLog: atualizarLog,
        onDeleteLog: excluirLog,
      ),
      const PaginaSobre(),
    ];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (isRecording)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 14,
                ),
                decoration: BoxDecoration(
                  color: widget.isDarkMode
                      ? CoresAplicacao.red.withValues(alpha: 0.12)
                      : CoresAplicacao.red.withValues(alpha: 0.08),
                  border: Border(
                    bottom: BorderSide(
                      color: widget.isDarkMode
                          ? CoresAplicacao.red.withValues(alpha: 0.45)
                          : CoresAplicacao.red.withValues(alpha: 0.35),
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: CoresAplicacao.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'GRAVANDO • ${_formatDuration(recordingSeconds)}',
                      style: TextStyle(
                        color: widget.isDarkMode
                            ? CoresAplicacao.text
                            : CoresAplicacao.lightText,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: IndexedStack(index: selected, children: pages),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: selected,
        onTap: (index) => setState(() => selected = index),
        backgroundColor: widget.isDarkMode
            ? const Color(0xFF111113)
            : const Color(0xFFF4F6F9),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: widget.isDarkMode
            ? const Color(0xFF9BB4FF)
            : CoresAplicacao.orange,
        unselectedItemColor: widget.isDarkMode
            ? const Color(0xFF7A8393)
            : const Color(0xFF68686F),
        selectedFontSize: 10,
        unselectedFontSize: 10,
        showUnselectedLabels: true,
        elevation: 0,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.tune), label: 'Veículo'),
          BottomNavigationBarItem(
            icon: Icon(Icons.monitor_heart_outlined),
            activeIcon: Icon(Icons.monitor_heart),
            label: 'Telemetria',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.list_alt_outlined),
            activeIcon: Icon(Icons.list_alt),
            label: 'Logs',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.info_outline),
            activeIcon: Icon(Icons.info),
            label: 'Sobre',
          ),
        ],
      ),
    );
  }
}

class _DialogoDispositivosBle extends StatefulWidget {
  final Esp32BleClient client;

  const _DialogoDispositivosBle({required this.client});

  @override
  State<_DialogoDispositivosBle> createState() =>
      _DialogoDispositivosBleState();
}

class _DialogoDispositivosBleState extends State<_DialogoDispositivosBle> {
  final List<BleDevice> _devices = [];
  StreamSubscription<BleDevice>? _scanSubscription;
  Timer? _scanTimer;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scanSubscription = widget.client.scanResults.listen(
      (device) {
        if (!mounted) return;
        final index = _devices.indexWhere(
          (item) => item.deviceId == device.deviceId,
        );
        setState(() {
          if (index == -1) {
            _devices.add(device);
          } else {
            _devices[index] = device;
          }
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Erro ao buscar dispositivos BLE: $error\n$stackTrace');
        if (mounted) setState(() => _error = error.toString());
      },
    );
  }

  Future<void> _startScan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _error = null;
      _devices.clear();
    });
    try {
      await widget.client.startScan();
      if (!kIsWeb && mounted) {
        _scanTimer = Timer(const Duration(seconds: 15), _stopScan);
      } else if (mounted) {
        setState(() => _scanning = false);
      }
    } catch (error, stackTrace) {
      debugPrint(
        'Não foi possível buscar dispositivos BLE: $error\n$stackTrace',
      );
      if (mounted) {
        setState(() {
          _scanning = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    try {
      await widget.client.stopScan();
    } catch (error, stackTrace) {
      debugPrint('Não foi possível encerrar a busca BLE: $error\n$stackTrace');
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _selectDevice(BleDevice device) async {
    await _stopScan();
    if (mounted) Navigator.of(context).pop(device);
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    unawaited(_scanSubscription?.cancel());
    if (_scanning) unawaited(widget.client.stopScan());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Conectar ao ESP32'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              kIsWeb
                  ? 'No navegador, escolha o ESP32 na janela de dispositivos Bluetooth.'
                  : 'Ligue o ESP32 e inicie a busca por dispositivos BLE próximos.',
            ),
            const SizedBox(height: 12),
            if (_error != null) ...[
              Text(
                'Falha na busca: $_error',
                style: TextStyle(color: colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            if (_scanning && _devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_devices.isNotEmpty)
              SizedBox(
                height: 200,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _devices.length,
                  itemBuilder: (context, index) {
                    final device = _devices[index];
                    return ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(
                        device.name?.isNotEmpty == true
                            ? device.name!
                            : 'Dispositivo BLE',
                      ),
                      subtitle: Text(device.deviceId),
                      onTap: () => _selectDevice(device),
                    );
                  },
                ),
              )
            else if (!_scanning)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Nenhum dispositivo encontrado ainda.'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        if (_scanning && !kIsWeb)
          TextButton(onPressed: _stopScan, child: const Text('Parar busca')),
        FilledButton.icon(
          onPressed: _scanning ? null : _startScan,
          icon: const Icon(Icons.search),
          label: Text(_scanning ? 'Buscando...' : 'Buscar dispositivos'),
        ),
      ],
    );
  }
}

class CabecalhoPagina extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? badge;

  const CabecalhoPagina({
    super.key,
    required this.title,
    required this.subtitle,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                subtitle,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
        if (badge != null) Flexible(child: badge!),
      ],
    );
  }
}

class SeloStatus extends StatelessWidget {
  final String text;
  final Color color;

  const SeloStatus({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        border: Border.all(color: color.withValues(alpha: .65)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 8,
              fontWeight: FontWeight.w800,
              letterSpacing: .4,
            ),
          ),
        ],
      ),
    );
  }
}

class PaginaVeiculo extends StatefulWidget {
  final bool connected;
  final String brand;
  final String model;
  final String year;
  final bool isDarkMode;
  final bool isRecording;
  final ValueChanged<bool> onThemeChanged;
  final VoidCallback? onConnect;
  final bool isConnecting;
  final String? deviceName;
  final VoidCallback? onToggleRecording;
  final void Function(String brand, String model, String year) onVehicleChanged;

  const PaginaVeiculo({
    super.key,
    required this.connected,
    required this.brand,
    required this.model,
    required this.year,
    required this.isDarkMode,
    this.isRecording = false,
    required this.onThemeChanged,
    required this.onConnect,
    this.isConnecting = false,
    this.deviceName,
    this.onToggleRecording,
    required this.onVehicleChanged,
  });

  @override
  State<PaginaVeiculo> createState() => _PaginaVeiculoState();
}

class _PaginaVeiculoState extends State<PaginaVeiculo> {
  @override
  Widget build(BuildContext context) {
    final isLight = !widget.isDarkMode;
    final cardColor = isLight ? CoresAplicacao.lightCard : CoresAplicacao.card;
    final borderColor = isLight
        ? CoresAplicacao.lightBorder
        : CoresAplicacao.border;
    final textColor = isLight ? CoresAplicacao.lightText : CoresAplicacao.text;
    final mutedColor = isLight
        ? CoresAplicacao.lightMuted
        : CoresAplicacao.muted;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 360;
        final horizontalPadding = compact ? 14.0 : 20.0;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            12,
            horizontalPadding,
            18,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: compact ? double.infinity : 420,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CabecalhoPagina(
                  title: 'Configuração',
                  subtitle: 'Selecione o veículo do ecossistema Stellantis',
                  badge: SeloStatus(
                    text: widget.connected ? 'CONNECTED' : 'DISCONNECTED',
                    color: widget.connected
                        ? CoresAplicacao.green
                        : CoresAplicacao.red,
                  ),
                ),
                const SizedBox(height: 20),
                const RotuloCampo('MARCA / BRAND'),
                const SizedBox(height: 7),
                SeletorDropdown(
                  value: widget.brand,
                  items: const ['Fastback', 'Pulse', 'Toro', 'Compass'],
                  onChanged: (v) =>
                      widget.onVehicleChanged(v, widget.model, widget.year),
                ),
                const SizedBox(height: 14),
                const RotuloCampo('MODELO / MODEL'),
                const SizedBox(height: 7),
                SeletorDropdown(
                  value: widget.model,
                  items: const ['Impétus', 'Limited', 'Audace', 'Longitude'],
                  onChanged: (v) =>
                      widget.onVehicleChanged(widget.brand, v, widget.year),
                ),
                const SizedBox(height: 14),
                const RotuloCampo('ANO FABRICAÇÃO'),
                const SizedBox(height: 7),
                SeletorDropdown(
                  value: widget.year,
                  items: const ['2026', '2025', '2024', '2023'],
                  onChanged: (v) =>
                      widget.onVehicleChanged(widget.brand, widget.model, v),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: borderColor),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.light_mode_outlined,
                        color: CoresAplicacao.orange,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Tema',
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        widget.isDarkMode ? 'Escuro' : 'Claro',
                        style: TextStyle(
                          color: mutedColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Switch.adaptive(
                        value: widget.isDarkMode,
                        activeThumbColor: CoresAplicacao.orange,
                        onChanged: widget.onThemeChanged,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Column(
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: CoresAplicacao.orange.withValues(alpha: .06),
                          border: Border.all(
                            color: CoresAplicacao.orange.withValues(alpha: .25),
                          ),
                        ),
                        child: Icon(
                          Icons.bluetooth,
                          color: widget.connected
                              ? CoresAplicacao.green
                              : CoresAplicacao.orange,
                          size: 29,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.connected
                            ? 'Status: Conectado${widget.deviceName == null ? '' : ' • ${widget.deviceName}'}'
                            : 'Status: Desconectado',
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        widget.connected
                            ? 'ESP32 conectado por Bluetooth Low Energy'
                            : 'Ligue o ESP32 e ative o Bluetooth',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: mutedColor, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: compact ? 42 : 46,
                  child: OutlinedButton.icon(
                    onPressed: widget.onToggleRecording ?? () {},
                    icon: Icon(
                      widget.isRecording
                          ? Icons.stop_circle_outlined
                          : Icons.videocam_outlined,
                      size: 17,
                      color: widget.isRecording
                          ? CoresAplicacao.red
                          : CoresAplicacao.green,
                    ),
                    label: Text(
                      widget.isRecording ? 'PARAR LOG' : 'GRAVAR LOG',
                      style: TextStyle(
                        color: widget.isRecording
                            ? CoresAplicacao.red
                            : CoresAplicacao.green,
                        fontWeight: FontWeight.w800,
                        fontSize: compact ? 11 : 12,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: widget.isRecording
                            ? CoresAplicacao.red
                            : CoresAplicacao.green,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      backgroundColor: widget.isRecording
                          ? CoresAplicacao.red.withValues(alpha: .04)
                          : CoresAplicacao.green.withValues(alpha: .04),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: compact ? 42 : 46,
                  child: OutlinedButton.icon(
                    onPressed: widget.isConnecting ? null : widget.onConnect,
                    icon: Icon(
                      widget.isConnecting
                          ? Icons.bluetooth_searching
                          : Icons.bluetooth,
                      size: 17,
                      color: widget.connected
                          ? CoresAplicacao.green
                          : CoresAplicacao.yellow,
                    ),
                    label: Text(
                      widget.isConnecting
                          ? 'CONECTANDO AO ESP32...'
                          : widget.connected
                          ? 'DESCONECTAR ESP32'
                          : 'CONECTAR ESP32 VIA BLE',
                      style: TextStyle(
                        color: widget.connected
                            ? CoresAplicacao.green
                            : CoresAplicacao.yellow,
                        fontWeight: FontWeight.w800,
                        fontSize: compact ? 10.5 : 12,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: widget.connected
                            ? CoresAplicacao.green
                            : CoresAplicacao.yellow,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      backgroundColor: widget.connected
                          ? CoresAplicacao.green.withValues(alpha: .04)
                          : CoresAplicacao.yellow.withValues(alpha: .04),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class RotuloCampo extends StatelessWidget {
  final String text;
  const RotuloCampo(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Text(
      text,
      style: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: 9,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class SeletorDropdown extends StatelessWidget {
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;

  const SeletorDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final surfaceColor = isLight
        ? CoresAplicacao.lightSurface
        : CoresAplicacao.surface;
    final surfaceColor2 = isLight
        ? CoresAplicacao.lightSurface2
        : CoresAplicacao.surface2;
    final borderColor = isLight
        ? CoresAplicacao.lightBorder
        : CoresAplicacao.border;
    final textColor = isLight ? CoresAplicacao.lightText : CoresAplicacao.text;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: surfaceColor2,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            color: CoresAplicacao.orange,
            size: 20,
          ),
          style: TextStyle(color: textColor, fontSize: 12),
          items: items
              .map(
                (item) => DropdownMenuItem(
                  value: item,
                  child: Text(item, style: TextStyle(color: textColor)),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ),
    );
  }
}

class PaginaTelemetria extends StatefulWidget {
  final bool connected;
  final String brand;
  final String model;
  final String year;
  final bool isDarkMode;
  final bool isRecording;
  final int recordingSeconds;
  final Esp32Telemetry? telemetry;
  final VoidCallback onOpenLogs;
  final void Function(EntradaLog log) onLogRecorded;
  final VoidCallback? onToggleRecording;
  final void Function(bool isRecording, int sessionSeconds)?
  onRecordingStateChanged;

  const PaginaTelemetria({
    super.key,
    required this.connected,
    required this.brand,
    required this.model,
    required this.year,
    required this.isDarkMode,
    this.isRecording = false,
    this.recordingSeconds = 0,
    this.telemetry,
    required this.onOpenLogs,
    required this.onLogRecorded,
    this.onToggleRecording,
    this.onRecordingStateChanged,
  });

  @override
  State<PaginaTelemetria> createState() => _PaginaTelemetriaState();
}

class _PaginaTelemetriaState extends State<PaginaTelemetria> {
  bool isRecording = false;
  int sessionSeconds = 0;
  Timer? _sessionTimer;
  double speedValue = 138;
  double rpmValue = 5400;
  double odometerValue = 14285;
  double waterTempValue = 94;
  double batteryValue = 14.2;

  String _formatSession(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String get formattedSession => _formatSession(sessionSeconds);

  void _alternarGravacao() {
    if (widget.onToggleRecording != null) {
      widget.onToggleRecording!.call();
      return;
    }

    if (isRecording) {
      _sessionTimer?.cancel();
      _sessionTimer = null;
      setState(() {
        isRecording = false;
        speedValue = 138;
        rpmValue = 5400;
        odometerValue = 14285;
        waterTempValue = 94;
        batteryValue = 14.2;
      });
      widget.onRecordingStateChanged?.call(false, sessionSeconds);
      widget.onLogRecorded(_criarEntradaLog());
      return;
    }

    setState(() {
      sessionSeconds = 0;
      isRecording = true;
      speedValue = 0;
      rpmValue = 0;
      odometerValue = 0;
      waterTempValue = 0;
      batteryValue = 0;
    });
    widget.onRecordingStateChanged?.call(true, sessionSeconds);

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        sessionSeconds += 1;
      });
      widget.onRecordingStateChanged?.call(true, sessionSeconds);
    });
  }

  @override
  void didUpdateWidget(covariant PaginaTelemetria oldWidget) {
    super.didUpdateWidget(oldWidget);

    final recordingChanged = oldWidget.isRecording != widget.isRecording;
    final secondsChanged =
        oldWidget.recordingSeconds != widget.recordingSeconds;

    if (recordingChanged || secondsChanged) {
      setState(() {
        isRecording = widget.isRecording;
        sessionSeconds = widget.recordingSeconds;

        if (widget.isRecording) {
          speedValue = 0;
          rpmValue = 0;
          odometerValue = 0;
          waterTempValue = 0;
          batteryValue = 0;
        } else {
          speedValue = 138;
          rpmValue = 5400;
          odometerValue = 14285;
          waterTempValue = 94;
          batteryValue = 14.2;
        }
      });
    }
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    super.dispose();
  }

  EntradaLog _criarEntradaLog() {
    final now = DateTime.now().toLocal();
    final formattedTime =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} • ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    return EntradaLog(
      vehicle: '${widget.brand} ${widget.model}',
      durationSeconds: sessionSeconds,
      timestamp: formattedTime,
      summary: widget.connected
          ? 'Sessão gravada com telemetria BLE ativa'
          : 'Sessão gravada sem conexão BLE',
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = !widget.isDarkMode;
    final panelColor = isLight
        ? CoresAplicacao.lightSurface
        : CoresAplicacao.surface;
    final panelColor2 = isLight
        ? CoresAplicacao.lightSurface2
        : CoresAplicacao.surface2;
    final borderColor = isLight
        ? CoresAplicacao.lightBorder
        : CoresAplicacao.border;
    final textColor = isLight ? CoresAplicacao.lightText : CoresAplicacao.text;
    final mutedColor = isLight
        ? CoresAplicacao.lightMuted
        : CoresAplicacao.muted;
    final vehicleLabel = '${widget.brand} ${widget.model}';
    final recordingActive = widget.onToggleRecording != null
        ? widget.isRecording
        : isRecording;
    final effectiveSessionSeconds = widget.onToggleRecording != null
        ? widget.recordingSeconds
        : sessionSeconds;
    final accentColor = recordingActive
        ? CoresAplicacao.red
        : CoresAplicacao.green;
    final buttonText = recordingActive ? 'PARAR' : 'INICIAR';
    final displayedSpeed = widget.connected
        ? widget.telemetry?.speedKmh ?? 0
        : speedValue;
    final displayedRpm = widget.connected
        ? widget.telemetry?.rpm ?? 0
        : rpmValue;
    final displayedOdometer = widget.connected
        ? widget.telemetry?.odometerKm ?? 0
        : odometerValue;
    final displayedCoolantTemp = widget.connected
        ? widget.telemetry?.coolantTempC ?? 0
        : waterTempValue;
    final displayedBattery = widget.connected
        ? widget.telemetry?.batteryVoltage ?? 0
        : batteryValue;
    final speedProgress = widget.connected
        ? (displayedSpeed / 180).clamp(0.0, 1.0)
        : recordingActive
        ? 0.0
        : 0.78;
    final rpmProgress = widget.connected
        ? (displayedRpm / 8000).clamp(0.0, 1.0)
        : recordingActive
        ? 0.0
        : 0.67;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 360;
        final horizontalPadding = compact ? 14.0 : 20.0;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            12,
            horizontalPadding,
            18,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: compact ? double.infinity : 420,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CabecalhoPagina(
                  title: 'Telemetria',
                  subtitle: widget.connected
                      ? '$vehicleLabel • ESP32 BLE conectado • ${widget.year}'
                      : '$vehicleLabel • ESP32 BLE desconectado • ${widget.year}',
                  badge: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        onPressed: widget.onOpenLogs,
                        icon: const Icon(Icons.list_alt_outlined, size: 14),
                        label: const Text(
                          'LOGS',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: isLight
                              ? CoresAplicacao.primaryBlue
                              : CoresAplicacao.orange,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SeloStatus(
                        text: widget.connected ? 'BLE OK' : 'BLE OFF',
                        color: widget.connected
                            ? CoresAplicacao.blue
                            : CoresAplicacao.red,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: CartaoMedidor(
                        label: 'VELOCIDADE',
                        value: displayedSpeed,
                        unit: 'KM/H',
                        color: CoresAplicacao.orange,
                        progress: speedProgress,
                        isDarkMode: widget.isDarkMode,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: CartaoMedidor(
                        label: 'RPM MOTOR',
                        value: displayedRpm,
                        unit: 'RPM',
                        color: CoresAplicacao.yellow,
                        progress: rpmProgress,
                        isDarkMode: widget.isDarkMode,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: panelColor,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: borderColor),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'HODÔMETRO TOTAL',
                          style: TextStyle(
                            color: mutedColor,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextoNumericoAnimado(
                        value: displayedOdometer,
                        decimals: 0,
                        style: TextStyle(
                          color: isLight
                              ? CoresAplicacao.primaryBlue
                              : CoresAplicacao.yellow,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                        formatter: (value) =>
                            '${value.toInt().toString().padLeft(6, '0')} km',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: CartaoMetrica(
                        title: 'TEMPERATURA ÁGUA',
                        value: displayedCoolantTemp,
                        unit: '°C',
                        isDarkMode: widget.isDarkMode,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: CartaoMetrica(
                        title: 'VOLTAGEM BATERIA',
                        value: displayedBattery,
                        unit: 'V',
                        isDarkMode: widget.isDarkMode,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: panelColor2,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: borderColor),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: accentColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Gravação de Logs',
                              style: TextStyle(
                                color: textColor,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Sessão: ${_formatSession(effectiveSessionSeconds)}',
                              style: TextStyle(color: mutedColor, fontSize: 9),
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _alternarGravacao,
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: accentColor),
                          foregroundColor: accentColor,
                          padding: const EdgeInsets.symmetric(horizontal: 13),
                          minimumSize: const Size(60, 34),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                        child: Text(
                          buttonText,
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class TextoNumericoAnimado extends StatefulWidget {
  final double value;
  final int decimals;
  final TextStyle style;
  final String Function(double value)? formatter;

  const TextoNumericoAnimado({
    super.key,
    required this.value,
    this.decimals = 0,
    required this.style,
    this.formatter,
  });

  @override
  State<TextoNumericoAnimado> createState() => _TextoNumericoAnimadoState();
}

class _TextoNumericoAnimadoState extends State<TextoNumericoAnimado>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;

  String _formatValue(double value) {
    final text = value.toStringAsFixed(widget.decimals);
    if (widget.formatter != null) {
      return widget.formatter!(value);
    }

    if (widget.decimals == 0) {
      return text;
    }

    return text
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _animation = AlwaysStoppedAnimation(widget.value);
  }

  @override
  void didUpdateWidget(covariant TextoNumericoAnimado oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.value != widget.value) {
      _animation = Tween<double>(
        begin: oldWidget.value,
        end: widget.value,
      ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_controller);
      _controller
        ..value = 0
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        return Text(_formatValue(_animation.value), style: widget.style);
      },
    );
  }
}

class CartaoMedidor extends StatelessWidget {
  final String label;
  final double value;
  final String unit;
  final Color color;
  final double progress;
  final bool isDarkMode;

  const CartaoMedidor({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    required this.progress,
    required this.isDarkMode,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = !isDarkMode;
    final background = isLight
        ? CoresAplicacao.lightSurface
        : CoresAplicacao.surface;
    final border = isLight ? CoresAplicacao.lightBorder : CoresAplicacao.border;
    final textColor = isLight ? CoresAplicacao.lightText : CoresAplicacao.text;
    final mutedColor = isLight
        ? CoresAplicacao.lightMuted
        : CoresAplicacao.muted;
    final baseColor = isLight
        ? CoresAplicacao.lightBorder
        : const Color(0xFF242429);

    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          const SizedBox(height: 11),
          SizedBox(
            width: 95,
            height: 95,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: progress),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, animatedProgress, _) {
                return CustomPaint(
                  painter: PintorMedidor(
                    color: color,
                    progress: animatedProgress,
                    baseColor: baseColor,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextoNumericoAnimado(
                          value: value,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          unit,
                          style: TextStyle(
                            color: mutedColor,
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: mutedColor,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class PintorMedidor extends CustomPainter {
  final Color color;
  final double progress;
  final Color baseColor;

  PintorMedidor({
    required this.color,
    required this.progress,
    required this.baseColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 7;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final base = Paint()
      ..color = baseColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    final active = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, 2.35, 4.72, false, base);
    canvas.drawArc(rect, 2.35, 4.72 * progress, false, active);
  }

  @override
  bool shouldRepaint(covariant PintorMedidor oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.baseColor != baseColor;
}

class CartaoMetrica extends StatelessWidget {
  final String title;
  final double value;
  final String unit;
  final bool isDarkMode;

  const CartaoMetrica({
    super.key,
    required this.title,
    required this.value,
    required this.unit,
    required this.isDarkMode,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = !isDarkMode;
    final background = isLight
        ? CoresAplicacao.lightSurface
        : CoresAplicacao.surface;
    final borderColor = isLight
        ? CoresAplicacao.lightBorder
        : CoresAplicacao.border;
    final textColor = isLight ? CoresAplicacao.lightText : CoresAplicacao.text;
    final mutedColor = isLight
        ? CoresAplicacao.lightMuted
        : CoresAplicacao.muted;
    final decimals = unit == 'V' ? 1 : 0;

    return Container(
      height: 90,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: mutedColor,
              fontSize: 8,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TextoNumericoAnimado(
                value: value,
                decimals: decimals,
                style: TextStyle(
                  color: textColor,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  unit,
                  style: TextStyle(color: mutedColor, fontSize: 8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.circle, color: CoresAplicacao.green, size: 6),
              const SizedBox(width: 4),
              Text(
                'Sinal OBD OK',
                style: TextStyle(color: mutedColor, fontSize: 7),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PaginaRegistro extends StatelessWidget {
  const PaginaRegistro({super.key});

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).colorScheme.onSurface;

    return Center(
      child: Text('Registro', style: TextStyle(color: textColor, fontSize: 22)),
    );
  }
}

class PaginaLogs extends StatefulWidget {
  final List<EntradaLog> logs;
  final Future<List<FrameTelemetria>> Function(int logId)? onLoadFrames;
  final Future<List<FrameCan>> Function(int logId)? onLoadCanFrames;
  final Future<void> Function(EntradaLog log) onUpdateLog;
  final Future<bool> Function(EntradaLog log) onDeleteLog;

  const PaginaLogs({
    super.key,
    required this.logs,
    this.onLoadFrames,
    this.onLoadCanFrames,
    required this.onUpdateLog,
    required this.onDeleteLog,
  });

  @override
  State<PaginaLogs> createState() => _PaginaLogsState();
}

class _PaginaLogsState extends State<PaginaLogs> {
  int? selectedIndex;
  List<FrameTelemetria> _selectedFrames = const [];
  List<FrameCan> _selectedCanFrames = const [];
  bool _isLoadingFrames = false;
  String? _frameLoadError;

  @override
  void didUpdateWidget(covariant PaginaLogs oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = selectedIndex;
    if (index == null || index >= oldWidget.logs.length) return;

    final selectedLog = oldWidget.logs[index];
    final selectedId = selectedLog.id;
    final newIndex = selectedId == null
        ? widget.logs.indexOf(selectedLog)
        : widget.logs.indexWhere((log) => log.id == selectedId);
    if (newIndex >= 0) {
      selectedIndex = newIndex;
    } else {
      selectedIndex = null;
      _selectedFrames = const [];
      _selectedCanFrames = const [];
      _isLoadingFrames = false;
      _frameLoadError = null;
    }
  }

  List<Map<String, String>> get rows {
    if (widget.logs.isEmpty) {
      return const [];
    }

    return widget.logs.asMap().entries.map((entry) {
      final log = entry.value;
      final seconds = log.durationSeconds;
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      final remainingSeconds = seconds % 60;
      final time =
          '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';

      return {
        'time': time,
        'id': log.id?.toString() ?? entry.key.toString(),
        'name': log.vehicle,
        'data': log.timestamp,
      };
    }).toList();
  }

  Future<void> _abrirLog(int index) async {
    if (selectedIndex == index) {
      setState(() {
        selectedIndex = null;
        _selectedFrames = const [];
        _selectedCanFrames = const [];
        _isLoadingFrames = false;
        _frameLoadError = null;
      });
      return;
    }

    final log = widget.logs[index];
    setState(() {
      selectedIndex = index;
      _selectedFrames = const [];
      _isLoadingFrames = log.id != null &&
          (widget.onLoadFrames != null || widget.onLoadCanFrames != null);
      _frameLoadError = null;
    });

    final logId = log.id;
    final loadFrames = widget.onLoadFrames;
    final loadCanFrames = widget.onLoadCanFrames;
    if (logId == null) return;

    try {
      final frames = loadFrames == null
          ? const <FrameTelemetria>[]
          : await loadFrames(logId);
      final canFrames = loadCanFrames == null
          ? const <FrameCan>[]
          : await loadCanFrames(logId);
      if (!mounted || selectedIndex != index) return;
      setState(() {
        _selectedFrames = frames;
        _selectedCanFrames = canFrames;
        _isLoadingFrames = false;
      });
    } on Exception catch (error, stackTrace) {
      debugPrint(
        'Não foi possível carregar os frames do log: $error\n$stackTrace',
      );
      if (!mounted || selectedIndex != index) return;
      setState(() {
        _isLoadingFrames = false;
        _frameLoadError = error.toString();
      });
    }
  }

  Future<void> _editarLog(int index) async {
    final log = widget.logs[index];
    final formKey = GlobalKey<FormState>();
    final vehicleController = TextEditingController(text: log.vehicle);
    final durationController = TextEditingController(
      text: log.durationSeconds.toString(),
    );
    final timestampController = TextEditingController(text: log.timestamp);
    final summaryController = TextEditingController(text: log.summary);

    try {
      final updatedLog = await showDialog<EntradaLog>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Editar log'),
          content: SizedBox(
            width: 360,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: vehicleController,
                      decoration: const InputDecoration(labelText: 'Veículo'),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Informe o veículo.'
                          : null,
                    ),
                    TextFormField(
                      controller: durationController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Duração (segundos)',
                      ),
                      validator: (value) {
                        final seconds = int.tryParse(value ?? '');
                        return seconds == null || seconds < 0
                            ? 'Informe uma duração válida.'
                            : null;
                      },
                    ),
                    TextFormField(
                      controller: timestampController,
                      decoration: const InputDecoration(
                        labelText: 'Data e hora',
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Informe a data e hora.'
                          : null,
                    ),
                    TextFormField(
                      controller: summaryController,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(labelText: 'Resumo'),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Informe o resumo.'
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(
                  dialogContext,
                  log.copyWith(
                    vehicle: vehicleController.text.trim(),
                    durationSeconds: int.parse(durationController.text),
                    timestamp: timestampController.text.trim(),
                    summary: summaryController.text.trim(),
                  ),
                );
              },
              child: const Text('Salvar'),
            ),
          ],
        ),
      );

      if (updatedLog != null) await widget.onUpdateLog(updatedLog);
    } finally {
      vehicleController.dispose();
      durationController.dispose();
      timestampController.dispose();
      summaryController.dispose();
    }
  }

  Future<void> _confirmarExclusao(int index) async {
    final log = widget.logs[index];
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir log?'),
        content: const Text('Este log gravado será excluído permanentemente.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: CoresAplicacao.red),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );

    if (confirmou != true || !mounted) return;

    final excluido = await widget.onDeleteLog(log);
    if (!excluido) return;
    if (!mounted) return;
    if (selectedIndex == index) {
      setState(() {
        selectedIndex = null;
        _selectedFrames = const [];
        _selectedCanFrames = const [];
        _isLoadingFrames = false;
        _frameLoadError = null;
      });
    } else if (selectedIndex != null && selectedIndex! > index) {
      setState(() => selectedIndex = selectedIndex! - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final surfaceColor = isLight
        ? CoresAplicacao.lightSurface
        : CoresAplicacao.surface;
    final surfaceColor2 = isLight
        ? CoresAplicacao.lightSurface2
        : CoresAplicacao.surface2;
    final borderColor = isLight
        ? CoresAplicacao.lightBorder
        : CoresAplicacao.border;
    final textColor = isLight ? CoresAplicacao.lightText : CoresAplicacao.text;
    final mutedColor = isLight
        ? CoresAplicacao.lightMuted
        : CoresAplicacao.muted;
    final buttonColor = isLight
        ? CoresAplicacao.primaryBlue
        : CoresAplicacao.orange;
    final logRows = rows;
    final selectedRow =
        selectedIndex == null || selectedIndex! >= logRows.length
        ? null
        : logRows[selectedIndex!];
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CabecalhoPagina(
              title: 'Logs',
              subtitle: 'Visualização da sessão OBD',
              badge: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: buttonColor.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: buttonColor.withValues(alpha: .35)),
                ),
                child: Text(
                  '${logRows.length}',
                  style: TextStyle(
                    color: buttonColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 9,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (logRows.isEmpty)
              Center(
                child: Text(
                  'Nenhum log gravado ainda.',
                  style: TextStyle(color: mutedColor, fontSize: 12),
                ),
              )
            else ...[
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: surfaceColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: logRows.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: borderColor),
                  itemBuilder: (context, index) {
                    final item = logRows[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              item['name'] ?? '',
                              style: TextStyle(
                                color: textColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () => _abrirLog(index),
                            style: TextButton.styleFrom(
                              foregroundColor: buttonColor,
                            ),
                            child: const Text(
                              'Visualizar',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => _editarLog(index),
                            tooltip: 'Editar log',
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            onPressed: () => _confirmarExclusao(index),
                            tooltip: 'Excluir log',
                            color: CoresAplicacao.red,
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              if (selectedRow != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: surfaceColor2,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: borderColor),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Registro de Log',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _DetailChip(
                                label: 'Veículo',
                                value: selectedRow['name'] ?? '',
                                color: buttonColor,
                                textColor: textColor,
                              ),
                              _DetailChip(
                                label: 'Duração',
                                value: selectedRow['time'] ?? '',
                                color: isLight
                                    ? CoresAplicacao.lightSurface
                                    : CoresAplicacao.surface,
                                textColor: textColor,
                              ),
                              _DetailChip(
                                label: 'Data',
                                value: selectedRow['data'] ?? '',
                                color: isLight
                                    ? CoresAplicacao.lightSurface
                                    : CoresAplicacao.surface,
                                textColor: textColor,
                              ),
                              _DetailChip(
                                label: 'Resumo',
                                value: widget.logs[selectedIndex!].summary,
                                color: isLight
                                    ? CoresAplicacao.lightSurface
                                    : CoresAplicacao.surface,
                                textColor: textColor,
                              ),
                              _DetailChip(
                                label: 'Estado',
                                value: widget.logs[selectedIndex!].status,
                                color: isLight
                                    ? CoresAplicacao.lightSurface
                                    : CoresAplicacao.surface,
                                textColor: textColor,
                              ),
                              if (widget.logs[selectedIndex!].sourceDevice !=
                                  null)
                                _DetailChip(
                                  label: 'Dispositivo BLE',
                                  value:
                                      widget.logs[selectedIndex!].sourceDevice!,
                                  color: isLight
                                      ? CoresAplicacao.lightSurface
                                      : CoresAplicacao.surface,
                                  textColor: textColor,
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Frames de telemetria (${_selectedFrames.length})',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_isLoadingFrames)
                            const Center(child: CircularProgressIndicator())
                          else if (_frameLoadError != null)
                            Text(
                              'Não foi possível carregar os frames: $_frameLoadError',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 10,
                              ),
                            )
                          else if (_selectedFrames.isEmpty)
                            Text(
                              'Nenhum frame de telemetria foi salvo nesta gravação.',
                              style: TextStyle(color: mutedColor, fontSize: 10),
                            )
                          else
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                columnSpacing: 14,
                                horizontalMargin: 0,
                                headingRowColor: WidgetStatePropertyAll(
                                  buttonColor.withValues(alpha: .12),
                                ),
                                columns:
                                    [
                                          'Horário',
                                          'Velocidade km/h',
                                          'RPM',
                                          'Odômetro km',
                                          'Temp. °C',
                                          'Bateria V',
                                        ]
                                        .map(
                                          (label) => DataColumn(
                                            label: Text(
                                              label,
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.w800,
                                                color: textColor,
                                              ),
                                            ),
                                          ),
                                        )
                                        .toList(),
                                rows: _selectedFrames
                                    .map(
                                      (frame) => DataRow(
                                        cells:
                                            [
                                                  frame.capturedAt
                                                      .toLocal()
                                                      .toString()
                                                      .split('.')
                                                      .first,
                                                  frame.speedKmh
                                                      .toStringAsFixed(1),
                                                  frame.rpm.toStringAsFixed(0),
                                                  frame.odometerKm
                                                      .toStringAsFixed(2),
                                                  frame.coolantTempC
                                                      .toStringAsFixed(1),
                                                  frame.batteryVoltage
                                                      .toStringAsFixed(1),
                                                ]
                                                .map(
                                                  (value) => DataCell(
                                                    Text(
                                                      value,
                                                      style: TextStyle(
                                                        color: textColor,
                                                        fontSize: 9,
                                                      ),
                                                    ),
                                                  ),
                                                )
                                                .toList(),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          const SizedBox(height: 14),
                          Text(
                            'Frames CAN (${_selectedCanFrames.length})',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_selectedCanFrames.isEmpty)
                            Text(
                              'Nenhum frame CAN recebido nesta gravação.',
                              style: TextStyle(
                                color: mutedColor,
                                fontSize: 10,
                              ),
                            )
                          else
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                columnSpacing: 14,
                                horizontalMargin: 0,
                                headingRowColor: WidgetStatePropertyAll(
                                  buttonColor.withValues(alpha: .12),
                                ),
                                columns: [
                                  'Horário',
                                  'ID',
                                  'Tipo',
                                  'RTR',
                                  'DLC',
                                  'Dados (hex)',
                                ]
                                    .map(
                                      (label) => DataColumn(
                                        label: Text(
                                          label,
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            color: textColor,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                rows: _selectedCanFrames
                                    .map(
                                      (frame) => DataRow(
                                        cells: [
                                          frame.capturedAt
                                              .toLocal()
                                              .toString()
                                              .split('.')
                                              .first,
                                          frame.formattedCanId,
                                          frame.extended ? 'Estendido' : 'Padrão',
                                          frame.remoteRequest ? 'Sim' : 'Não',
                                          frame.dlc.toString(),
                                          frame.dataHex.isEmpty
                                              ? '—'
                                              : frame.dataHex,
                                        ]
                                            .map(
                                              (value) => DataCell(
                                                Text(
                                                  value,
                                                  style: TextStyle(
                                                    color: textColor,
                                                    fontSize: 9,
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final Color textColor;

  const _DetailChip({
    required this.label,
    required this.value,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: textColor.withValues(alpha: .18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: textColor.withValues(alpha: .75),
              fontSize: 8,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: textColor,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class PaginaSobre extends StatelessWidget {
  const PaginaSobre({super.key});

  Future<void> _abrirRepositorio(BuildContext context) async {
    final opened = await launchUrl(
      Uri.parse('https://github.com/EderArthur/CARNalyzer'),
      mode: LaunchMode.externalApplication,
    );

    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o repositório.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final mutedColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final surfaceColor = isLight
        ? CoresAplicacao.lightSurface
        : CoresAplicacao.surface;
    final borderColor = isLight
        ? CoresAplicacao.lightBorder
        : CoresAplicacao.border;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 45, 20, 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: borderColor),
              ),
              child: const Center(
                child: Text(
                  'C',
                  style: TextStyle(
                    color: CoresAplicacao.orange,
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'CARNalyzer',
              style: TextStyle(
                color: textColor,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'STELLANTIS TEST TOOL',
              style: TextStyle(
                color: CoresAplicacao.yellow,
                fontSize: 9,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 25),
            CartaoInformativo(
              child: Column(
                children: [
                  Text(
                    '"Monitoramento e análise de dados\nveiculares em tempo real"',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Desenvolvido sob padrões restritos de engenharia\n'
                    'automotiva para validação e testes de pista.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: mutedColor,
                      fontSize: 9,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Align(
              alignment: Alignment.centerLeft,
              child: RotuloCampo('EQUIPE TÉCNICA'),
            ),
            const SizedBox(height: 8),
            const CartaoInformativo(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  LinhaEquipe('Scrum Master', 'Eder Arthur'),
                  LinhaEquipe('Hardware', 'Lucas Bispo'),
                  LinhaEquipe('Software', 'Luiz Henrique'),
                  LinhaEquipe('Mobile Integration', 'Wagnus'),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor),
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: CoresAplicacao.orange.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(
                      Icons.account_tree_outlined,
                      color: CoresAplicacao.orange,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Repositório\ndo Projeto',
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 10,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _abrirRepositorio(context),
                    child: const Text(
                      'Acessar repositório',
                      style: TextStyle(
                        color: CoresAplicacao.orange,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CartaoInformativo extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const CartaoInformativo({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: isLight ? CoresAplicacao.lightSurface : CoresAplicacao.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: isLight ? CoresAplicacao.lightBorder : CoresAplicacao.border,
        ),
      ),
      child: child,
    );
  }
}

class LinhaEquipe extends StatelessWidget {
  final String role;
  final String name;

  const LinhaEquipe(this.role, this.name, {super.key});

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final mutedColor = Theme.of(context).colorScheme.onSurfaceVariant;

    return Container(
      height: 39,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isLight ? CoresAplicacao.lightBorder : CoresAplicacao.border,
          ),
        ),
      ),
      child: Row(
        children: [
          Text(role, style: TextStyle(color: mutedColor, fontSize: 9)),
          const Spacer(),
          Text(
            name,
            style: TextStyle(
              color: textColor,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
