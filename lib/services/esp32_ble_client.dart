import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

class Esp32BleClient {
  static const serviceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const telemetryCharacteristicUuid =
      '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
  static const commandCharacteristicUuid =
      '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';

  String? _connectedDeviceId;

  Stream<BleDevice> get scanResults => UniversalBle.scanStream;

  Stream<bool> connectionChanges(String deviceId) =>
      UniversalBle.connectionStream(deviceId);

  Future<void> startScan() async {
    if (!kIsWeb) {
      await UniversalBle.requestPermissions();
    }

    if (!kIsWeb) {
      final availability = await UniversalBle.getBluetoothAvailabilityState();
      if (availability != AvailabilityState.poweredOn) {
        throw StateError('Ative o Bluetooth para buscar o ESP32.');
      }
    }

    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [serviceUuid]),
      skipDuplicates: true,
    );
  }

  Future<void> stopScan() => UniversalBle.stopScan();

  Future<void> connect(BleDevice device) async {
    await UniversalBle.connect(
      device.deviceId,
      timeout: const Duration(seconds: 20),
    );

    try {
      final services = await UniversalBle.discoverServices(device.deviceId);
      BleService? service;
      for (final candidate in services) {
        if (BleUuidParser.compareStrings(candidate.uuid, serviceUuid)) {
          service = candidate;
          break;
        }
      }
      if (service == null) {
        throw StateError('O serviço BLE esperado não foi encontrado no ESP32.');
      }

      BleCharacteristic? telemetryCharacteristic;
      BleCharacteristic? commandCharacteristic;
      for (final candidate in service.characteristics) {
        if (BleUuidParser.compareStrings(
          candidate.uuid,
          telemetryCharacteristicUuid,
        )) {
          telemetryCharacteristic = candidate;
        } else if (BleUuidParser.compareStrings(
          candidate.uuid,
          commandCharacteristicUuid,
        )) {
          commandCharacteristic = candidate;
        }
      }
      if (telemetryCharacteristic == null ||
          commandCharacteristic == null) {
        throw StateError(
          'As características de telemetria e comando não foram encontradas.',
        );
      }
      if (!telemetryCharacteristic.properties
          .contains(CharacteristicProperty.notify)) {
        throw StateError(
          'A característica de telemetria do ESP32 não aceita notificações.',
        );
      }

      await UniversalBle.subscribeNotifications(
        device.deviceId,
        serviceUuid,
        telemetryCharacteristicUuid,
      );
      _connectedDeviceId = device.deviceId;
    } catch (_) {
      await UniversalBle.disconnect(device.deviceId);
      rethrow;
    }
  }

  Stream<Uint8List> telemetryStream(String deviceId) =>
      UniversalBle.characteristicValueStream(
        deviceId,
        telemetryCharacteristicUuid,
      );

  Future<void> sendCommand(String command) async {
    final deviceId = _connectedDeviceId;
    if (deviceId == null) {
      throw StateError('Conecte-se ao ESP32 antes de enviar um comando.');
    }

    await UniversalBle.write(
      deviceId,
      serviceUuid,
      commandCharacteristicUuid,
      Uint8List.fromList(utf8.encode('$command\n')),
    );
  }

  Future<void> disconnect() async {
    final deviceId = _connectedDeviceId;
    if (deviceId == null) return;

    await UniversalBle.disconnect(deviceId);
    _connectedDeviceId = null;
  }
}
