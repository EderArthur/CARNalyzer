# CARNalyzer Flutter

Interface Flutter baseada no design enviado do Figma.

## O que já está implementado

- Tema escuro semelhante ao layout original.
- Tela de Configuração/Veículo.
- Seleção de marca, modelo e ano.
- Estado conectado/desconectado do OBD.
- Tela de Telemetria.
- Indicadores de velocidade e RPM com gauges.
- Hodômetro, temperatura da água e tensão da bateria.
- Área de gravação de logs.
- Tela Sobre com equipe técnica.
- Navegação inferior.
- Layout responsivo para celular e web.
- Banco de dados SQLite local para sessões e frames de telemetria, com CRUD.
- Armazenamento de frames CAN brutos recebidos via ESP32 em cada sessão.
- Conexão BLE multiplataforma (Android e navegador) com o ESP32 DevKit V1.
- Recepção de telemetria JSON enviada pelo ESP32 para os indicadores do app.

## Banco de dados local

O documento de entrega da Sprint está em
[`docs/projeto_banco_de_dados.pdf`](docs/projeto_banco_de_dados.pdf).

O histórico de sessões é armazenado em SQLite local. Android e iOS usam
`sqflite`; Windows, Linux e macOS usam `sqflite_common_ffi`; no navegador, o
banco é executado via WebAssembly e persistido no IndexedDB por
`sqflite_common_ffi_web`. Tema e veículo selecionado continuam em
`SharedPreferences`, pois são preferências simples da interface.

Este repositório configura atualmente os destinos Android e Web. Os destinos
desktop ainda precisam do respectivo runner Flutter e da toolchain nativa
(Visual Studio com C++ no Windows).

O schema atual é a versão 3. A tabela `logs` guarda uma sessão, `log_frames`
guarda amostras da telemetria decodificada e `can_frames` guarda frames CAN
brutos. Ambas as tabelas de frames se relacionam com `logs` por `log_id`:

| Tabela | Campos principais |
| --- | --- |
| `logs` | `id`, `vehicle`, `duration_seconds`, `timestamp`, `summary`, `status`, `source_device` |
| `log_frames` | `id`, `log_id`, `captured_at`, `speed_kmh`, `rpm`, `odometer_km`, `coolant_temp_c`, `battery_voltage`, `raw_payload` |
| `can_frames` | `id`, `log_id`, `captured_at`, `can_id`, `extended`, `remote_request`, `dlc`, `data_hex`, `device_timestamp_ms`, `raw_payload` |

Ao iniciar uma gravação, o app cria uma sessão com status `recording`. Cada
pacote JSON de telemetria válido ou frame CAN recebido do ESP32 durante a
gravação é persistido com horário UTC e payload original. Ao parar, a sessão é
finalizada com duração e resumo. Se o app for fechado antes, a sessão é marcada
`interrupted` na próxima inicialização. Registros antigos são preservados pela
migração automática do schema v1/v2 para v3; os históricos que estavam no
`SharedPreferences` também são importados.

A tela **Logs** abre a sessão e mostra os frames de telemetria e frames CAN em
tabelas separadas. Para consultar os dados com SQL em uma cópia do arquivo
SQLite:

```sql
SELECT id, vehicle, timestamp, duration_seconds, status, source_device, summary
FROM logs
ORDER BY id DESC;
```

```sql
SELECT f.captured_at, l.vehicle, f.speed_kmh, f.rpm, f.odometer_km,
       f.coolant_temp_c, f.battery_voltage, f.raw_payload
FROM log_frames AS f
JOIN logs AS l ON l.id = f.log_id
WHERE l.id = 1
ORDER BY f.captured_at;
```

Consulta dos frames CAN recebidos em uma sessão:

```sql
SELECT captured_at, printf('0x%X', can_id) AS can_id, extended,
       remote_request, dlc, data_hex, device_timestamp_ms, raw_payload
FROM can_frames
WHERE log_id = 1
ORDER BY captured_at;
```

No Android, o arquivo é `carnalyzer.db` na pasta privada de bancos de dados
do app (`data/data/com.example.carnalyzer/databases/`). Copie-o pelo Device
Explorer do Android Studio e abra a cópia com DB Browser for SQLite. No Web,
o SQLite usa IndexedDB do navegador, não um arquivo `.db` diretamente
acessível.

Para reconstruir os arquivos de suporte do SQLite Web após atualizar os
pacotes:

```bash
dart run sqflite_common_ffi_web:setup
```

O comando atualiza `web/sqlite3.wasm` e `web/sqflite_sw.js`.

Testes do repositório:

```bash
flutter test test/banco_dados_local_test.dart
```

## Executar

```bash
flutter pub get
flutter run -d chrome
```

Para executar em um dispositivo Android conectado:

```bash
flutter devices
flutter run -d <device-id>
```

## Conexão BLE com ESP32

O app usa BLE GATT com um serviço no formato UART, compatível com Android e
Web Bluetooth. Um firmware inicial para ESP32 DevKit V1 está em
[`examples/esp32_can_ble_carnalyzer/esp32_can_ble_carnalyzer.ino`](examples/esp32_can_ble_carnalyzer/esp32_can_ble_carnalyzer.ino).

Abra essa pasta no Arduino IDE como sketch, selecione a placa ESP32 Dev Module
e configure no início do arquivo `CAN_TX_GPIO`, `CAN_RX_GPIO` e `CAN_BITRATE`
de acordo com o seu módulo e rede. O ESP32 precisa de um transceiver CAN físico
entre seus pinos TWAI e CAN_H/CAN_L; o controlador integrado do DevKit não se
liga diretamente ao barramento do veículo.

O sketch inicia o TWAI em modo `LISTEN_ONLY`, lê frames continuamente no
`loop()` e imprime ID, tipo, RTR, DLC e bytes no Serial Monitor. Quando o app
está conectado, envia cada frame como JSON pela característica BLE existente;
o app recompõe as notificações fragmentadas, associa o frame à gravação ativa
e o salva em `can_frames`. A tela **Logs > Visualizar** exibe ID, tipo, RTR,
DLC, bytes e horário.

Cada linha JSON usa `type: "can_frame"`, `timestampMs`, `id`, `extended`,
`rtr`, `dlc` e `data` (bytes em hexadecimal). `timestampMs` é o contador de
milissegundos desde o boot do ESP32; `captured_at` no app é o horário UTC de
recepção. O frame só é persistido no banco enquanto uma gravação estiver
ativa no app.

O modo somente escuta evita que este sketch transmita mensagens CAN ao veículo.
Os pinos indicados são apenas valores iniciais configuráveis, e o bitrate
padrão de 500 kbit/s deve ser ajustado à rede CAN que será monitorada. A
serialização JSON e o envio BLE são uma estrutura inicial de demonstração; em
barramentos com alta taxa de frames, pode ser necessário filtrar IDs ou
implementar uma transmissão binária/agrupada para evitar perda por limite de
throughput BLE.

Android solicita as permissões BLE em tempo de execução. No navegador, use
Chrome ou outro navegador com Web Bluetooth em contexto seguro (por exemplo,
`localhost`); o navegador abrirá seu seletor de dispositivos. A conexão física
depende de Bluetooth disponível e do firmware instalado no ESP32.

Esta etapa implementa descoberta, conexão, notificações e envio de comandos
pela característica BLE. A integração com adaptador OBD-II/CAN, leitura real
dos sensores, DTCs e gráficos históricos permanece como evolução futura.

A arquitetura pode ser evoluída para `screens`, `widgets`, `services`, `models` e `repositories` conforme a comunicação real for implementada.
