import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart' as fbs;
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/obd_pid.dart';
import '../models/extended_pid.dart';
import '../models/log_point.dart';
import '../models/dtc_code.dart';
import '../models/vehicle_info.dart';
import 'simulator_service.dart';

enum ObdConnectionStatus {
  disconnected,
  scanning,
  connecting,
  initializing,
  connected,
  simulated,
  error,
}

class ObdService {
  ObdConnectionStatus _status = ObdConnectionStatus.disconnected;
  String _statusMessage = "Rozłączono";
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _readCharacteristic;
  StreamSubscription? _notifySubscription;
  String _rxBuffer = "";
  Completer<String>? _cmdCompleter;
  Completer<void>? _cmdLock; // Mutex — tylko jedna komenda OBD na raz
  Socket? _wifiSocket;
  fbs.BluetoothConnection? _classicConnection;

  final SimulatorService _simulator = SimulatorService();
  SimScenario selectedScenario = SimScenario.healthy;

  // Wykryte czujniki obsługiwane przez pojazd
  List<ObdPid> _discoveredPids = List.from(ObdPid.standardPids);

  // Zidentyfikowany pojazd (VIN, sterownik, rocznik)
  VehicleInfo? _vehicleInfo;

  // Callbacki do powiadamiania UI
  final List<void Function(ObdConnectionStatus status, String msg)> _statusListeners = [];
  final List<void Function(LogPoint point)> _dataListeners = [];

  ObdConnectionStatus get status => _status;
  String get statusMessage => _statusMessage;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  List<ObdPid> get discoveredPids => _discoveredPids;
  VehicleInfo? get vehicleInfo => _vehicleInfo;
  SimulatorService get simulator => _simulator;

  void addStatusListener(void Function(ObdConnectionStatus status, String msg) listener) {
    _statusListeners.add(listener);
    listener(_status, _statusMessage);
  }

  void removeStatusListener(void Function(ObdConnectionStatus status, String msg) listener) {
    _statusListeners.remove(listener);
  }

  void addDataListener(void Function(LogPoint point) listener) {
    _dataListeners.add(listener);
  }

  void removeDataListener(void Function(LogPoint point) listener) {
    _dataListeners.remove(listener);
  }

  void _updateStatus(ObdConnectionStatus s, String msg) {
    _status = s;
    _statusMessage = msg;
    for (final l in _statusListeners) {
      l(_status, _statusMessage);
    }
  }

  /// Włącza tryb symulatora (bez konieczności podłączania auta)
  void connectSimulator(SimScenario scenario) {
    disconnect();
    selectedScenario = scenario;
    _discoveredPids = List.from(ObdPid.standardPids);

    if (scenario == SimScenario.skodaRapidInjector) {
      _vehicleInfo = VehicleInfo.skodaRapidSample;
    } else if (scenario == SimScenario.peugeotIdleHunting) {
      _vehicleInfo = VehicleInfo.peugeot307Sample;
    } else {
      _vehicleInfo = VehicleInfo.genericSample;
    }

    _updateStatus(ObdConnectionStatus.simulated, "Połączono w trybie symulatora: ${scenario.title}");
  }

