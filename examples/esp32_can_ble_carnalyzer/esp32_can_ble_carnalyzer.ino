#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <driver/twai.h>

// Configure these values for the ESP32 board, CAN transceiver and bus.
#define CAN_TX_GPIO GPIO_NUM_5
#define CAN_RX_GPIO GPIO_NUM_4
#define CAN_BITRATE 500000UL

static const char *DEVICE_NAME = "CARNalyzer-ESP32";
static const char *SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static const char *COMMAND_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
static const char *CAN_FRAME_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
static const size_t BLE_CHUNK_SIZE = 20;
static const uint32_t BLE_CHUNK_DELAY_MS = 5;
static const uint32_t CAN_RX_QUEUE_LENGTH = 64;

BLEServer *bleServer = nullptr;
BLECharacteristic *canFrameCharacteristic = nullptr;
volatile bool deviceConnected = false;

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
    const String command = String(characteristic->getValue().c_str());
    Serial.print("BLE command received: ");
    Serial.println(command);
  }
};

twai_timing_config_t canTimingConfig() {
#if CAN_BITRATE == 1000000UL
  return TWAI_TIMING_CONFIG_1MBITS();
#elif CAN_BITRATE == 800000UL
  return TWAI_TIMING_CONFIG_800KBITS();
#elif CAN_BITRATE == 500000UL
  return TWAI_TIMING_CONFIG_500KBITS();
#elif CAN_BITRATE == 250000UL
  return TWAI_TIMING_CONFIG_250KBITS();
#elif CAN_BITRATE == 125000UL
  return TWAI_TIMING_CONFIG_125KBITS();
#else
#error "Unsupported CAN_BITRATE. Add the matching TWAI timing configuration."
#endif
}

void startCanReceiver() {
  twai_general_config_t generalConfig =
      TWAI_GENERAL_CONFIG_DEFAULT(CAN_TX_GPIO, CAN_RX_GPIO,
                                  TWAI_MODE_LISTEN_ONLY);
  generalConfig.rx_queue_len = CAN_RX_QUEUE_LENGTH;
  const twai_timing_config_t timingConfig = canTimingConfig();
  const twai_filter_config_t filterConfig = TWAI_FILTER_CONFIG_ACCEPT_ALL();

  esp_err_t result =
      twai_driver_install(&generalConfig, &timingConfig, &filterConfig);
  if (result != ESP_OK) {
    Serial.printf("TWAI driver install failed: %s\n", esp_err_to_name(result));
    while (true) delay(1000);
  }

  result = twai_start();
  if (result != ESP_OK) {
    Serial.printf("TWAI start failed: %s\n", esp_err_to_name(result));
    while (true) delay(1000);
  }

  Serial.printf("CAN listener ready at %lu bit/s (listen-only mode)\n",
                static_cast<unsigned long>(CAN_BITRATE));
}

void startBleServer() {
  BLEDevice::init(DEVICE_NAME);
  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService *service = bleServer->createService(SERVICE_UUID);
  BLECharacteristic *commandCharacteristic = service->createCharacteristic(
      COMMAND_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  commandCharacteristic->setCallbacks(new CommandCallbacks());

  canFrameCharacteristic = service->createCharacteristic(
      CAN_FRAME_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  canFrameCharacteristic->addDescriptor(new BLE2902());

  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("BLE ready: connect to CARNalyzer-ESP32");
}

String frameToJson(const twai_message_t &frame) {
  String dataHex;
  if (!frame.rtr) {
    for (uint8_t index = 0; index < frame.data_length_code; index++) {
      if (frame.data[index] < 0x10) dataHex += '0';
      dataHex += String(frame.data[index], HEX);
    }
    dataHex.toUpperCase();
  }

  String payload = "{\"type\":\"can_frame\",\"timestampMs\":";
  payload += String(millis());
  payload += ",\"id\":";
  payload += String(frame.identifier);
  payload += ",\"extended\":";
  payload += frame.extd ? "true" : "false";
  payload += ",\"rtr\":";
  payload += frame.rtr ? "true" : "false";
  payload += ",\"dlc\":";
  payload += String(frame.data_length_code);
  payload += ",\"data\":\"";
  payload += dataHex;
  payload += "\"}";
  return payload;
}

void sendFrameOverBle(const String &payload) {
  if (!deviceConnected) return;

  for (size_t offset = 0; offset < payload.length();
       offset += BLE_CHUNK_SIZE) {
    if (!deviceConnected) return;

    const size_t remaining = payload.length() - offset;
    const size_t chunkLength =
        remaining < BLE_CHUNK_SIZE ? remaining : BLE_CHUNK_SIZE;
    canFrameCharacteristic->setValue(
        reinterpret_cast<const uint8_t *>(payload.c_str() + offset),
        chunkLength);
    canFrameCharacteristic->notify();
    delay(BLE_CHUNK_DELAY_MS);
  }

  const uint8_t newline = '\n';
  canFrameCharacteristic->setValue(&newline, 1);
  canFrameCharacteristic->notify();
}

void printFrameToSerial(const twai_message_t &frame, const String &payload) {
  Serial.printf("CAN ID=0x%lX %s RTR=%u DLC=%u DATA=",
                static_cast<unsigned long>(frame.identifier),
                frame.extd ? "EXT" : "STD", frame.rtr ? 1 : 0,
                frame.data_length_code);
  if (frame.rtr) {
    Serial.print("<remote request>");
  } else {
    for (uint8_t index = 0; index < frame.data_length_code; index++) {
      Serial.printf("%02X", frame.data[index]);
      if (index + 1 < frame.data_length_code) Serial.print(' ');
    }
  }
  Serial.println();

  if (deviceConnected) sendFrameOverBle(payload);
}

void setup() {
  Serial.begin(115200);
  startCanReceiver();
  startBleServer();
}

void loop() {
  twai_message_t frame = {};
  if (twai_receive(&frame, pdMS_TO_TICKS(50)) != ESP_OK) return;

  const String payload = frameToJson(frame);
  printFrameToSerial(frame, payload);
}
