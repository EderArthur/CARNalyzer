#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <string.h>

static const char *DEVICE_NAME = "CARNalyzer-ESP32";
static const char *SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static const char *COMMAND_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
static const char *TELEMETRY_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

BLEServer *server = nullptr;
BLECharacteristic *telemetryCharacteristic = nullptr;
bool deviceConnected = false;
unsigned long lastTelemetryAt = 0;
unsigned long sample = 0;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override {
    deviceConnected = true;
  }

  void onDisconnect(BLEServer *) override {
    deviceConnected = false;
    BLEDevice::startAdvertising();
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String command = String(characteristic->getValue().c_str());
    command.trim();
    Serial.print("Comando recebido: ");
    Serial.println(command);
  }
};

void notifyInChunks(const String &message) {
  const size_t chunkSize = 20;
  for (size_t offset = 0; offset < message.length(); offset += chunkSize) {
    const size_t remaining = message.length() - offset;
    const size_t length = remaining < chunkSize ? remaining : chunkSize;
    uint8_t chunk[chunkSize];
    memcpy(chunk, message.c_str() + offset, length);
    telemetryCharacteristic->setValue(chunk, length);
    telemetryCharacteristic->notify();
    delay(20);
  }
}

void setup() {
  Serial.begin(115200);
  BLEDevice::init(DEVICE_NAME);

  server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);
  BLECharacteristic *commandCharacteristic = service->createCharacteristic(
      COMMAND_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  commandCharacteristic->setCallbacks(new CommandCallbacks());

  telemetryCharacteristic = service->createCharacteristic(
      TELEMETRY_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  telemetryCharacteristic->addDescriptor(new BLE2902());

  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("CARNalyzer BLE pronto. Anuncie o dispositivo no app.");
}

void loop() {
  if (!deviceConnected || millis() - lastTelemetryAt < 1000) {
    delay(20);
    return;
  }

  lastTelemetryAt = millis();

  // Valores de demonstração. Substitua pela leitura real do adaptador OBD-II.
  const float speedKmh = 40 + (sample % 15);
  const int rpm = 1500 + ((sample * 120) % 1800);
  const float odometerKm = 14285.0 + sample / 3600.0;
  const float coolantTempC = 88 + (sample % 8);
  const float batteryVoltage = 13.8 + (sample % 5) * 0.1;
  sample++;

  String payload = "{\"speedKmh\":" + String(speedKmh, 1) +
                   ",\"rpm\":" + String(rpm) +
                   ",\"odometerKm\":" + String(odometerKm, 2) +
                   ",\"coolantTempC\":" + String(coolantTempC, 1) +
                   ",\"batteryVoltage\":" + String(batteryVoltage, 1) +
                   "}\n";
  notifyInChunks(payload);
}