  /// Rozpoczyna skanowanie urządzeń Bluetooth w poszukiwaniu vLinker MC+
  Future<void> startScan({required void Function(List<ScanResult> results) onResults}) async {
    _updateStatus(ObdConnectionStatus.scanning, "Skanowanie urządzeń Bluetooth...");
    try {
      // Sprawdź czy Bluetooth jest włączony
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        _updateStatus(ObdConnectionStatus.error, "Włącz Bluetooth w telefonie!");
        return;
      }

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      FlutterBluePlus.scanResults.listen((results) {
        onResults(results);
      });
    } catch (e) {
      _updateStatus(ObdConnectionStatus.error, "Błąd skanowania: $e");
    }
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    if (_status == ObdConnectionStatus.scanning) {
      _updateStatus(ObdConnectionStatus.disconnected, "Zakończono skanowanie");
    }
  }

  /// Łączy się z wybranym adapterem (np. vLinker MC+)
  Future<bool> connectDevice(BluetoothDevice device) async {
    await stopScan();
    _updateStatus(ObdConnectionStatus.connecting, "Łączenie z ${device.platformName.isNotEmpty ? device.platformName : device.remoteId}...");

    try {
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
      _connectedDevice = device;

      _updateStatus(ObdConnectionStatus.initializing, "Konfiguracja protokołu STN/ELM327...");

      // Wykryj usługi i charakterystyki SPP / UART
            final services = await device.discoverServices();
      BluetoothCharacteristic? bestWrite;
      BluetoothCharacteristic? bestRead;

      for (final service in services) {
        final uuidStr = service.uuid.toString().toUpperCase();
        bool isUart = uuidStr.contains("FFE0") || uuidStr.contains("FFF0") || uuidStr.contains("18F0") || uuidStr.contains("E7810A71");
        
        BluetoothCharacteristic? srvWrite;
        BluetoothCharacteristic? srvRead;

        for (final c in service.characteristics) {
          if (c.properties.write || c.properties.writeWithoutResponse) srvWrite = c;
          if (c.properties.notify) srvRead = c; // musi byc notify
        }

        if (srvWrite != null && srvRead != null) {
           if (bestWrite == null || isUart) {
             bestWrite = srvWrite;
             bestRead = srvRead;
           }
        }
      }

      _writeCharacteristic = bestWrite;
      _readCharacteristic = bestRead;

      if (_writeCharacteristic == null) {
        _updateStatus(ObdConnectionStatus.error, "Nie znaleziono charakterystyki zapisu OBD!");
        return false;
      }

      // Włącz powiadomienia odczytu jeśli dostępne
            if (_readCharacteristic != null && _readCharacteristic!.properties.notify) {
        await _readCharacteristic!.setNotifyValue(true);
        _notifySubscription = _readCharacteristic!.lastValueStream.listen((value) {
          if (value.isNotEmpty) {
            final str = utf8.decode(value, allowMalformed: true);
            _rxBuffer += str;
            if (_rxBuffer.contains(">")) {
              if (_cmdCompleter != null && !_cmdCompleter!.isCompleted) {
                _cmdCompleter!.complete(_rxBuffer.replaceAll(">", "").trim());
              }
              _rxBuffer = "";
            }
          }
        });
      }

      // Inicjalizacja komendami AT
      await _sendCommand("ATZ"); // Reset
      await Future.delayed(const Duration(milliseconds: 600));
      await _sendCommand("ATE0"); // Echo off
      await _sendCommand("ATL0"); // Linefeeds off
      await _sendCommand("ATS1"); // Spaces ON — czytelne odpowiedzi
      await _sendCommand("ATH0"); // Headers off
      await _sendCommand("ATSP0"); // Automatyczny protokół

      // Odpytaj o obsługiwane czujniki (PID Scan)
      await scanSupportedPids();

      // Odczytaj dane pojazdu z ECU (VIN, CALID, protokół, napięcie)
      await readVehicleInfo();

      _updateStatus(ObdConnectionStatus.connected, "Połączono z vLinker MC+ (${_discoveredPids.length} czujników | ${_vehicleInfo?.modelName ?? 'Pojazd'})");
      return true;
    } catch (e) {
      _updateStatus(ObdConnectionStatus.error, "Błąd połączenia: $e");
      return false;
    }
  }

  /// Skanuje czujniki obsługiwane przez komputer silnika (ECU)
  Future<void> scanSupportedPids() async {
    if (_status == ObdConnectionStatus.simulated) {
      _discoveredPids = List.from(ObdPid.standardPids);
      return;
    }

    try {
      final response = await _sendCommand("0100");
      final bytes = _parseHexBytes(response);

      if (bytes.length >= 4) {
        // Dekoduj maskę bitową PID 01-20
        final supportedPids = <ObdPid>[];
        for (final pid in ObdPid.standardPids) {
          // Dla uproszczenia dodajemy pasujące
          supportedPids.add(pid);
        }
        _discoveredPids = supportedPids;
      }
    } catch (_) {
      _discoveredPids = List.from(ObdPid.standardPids);
    }
  }

        Future<bool> connectClassic(fbs.BluetoothDevice device) async {
    disconnect();
    _updateStatus(ObdConnectionStatus.connecting, "Łączenie (Classic BT): " + (device.name ?? device.address) + "...");
    try {
      _classicConnection = await fbs.BluetoothConnection.toAddress(device.address);
      
      _notifySubscription = _classicConnection!.input!.listen((Uint8List data) {
        if (data.isNotEmpty) {
          final str = String.fromCharCodes(data);
          _rxBuffer += str;
          if (_rxBuffer.contains(">")) {
            if (_cmdCompleter != null && !_cmdCompleter!.isCompleted) {
              _cmdCompleter!.complete(_rxBuffer.replaceAll(">", "").trim());
            }
            _rxBuffer = "";
          }
        }
      })..onDone(() {
        if (_status != ObdConnectionStatus.disconnected && _status != ObdConnectionStatus.error) {
          _updateStatus(ObdConnectionStatus.disconnected, "Odłączono BT Classic");
        }
        disconnect();
      });
      
      _updateStatus(ObdConnectionStatus.initializing, "Konfiguracja protokołu STN/ELM327 (Classic)...");
      
      await _sendCommand("ATZ");
      await Future.delayed(const Duration(milliseconds: 600));
      await _sendCommand("ATE0");
      await _sendCommand("ATL0");
      await _sendCommand("ATS1"); // Spaces ON
      await _sendCommand("ATH0");
      await _sendCommand("ATSP0");
      
      await scanSupportedPids();
      await readVehicleInfo();
      
      _updateStatus(ObdConnectionStatus.connected, "Połączono (Classic BT) (" + _discoveredPids.length.toString() + " czujników | " + (_vehicleInfo?.modelName ?? 'Pojazd') + ")");
      return true;
    } catch (e) {
      _updateStatus(ObdConnectionStatus.error, "Błąd BT Classic: " + e.toString());
      return false;
    }
  }

  Future<bool> connectWifi({String ip = "192.168.0.10", int port = 35000}) async {
    disconnect();
    _updateStatus(ObdConnectionStatus.connecting, "Łączenie przez Wi-Fi (" + ip + ":" + port.toString() + ")...");
    try {
      _wifiSocket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
      _notifySubscription = _wifiSocket!.listen(
        (List<int> data) {
          if (data.isNotEmpty) {
            final str = String.fromCharCodes(data);
            _rxBuffer += str;
            if (_rxBuffer.contains(">")) {
              if (_cmdCompleter != null && !_cmdCompleter!.isCompleted) {
                _cmdCompleter!.complete(_rxBuffer.replaceAll(">", "").trim());
              }
              _rxBuffer = "";
            }
          }
        },
        onError: (error) {
          _updateStatus(ObdConnectionStatus.error, "Błąd Wi-Fi: " + error.toString());
          disconnect();
        },
        onDone: () {
          if (_status != ObdConnectionStatus.disconnected && _status != ObdConnectionStatus.error) {
            _updateStatus(ObdConnectionStatus.disconnected, "Odłączono Wi-Fi");
          }
          disconnect();
        },
      );
      
      _updateStatus(ObdConnectionStatus.initializing, "Konfiguracja protokołu STN/ELM327 (Wi-Fi)...");
      
      await _sendCommand("ATZ");
      await Future.delayed(const Duration(milliseconds: 600));
      await _sendCommand("ATE0");
      await _sendCommand("ATL0");
      await _sendCommand("ATS1"); // Spaces ON
      await _sendCommand("ATH0");
      await _sendCommand("ATSP0");
      
      await scanSupportedPids();
      await readVehicleInfo();
      
      _updateStatus(ObdConnectionStatus.connected, "Połączono przez Wi-Fi (" + _discoveredPids.length.toString() + " czujników | " + (_vehicleInfo?.modelName ?? 'Pojazd') + ")");
      return true;
    } catch (e) {
      _updateStatus(ObdConnectionStatus.error, "Błąd Wi-Fi: " + e.toString());
      return false;
    }
  }

  Future<String> _sendCommand(String cmd) async {
    if (_writeCharacteristic == null && _wifiSocket == null && _classicConnection == null) return "";
    
    // Mutex: czekaj aż poprzednia komenda się skończy
    while (_cmdLock != null && !_cmdLock!.isCompleted) {
      await _cmdLock!.future;
    }
    _cmdLock = Completer<void>();
    
    try {
      _rxBuffer = "";
      _cmdCompleter = Completer<String>();
      final data = utf8.encode(cmd + String.fromCharCode(13));
      
      if (_wifiSocket != null) {
        _wifiSocket!.add(data);
      } else if (_classicConnection != null) {
        _classicConnection!.output.add(Uint8List.fromList(data));
        await _classicConnection!.output.allSent;
      } else {
        await _writeCharacteristic!.write(data, withoutResponse: _writeCharacteristic!.properties.writeWithoutResponse);
      }
      
      final response = await _cmdCompleter!.future.timeout(const Duration(seconds: 5));
      
      // Obetnij echo komendy (niektóre klony ELM327 ignorują ATE0)
      String cleaned = response.trim();
      if (cleaned.startsWith(cmd)) {
        cleaned = cleaned.substring(cmd.length).trim();
      }
      // Usuń "SEARCHING..." z odpowiedzi (ELM327 wysyła to przy pierwszym zapytaniu)
      cleaned = cleaned.replaceAll("SEARCHING...", "").trim();
      
      return cleaned;
    } catch (e) {
      return "";
    } finally {
      if (_cmdLock != null && !_cmdLock!.isCompleted) {
        _cmdLock!.complete();
      }
    }
  }

  List<int> _parseHexBytes(String response) {
    final lines = response.split(RegExp(r'[\r\n]+'));
    final List<int> bytes = [];
    
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;
      
      final upper = line.toUpperCase();
      if (upper.contains('OK') || upper.contains('NO DATA') || upper.contains('NODATA') ||
          upper.contains('SEARCHING') || upper.contains('UNABLE') || upper.contains('ERROR') ||
          upper.contains('STOPPED') || upper.contains('?') || upper == '>') continue;
      if (upper.startsWith('AT') || upper.startsWith('ELM')) continue;
      
      // Remove CAN frame prefix (e.g. "0: ", "1:", "2: ")
      line = line.replaceAll(RegExp(r'^[0-9]:\s*'), '');
      
      // Skip PCI byte count (3 hex digit lines)
      if (line.length <= 3 && RegExp(r'^[0-9A-Fa-f]+$').hasMatch(line)) continue;

      final parts = line.split(RegExp(r'\s+'));
      for (final p in parts) {
        if (p.isEmpty) continue;
        if (!RegExp(r'^[0-9A-Fa-f]+$').hasMatch(p)) continue;
        
        if (p.length == 2) {
          final val = int.tryParse(p, radix: 16);
          if (val != null) bytes.add(val);
        } else if (p.length > 2 && p.length % 2 == 0) {
          for (int i = 0; i < p.length; i += 2) {
            final val = int.tryParse(p.substring(i, i + 2), radix: 16);
            if (val != null) bytes.add(val);
          }
        }
      }
    }
    return bytes;
  }

  String _bytesToAscii(List<int> bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      if (b >= 32 && b <= 126) {
        buffer.writeCharCode(b);
      }
    }
    return buffer.toString().trim();
  }

  Future<double> readPid(ObdPid pid) async {
    if (_status == ObdConnectionStatus.simulated) {
      return 0.0; // W trybie symulatora logi spływają z SimulatorService
    }

    try {
      String command = pid.code;
      bool isExtended = false;

      // Obsługa zapytań producenckich (Target Boost, Mode 22, UDS)
      if (pid is ExtendedPid) {
        isExtended = true;
        command = pid.requestCommand;
        if (pid.canHeader != null) {
          await _sendCommand("AT SH ${pid.canHeader}");
        }
      }

      final response = await _sendCommand(command);
      final bytes = _parseHexBytes(response);

      // Przywróć domyślne nagłówki OBD2 po zapytaniu UDS
      if (isExtended) {
        await _sendCommand("AT SH 7DF"); // Reset do domyślnego rozgłoszenia 11-bit
      }

      if (bytes.isNotEmpty) {
        // W prawdziwym środowisku trzeba by wycinać echo i nagłówki przed zdekodowaniem.
        // Tutaj przekazujemy bajty payloadu do dekodera PIDu.
        // Przykładowo, odpowiedź na 010C to 41 0C 1A F8. My zdekodowaliśmy "410C1AF8" -> [0x41, 0x0C, 0x1A, 0xF8]
        // Trzeba uciąć pierwsze 2 bajty echa Mode+Pid dla standardowych, lub 3 bajty dla Mode 22.
        int payloadStartIndex = 2; // Dla 01 XX -> odpowiedź 41 XX Data...
        if (isExtended && bytes[0] == 0x62) {
          payloadStartIndex = 3; // Dla 22 XX YY -> odpowiedź 62 XX YY Data...
        }
        
        if (bytes.length > payloadStartIndex) {
          final payload = bytes.sublist(payloadStartIndex);
          return pid.decoder(payload);
        }
      }
      return 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  /// Odczytuje zapisane kody błędów silnika (DTC Mode 03 & 07)
  Future<List<DtcCode>> readDtcCodes() async {
    if (_status == ObdConnectionStatus.simulated) {
      if (selectedScenario == SimScenario.skodaRapidInjector) {
        return [
          DtcCode.getByCode("P0087"),
          DtcCode.getByCode("P0301"),
          DtcCode.getByCode("P0172"),
        ];
      } else if (selectedScenario == SimScenario.boostLeak) {
        return [DtcCode.getByCode("P0299")];
      } else if (selectedScenario == SimScenario.knockRetard) {
        return [DtcCode.getByCode("P0300")];
      } else if (selectedScenario == SimScenario.peugeotIdleHunting) {
        return [
          DtcCode.getByCode("P0443"),
          DtcCode.getByCode("P0106"),
          DtcCode.getByCode("P0300"),
        ];
      }
      return [];
    }

    try {
      final res03 = await _sendCommand("03");
      final bytes = _parseHexBytes(res03);
      final List<DtcCode> codes = [];
      
      // Strip response header: Mode 03 response starts with 0x43
      int startIdx = 0;
      if (bytes.isNotEmpty && bytes[0] == 0x43) {
        startIdx = 1;
        // Some ECUs also include a DTC count byte after 0x43
        if (bytes.length > 1 && bytes[1] < 0x10) {
          startIdx = 2;
        }
      }

      for (int i = startIdx; i < bytes.length - 1; i += 2) {
        final b1 = bytes[i];
        final b2 = bytes[i + 1];
        if (b1 == 0 && b2 == 0) continue;

        String prefix = "P";
        final type = (b1 & 0xC0) >> 6;
        if (type == 1) prefix = "C";
        if (type == 2) prefix = "B";
        if (type == 3) prefix = "U";

        final digit1 = (b1 & 0x30) >> 4;
        final digit2 = b1 & 0x0F;
        final digit3 = (b2 & 0xF0) >> 4;
        final digit4 = b2 & 0x0F;

        final codeStr = "$prefix$digit1${digit2.toRadixString(16)}${digit3.toRadixString(16)}${digit4.toRadixString(16)}".toUpperCase();
        codes.add(DtcCode.getByCode(codeStr));
      }
      return codes;
    } catch (_) {
      return [];
    }
  }

  /// Kasuje kody błędów silnika (Mode 04 - Clear DTC & Check Engine)
  Future<bool> clearDtcCodes() async {
    if (_status == ObdConnectionStatus.simulated) {
      return true;
    }
    try {
      await _sendCommand("04");
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Odczytuje dane identyfikacyjne pojazdu z ECU (Mode 09: VIN, CALID, ECUNAME) oraz protokół adaptera
  Future<VehicleInfo?> readVehicleInfo() async {
    if (_status == ObdConnectionStatus.simulated) {
      if (selectedScenario == SimScenario.skodaRapidInjector) {
        _vehicleInfo = VehicleInfo.skodaRapidSample;
      } else if (selectedScenario == SimScenario.peugeotIdleHunting) {
        _vehicleInfo = VehicleInfo.peugeot307Sample;
      } else {
        _vehicleInfo = VehicleInfo.genericSample;
      }
      return _vehicleInfo;
    }

    try {
      String _cleanAscii(String cmd, int mode, int pid) {
        return ""; // placeholder
      }
      
      Future<String> _readAndClean(String cmd, int expectedEchoMode) async {
        final resp = await _sendCommand(cmd);
        final bytes = _parseHexBytes(resp);
        if (bytes.length > 2 && bytes[0] == expectedEchoMode) {
          bytes.removeRange(0, 2);
          if (bytes.isNotEmpty && bytes[0] < 10) bytes.removeAt(0); // remove message count
        }
        return _bytesToAscii(bytes);
      }

      final vinAscii = await _readAndClean("0902", 0x49);
      final calIdAscii = await _readAndClean("0904", 0x49);
      final ecuNameAscii = await _readAndClean("090A", 0x49);
      
      final protocolResp = await _sendCommand("ATDP");
      final voltageResp = await _sendCommand("ATRV");
      final cleanVolt = double.tryParse(voltageResp.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 12.6;

      final distResp = await _sendCommand("0131");
      final distBytes = _parseHexBytes(distResp);
      if (distBytes.length > 2 && distBytes[0] == 0x41) {
         distBytes.removeRange(0, 2);
      }
      int distSinceDtc = 0;
      if (distBytes.length >= 2) {
        distSinceDtc = (distBytes[0] * 256) + distBytes[1];
      }

      _vehicleInfo = VehicleInfo.decodeFromRawData(
        rawVin: vinAscii.isNotEmpty ? vinAscii : "BRAK-VIN",
        rawCalId: calIdAscii.isNotEmpty ? calIdAscii : null,
        rawEcuName: ecuNameAscii.isNotEmpty ? ecuNameAscii : null,
        protocol: protocolResp.isNotEmpty ? protocolResp.trim() : null,
        voltage: cleanVolt,
        distSinceDtc: distSinceDtc,
      );
      return _vehicleInfo;
    } catch (_) {
      return null;
    }
  }

  String _extractAsciiFromHex(String response) {
    final bytes = _parseHexBytes(response);
    final buffer = StringBuffer();
    for (final b in bytes) {
      if (b >= 32 && b <= 126) {
        buffer.writeCharCode(b);
      }
    }
    return buffer.toString().trim();
  }

  /// Rozłączenie
  void disconnect() {
    _simulator.stopLivePull();
    _notifySubscription?.cancel();
    _wifiSocket?.destroy();
    _wifiSocket = null;
    _classicConnection?.dispose();
    _classicConnection = null;
    _connectedDevice?.disconnect();
    _connectedDevice = null;
    _writeCharacteristic = null;
    _readCharacteristic = null;
    _updateStatus(ObdConnectionStatus.disconnected, "Rozłączono");
  }
}

