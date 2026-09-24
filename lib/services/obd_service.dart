import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart' as fbs;
import '../models/obd_pid.dart';
import '../models/extended_pid.dart';
import '../models/dtc_code.dart';
import '../models/vehicle_info.dart';
import 'elm_parser.dart';
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

/// Komunikacja z adapterem ELM327 / STN (vLinker MC+) przez BLE, Classic BT lub Wi-Fi.
///
/// Najważniejsze zasady działania:
/// * nagłówki CAN są włączone (ATH1), więc każdą odpowiedź przypisujemy do
///   konkretnego sterownika — silnik (7E8) i skrzynia (7E9) nie mieszają się,
/// * po wykryciu protokołu zapytania o czujniki idą fizycznie tylko do ECU
///   silnika (ATSH 7E0), a każda odpowiedź jest sprawdzana (usługa + numer PID),
///   więc spóźniona odpowiedź nigdy nie trafi do niewłaściwego czujnika,
/// * komendy są kolejkowane — tylko jedna komenda naraz, niezależnie od tego,
///   czy wysyła je rejestrator, czy przycisk „Odczytaj kody błędów”.
class ObdService extends ChangeNotifier {
  ObdConnectionStatus _status = ObdConnectionStatus.disconnected;
  String _statusMessage = "Rozłączono";
  bool _isScanning = false;
  bool _closing = false;

  // --- Warstwa transportowa ---
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _bleWrite;
  StreamSubscription<List<int>>? _bleRxSub;
  StreamSubscription<BluetoothConnectionState>? _bleStateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  fbs.BluetoothConnection? _classic;
  StreamSubscription<Uint8List>? _classicSub;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;

  // --- Kolejka komend ---
  final StringBuffer _rx = StringBuffer();
  Completer<String>? _pendingResponse;
  Future<void> _commandQueue = Future.value();
  bool _needsDrain = false;

  // --- Stan protokołu OBD ---
  ObdBusType _bus = ObdBusType.unknown;
  String? _engineEcu; // adres odpowiedzi ECU silnika, np. "7E8"
  String? _engineHeader; // adres zapytań fizycznych do ECU silnika, np. "7E0"
  String? _activeHeader; // ostatnio ustawiony ATSH
  bool _responseCountSupported = false;
  Set<int> _supportedPids = {};
  double? _baroKpa;
  String _adapterId = "";
  String _protocolName = "";

  final SimulatorService _simulator = SimulatorService();
  SimScenario _selectedScenario = SimScenario.healthy;

  List<ObdPid> _discoveredPids = uniqueStandardPids();
  VehicleInfo? _vehicleInfo;

  ObdConnectionStatus get status => _status;
  String get statusMessage => _statusMessage;
  bool get isScanning => _isScanning;
  bool get isLive => _status == ObdConnectionStatus.connected;
  BluetoothDevice? get connectedDevice => _bleDevice;
  List<ObdPid> get discoveredPids => _discoveredPids;
  VehicleInfo? get vehicleInfo => _vehicleInfo;
  SimulatorService get simulator => _simulator;
  String get adapterId => _adapterId;
  String get protocolName => _protocolName;
  String? get engineEcuAddress => _engineEcu;
  Set<int> get supportedPidNumbers => _supportedPids;

  SimScenario get selectedScenario => _selectedScenario;
  set selectedScenario(SimScenario s) {
    _selectedScenario = s;
    notifyListeners();
  }

  /// Katalog czujników bez duplikatów nazw (np. dwa warianty PEDAL).
  static List<ObdPid> uniqueStandardPids() {
    final seen = <String>{};
    return ObdPid.standardPids.where((p) => seen.add(p.shortName)).toList();
  }

  bool get _hasTransport => _socket != null || _classic != null || _bleWrite != null;
  bool get _isCan => _bus == ObdBusType.can11 || _bus == ObdBusType.can29;

  void _updateStatus(ObdConnectionStatus s, String msg) {
    _status = s;
    _statusMessage = msg;
    notifyListeners();
  }

  // ===========================================================================
  // Symulator
  // ===========================================================================

  /// Włącza tryb symulatora (bez konieczności podłączania auta)
  void connectSimulator(SimScenario scenario) {
    _closeTransport();
    _selectedScenario = scenario;
    _discoveredPids = uniqueStandardPids();

    if (scenario == SimScenario.skodaRapidInjector) {
      _vehicleInfo = VehicleInfo.skodaRapidSample;
    } else if (scenario == SimScenario.peugeotIdleHunting) {
      _vehicleInfo = VehicleInfo.peugeot307Sample;
    } else {
      _vehicleInfo = VehicleInfo.genericSample;
    }

    _updateStatus(ObdConnectionStatus.simulated, "Połączono w trybie symulatora: ${scenario.title}");
  }

  // ===========================================================================
  // Skanowanie BLE — nie zmienia statusu połączenia z autem
  // ===========================================================================

  /// Skanuje urządzenia BLE. Zwraca komunikat błędu albo null.
  Future<String?> startScan({required void Function(List<ScanResult> results) onResults}) async {
    try {
      final adapterState = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3), onTimeout: () => BluetoothAdapterState.unknown);
      if (adapterState != BluetoothAdapterState.on) {
        return "Włącz Bluetooth w telefonie!";
      }

      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.onScanResults.listen(onResults);
      FlutterBluePlus.cancelWhenScanComplete(_scanSub!);

      _isScanning = true;
      notifyListeners();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
      return null;
    } catch (e) {
      return "Błąd skanowania: $e";
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _isScanning = false;
    notifyListeners();
  }

  // ===========================================================================
  // Łączenie — BLE / Classic / Wi-Fi
  // ===========================================================================

  bool get _isBusy => _status == ObdConnectionStatus.connecting || _status == ObdConnectionStatus.initializing;

  /// Łączy się z adapterem BLE (np. vLinker MC+)
  Future<bool> connectDevice(BluetoothDevice device) async {
    if (_isBusy) return false;
    await stopScan();
    await _closeTransport();
    final name = device.platformName.isNotEmpty ? device.platformName : device.remoteId.str;
    _updateStatus(ObdConnectionStatus.connecting, "Łączenie z $name...");

    try {
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 15));
      _bleDevice = device;
      _bleStateSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && _bleDevice == device) {
          _onTransportLost("Utracono połączenie Bluetooth z adapterem");
        }
      });

      final services = await device.discoverServices();
      BluetoothCharacteristic? bestWrite;
      BluetoothCharacteristic? bestNotify;
      int bestScore = -1;

      for (final service in services) {
        final uuid = service.uuid.str.toUpperCase();
        // Pomiń standardowe usługi GAP/GATT/Device Info
        if (uuid == "1800" || uuid == "1801" || uuid == "180A" || uuid == "180F") continue;

        BluetoothCharacteristic? w;
        BluetoothCharacteristic? n;
        for (final c in service.characteristics) {
          if (w == null && (c.properties.write || c.properties.writeWithoutResponse)) w = c;
          if (n == null && (c.properties.notify || c.properties.indicate)) n = c;
        }
        if (w == null || n == null) continue;

        // vLinker MC+: 18F0 (2AF0/2AF1), typowe klony: FFE0, FFF0
        int score = 1;
        if (uuid.contains("18F0") || uuid.contains("FFE0") || uuid.contains("FFF0") || uuid.contains("E7810A71")) {
          score = 2;
        }
        if (score > bestScore) {
          bestScore = score;
          bestWrite = w;
          bestNotify = n;
        }
      }

      if (bestWrite == null || bestNotify == null) {
        _updateStatus(ObdConnectionStatus.error, "To urządzenie nie wygląda na adapter OBD (brak kanału UART BLE).");
        await _closeTransport();
        return false;
      }

      // onValueReceived — tylko dane przychodzące z adaptera. (lastValueStream
      // zwracał także nasze własne, wysłane komendy, co psuło odpowiedzi.)
      _bleRxSub = bestNotify.onValueReceived.listen((value) => _onRx(value));
      await bestNotify.setNotifyValue(true);
      _bleWrite = bestWrite;

      return await _initializeAdapter("vLinker (BLE)");
    } catch (e) {
      _updateStatus(ObdConnectionStatus.error, "Błąd połączenia BLE: $e");
      await _closeTransport();
      return false;
    }
  }

  /// Łączy się ze sparowanym adapterem Classic Bluetooth (SPP)
  Future<bool> connectClassic(fbs.BluetoothDevice device) async {
    if (_isBusy) return false;
    await stopScan();
    await _closeTransport();
    _updateStatus(ObdConnectionStatus.connecting, "Łączenie (Classic BT): ${device.name ?? device.address}...");
    try {
      // Pierwsza próba połączenia RFCOMM z adapterem często kończy się
      // niepowodzeniem (adapter jeszcze się budzi) — ponów raz po krótkiej przerwie.
      fbs.BluetoothConnection? conn;
      for (int attempt = 1; conn == null; attempt++) {
        try {
          conn = await fbs.BluetoothConnection.toAddress(device.address);
        } catch (_) {
          if (attempt >= 3) rethrow;
          _updateStatus(ObdConnectionStatus.connecting, "Ponawiam połączenie (próba ${attempt + 1}/3)...");
          await Future.delayed(const Duration(milliseconds: 1200));
        }
      }
      _classic = conn;
      _classicSub = conn.input!.listen(
        _onRx,
        onDone: () => _onTransportLost("Adapter Classic BT rozłączony"),
        onError: (_) => _onTransportLost("Błąd transmisji Classic BT"),
      );
      return await _initializeAdapter("Classic BT");
    } catch (e) {
      _updateStatus(ObdConnectionStatus.error, "Błąd BT Classic: $e");
      await _closeTransport();
      return false;
    }
  }

  /// Łączy się z adapterem Wi-Fi (domyślnie 192.168.0.10:35000)
  Future<bool> connectWifi({String ip = "192.168.0.10", int port = 35000}) async {
    if (_isBusy) return false;
    await stopScan();
    await _closeTransport();
    _updateStatus(ObdConnectionStatus.connecting, "Łączenie przez Wi-Fi ($ip:$port)...");
    try {
      final socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _socketSub = socket.listen(
        _onRx,
        onError: (_) => _onTransportLost("Błąd połączenia Wi-Fi"),
        onDone: () => _onTransportLost("Adapter Wi-Fi rozłączony"),
      );
      return await _initializeAdapter("Wi-Fi");
    } catch (e) {
      _updateStatus(ObdConnectionStatus.error, "Błąd Wi-Fi: $e");
      await _closeTransport();
      return false;
    }
  }

  void _onTransportLost(String msg) {
    if (_closing) return;
    if (_status == ObdConnectionStatus.disconnected || _status == ObdConnectionStatus.simulated) return;
    _closeTransport();
    _updateStatus(ObdConnectionStatus.disconnected, msg);
  }

  /// Rozłączenie
  void disconnect() {
    _simulator.stopLivePull();
    _closeTransport();
    _updateStatus(ObdConnectionStatus.disconnected, "Rozłączono");
  }

  Future<void> _closeTransport() async {
    _closing = true;
    try {
      _simulator.stopLivePull();
      final pending = _pendingResponse;
      _pendingResponse = null;
      if (pending != null && !pending.isCompleted) pending.complete("");

      await _bleRxSub?.cancel();
      await _bleStateSub?.cancel();
      await _classicSub?.cancel();
      await _socketSub?.cancel();
      _bleRxSub = null;
      _bleStateSub = null;
      _classicSub = null;
      _socketSub = null;

      _socket?.destroy();
      _socket = null;
      _classic?.dispose();
      _classic = null;
      final ble = _bleDevice;
      _bleDevice = null;
      _bleWrite = null;
      if (ble != null) {
        try {
          await ble.disconnect();
        } catch (_) {}
      }

      _rx.clear();
      _needsDrain = false;
      _bus = ObdBusType.unknown;
      _engineEcu = null;
      _engineHeader = null;
      _activeHeader = null;
      _responseCountSupported = false;
      _supportedPids = {};
      _baroKpa = null;
      _adapterId = "";
      _protocolName = "";
    } finally {
      _closing = false;
    }
  }

  // ===========================================================================
  // Niskopoziomowa komunikacja z ELM327
  // ===========================================================================

  void _onRx(List<int> data) {
    if (data.isEmpty) return;
    // ELM wysyła czyste ASCII; bajty 0x00 pojawiają się w niektórych klonach
    _rx.write(String.fromCharCodes(data.where((b) => b != 0)));
    final text = _rx.toString();
    final idx = text.indexOf('>');
    if (idx < 0) return;

    _rx.clear();
    if (idx + 1 < text.length) _rx.write(text.substring(idx + 1));
    final pending = _pendingResponse;
    _pendingResponse = null;
    // Odpowiedź bez oczekującego zapytania (spóźniona) jest odrzucana
    if (pending != null && !pending.isCompleted) pending.complete(text.substring(0, idx));
  }

  Future<void> _write(String cmd) async {
    final bytes = Uint8List.fromList("$cmd\r".codeUnits);
    if (_socket != null) {
      _socket!.add(bytes);
      await _socket!.flush();
    } else if (_classic != null) {
      _classic!.output.add(bytes);
      await _classic!.output.allSent;
    } else if (_bleWrite != null) {
      final c = _bleWrite!;
      final withoutResponse = c.properties.writeWithoutResponse;
      final mtu = _bleDevice?.mtuNow ?? 23;
      final chunk = (mtu - 3).clamp(20, 512);
      for (int i = 0; i < bytes.length; i += chunk) {
        final end = i + chunk > bytes.length ? bytes.length : i + chunk;
        await c.write(bytes.sublist(i, end), withoutResponse: withoutResponse);
      }
    }
  }

  /// Wysyła komendę i czeka na znak zachęty '>'. Komendy są ściśle kolejkowane.
  Future<String> _sendCommand(String cmd, {Duration timeout = const Duration(seconds: 4)}) async {
    if (!_hasTransport) return "";

    final previous = _commandQueue;
    final done = Completer<void>();
    _commandQueue = done.future;
    await previous;

    try {
      if (!_hasTransport) return "";

      // Po przekroczeniu czasu adapter mógł jeszcze coś wysłać — odczekaj na
      // zaległy znak '>' zanim wyślesz nową komendę.
      if (_needsDrain) {
        final drain = Completer<String>();
        _pendingResponse = drain;
        await drain.future.timeout(const Duration(milliseconds: 1500), onTimeout: () => "");
        _pendingResponse = null;
        _needsDrain = false;
      }

      _rx.clear();
      final completer = Completer<String>();
      _pendingResponse = completer;
      await _write(cmd);
      final response = await completer.future.timeout(timeout);
      return _stripEcho(response, cmd);
    } on TimeoutException {
      _pendingResponse = null;
      _needsDrain = true;
      if (kDebugMode) debugPrint("OBD timeout: $cmd");
      return "";
    } catch (e) {
      _pendingResponse = null;
      if (kDebugMode) debugPrint("OBD błąd komendy $cmd: $e");
      return "";
    } finally {
      done.complete();
    }
  }

  /// Usuwa echo komendy (niektóre klony ignorują ATE0).
  static String _stripEcho(String response, String cmd) {
    final normCmd = cmd.replaceAll(' ', '').toUpperCase();
    return response
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && l.replaceAll(' ', '').toUpperCase() != normCmd)
        .join("\n");
  }

  Future<void> _setHeader(String header) async {
    if (_activeHeader == header) return;
    if (header.length == 8) {
      // 29-bit: priorytet przez ATCP, reszta przez ATSH
      await _sendCommand("ATCP${header.substring(0, 2)}");
      await _sendCommand("ATSH${header.substring(2)}");
    } else {
      await _sendCommand("ATSH$header");
    }
    _activeHeader = header;
  }

  String? get _functionalHeader {
    switch (_bus) {
      case ObdBusType.can11:
        return "7DF";
      case ObdBusType.can29:
        return "18DB33F1";
      default:
        return null;
    }
  }

  static String? _requestHeaderFor(String ecu, ObdBusType bus) {
    if (bus == ObdBusType.can11 && ecu.length == 3) {
      final v = int.tryParse(ecu, radix: 16);
      if (v != null && v >= 0x7E8 && v <= 0x7EF) return (v - 8).toRadixString(16).toUpperCase();
    }
    if (bus == ObdBusType.can29 && ecu.length == 8 && ecu.startsWith("18DAF1")) {
      return "18DA${ecu.substring(6)}F1";
    }
    return null;
  }

  /// Wysyła zapytanie OBD i zwraca odpowiedzi rozdzielone na sterowniki.
  /// [broadcast] — zapytanie do wszystkich ECU (np. kody błędów),
  /// w przeciwnym razie tylko do ECU silnika (lub [header], jeśli podano).
  Future<List<EcuResponse>> _query(
    String cmd, {
    bool broadcast = false,
    String? header,
    bool singleFrame = false,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    String? targetHeader;
    if (broadcast) {
      targetHeader = _functionalHeader;
    } else {
      targetHeader = header ?? _engineHeader;
    }
    if (targetHeader != null && _isCan) await _setHeader(targetHeader);

    // Liczba oczekiwanych odpowiedzi — adapter kończy od razu po pierwszej
    // zamiast czekać na timeout magistrali (kilkukrotnie szybsze logowanie).
    final useCount = singleFrame && !broadcast && _responseCountSupported && targetHeader != null;
    final raw = await _sendCommand(useCount ? "${cmd}1" : cmd, timeout: timeout);
    final responses = ElmParser.parse(raw, _bus);

    if (!broadcast && header == null && _engineEcu != null) {
      final fromEngine = responses.where((r) => r.ecu == _engineEcu).toList();
      if (fromEngine.isNotEmpty) return fromEngine;
    }
    return responses;
  }

  // ===========================================================================
  // Inicjalizacja adaptera i wykrywanie sterownika silnika
  // ===========================================================================

  Future<bool> _initializeAdapter(String transportLabel) async {
    _updateStatus(ObdConnectionStatus.initializing, "Reset adaptera ($transportLabel)...");

    await _sendCommand("ATZ", timeout: const Duration(seconds: 5));
    await Future.delayed(const Duration(milliseconds: 300));
    if (!_hasTransport) return false;

    await _sendCommand("ATE0"); // echo off
    await _sendCommand("ATL0"); // bez dodatkowych LF
    await _sendCommand("ATS1"); // spacje między bajtami
    await _sendCommand("ATH1"); // nagłówki ON — rozróżniamy sterowniki
    await _sendCommand("ATAT1"); // adaptacyjny timeout
    await _sendCommand("ATSP0"); // automatyczny wybór protokołu
    _adapterId = (await _sendCommand("ATI")).replaceAll("\n", " ").trim();

    _updateStatus(ObdConnectionStatus.initializing, "Wyszukiwanie protokołu OBD (do 20 s)...");
    final raw0100 = await _sendCommand("0100", timeout: const Duration(seconds: 20));
    _bus = ElmParser.busFromProtocolNumber(await _sendCommand("ATDPN"));
    _protocolName = (await _sendCommand("ATDP")).trim();

    final responses = ElmParser.parse(raw0100, _bus).where((r) => r.matches(0x41, [0x00])).toList();
    if (responses.isEmpty) {
      final hint = raw0100.toUpperCase().contains("UNABLE") || raw0100.isEmpty
          ? "Adapter działa, ale samochód nie odpowiada. Włącz zapłon (lub silnik) i spróbuj ponownie."
          : "Nieoczekiwana odpowiedź sterownika: ${raw0100.replaceAll('\n', ' ')}";
      _updateStatus(ObdConnectionStatus.error, hint);
      await _closeTransport();
      return false;
    }

    // Wybierz ECU silnika: ten, który obsługuje RPM (PID 0C); przy remisie najniższy adres (7E8)
    responses.sort((a, b) {
      final aRpm = ElmParser.decodeSupportedPids(a.data).contains(0x0C) ? 0 : 1;
      final bRpm = ElmParser.decodeSupportedPids(b.data).contains(0x0C) ? 0 : 1;
      if (aRpm != bRpm) return aRpm.compareTo(bRpm);
      return a.ecu.compareTo(b.ecu);
    });
    final engine = responses.first;
    _engineEcu = engine.ecu == "?" ? null : engine.ecu;
    _engineHeader = _engineEcu != null ? _requestHeaderFor(_engineEcu!, _bus) : null;
    _activeHeader = null;

    _updateStatus(ObdConnectionStatus.initializing, "Skanowanie obsługiwanych czujników...");
    final supported = ElmParser.decodeSupportedPids(engine.data);
    for (int range = 0x20; range <= 0xC0 && supported.contains(range); range += 0x20) {
      final pidHex = range.toRadixString(16).padLeft(2, '0').toUpperCase();
      final r = await _query("01$pidHex");
      final match = r.where((e) => e.matches(0x41, [range])).firstOrNull;
      if (match == null) break;
      supported.addAll(ElmParser.decodeSupportedPids(match.data));
    }
    _supportedPids = supported;

    // Sprawdź, czy adapter obsługuje liczbę oczekiwanych odpowiedzi (np. "010C1")
    if (_isCan && _engineHeader != null) {
      await _setHeader(_engineHeader!);
      final raw = await _sendCommand("01001");
      _responseCountSupported = ElmParser.parse(raw, _bus).any((r) => r.matches(0x41, [0x00]));
    }

    // Ciśnienie atmosferyczne — do przeliczenia MAP na doładowanie względne
    if (_supportedPids.contains(0x33)) {
      final baro = await _readMode01Raw(0x33);
      if (baro != null && baro.isNotEmpty && baro[0] > 50) _baroKpa = baro[0].toDouble();
    }

    _rebuildDiscoveredPids();

    _updateStatus(ObdConnectionStatus.initializing, "Odczyt danych pojazdu (VIN, sterownik)...");
    await readVehicleInfo();

    if (_vehicleInfo != null && _vehicleInfo!.profile != VehicleProfile.generic) {
      _updateStatus(ObdConnectionStatus.initializing, "Sprawdzanie parametrów producenta...");
      await _probeExtendedPids(_vehicleInfo!.profile);
    }

    if (!_hasTransport) return false;
    final ecuTxt = _engineEcu != null ? " | ECU $_engineEcu" : "";
    _updateStatus(
      ObdConnectionStatus.connected,
      "Połączono ($transportLabel) • ${_discoveredPids.length} czujników$ecuTxt | ${_vehicleInfo?.modelName ?? 'Pojazd'}",
    );
    return true;
  }

  void _rebuildDiscoveredPids() {
    final list = <ObdPid>[];
    final seen = <String>{};
    for (final pid in ObdPid.standardPids) {
      final n = pid.mode01Pid;
      if (n == null) continue;
      if (_supportedPids.isNotEmpty && !_supportedPids.contains(n)) continue;
      if (!seen.add(pid.shortName)) continue;
      list.add(pid);
    }
    _discoveredPids = list;
  }

  Future<void> _probeExtendedPids(VehicleProfile profile) async {
    if (_bus != ObdBusType.can11) return;
    final seen = _discoveredPids.map((p) => p.shortName).toSet();
    for (final ep in ExtendedPid.getForProfile(profile)) {
      if (!_hasTransport) return;
      if (seen.contains(ep.shortName)) continue;
      if (ep.canHeader != null && ep.canHeader!.length != 3) continue;
      final v = await _readPidInternal(ep);
      if (v != null) {
        _discoveredPids.add(ep);
        seen.add(ep.shortName);
      }
    }
  }

  // ===========================================================================
  // Odczyt czujników
  // ===========================================================================

  Future<List<int>?> _readMode01Raw(int pid) async {
    final hex = pid.toRadixString(16).padLeft(2, '0').toUpperCase();
    final r = await _query("01$hex", singleFrame: true);
    final match = r.where((e) => e.matches(0x41, [pid])).firstOrNull;
    return match?.data.sublist(2);
  }

  /// Odczytuje wartość czujnika. Zwraca null, gdy ECU nie odpowiedziało
  /// poprawnie — taka próbka jest pomijana zamiast zapisywać fałszywe 0.
  Future<double?> readPid(ObdPid pid) async {
    if (_status != ObdConnectionStatus.connected) return null;
    return _readPidInternal(pid);
  }

  Future<double?> _readPidInternal(ObdPid pid) async {
    if (pid.simulatorOnly || !_hasTransport) return null;

    String cmd;
    String? header;
    if (pid is ExtendedPid) {
      cmd = pid.requestCommand.toUpperCase();
      header = pid.canHeader;
    } else {
      cmd = pid.code.toUpperCase();
    }
    if (cmd.length < 4 || cmd.length.isOdd || !RegExp(r'^[0-9A-F]+$').hasMatch(cmd)) return null;

    final service = int.parse(cmd.substring(0, 2), radix: 16);
    final id = [
      for (int i = 2; i < cmd.length; i += 2) int.parse(cmd.substring(i, i + 2), radix: 16),
    ];

    try {
      final responses = await _query(cmd, header: header, singleFrame: true);
      final match = responses.where((r) => r.matches(service + 0x40, id)).firstOrNull;
      if (match == null) return null;

      final payload = match.data.sublist(1 + id.length);
      if (payload.isEmpty) return null;
      var value = pid.decoder(payload);

      // Dekoder BOOST liczy (MAP - 100 kPa); korygujemy o zmierzone ciśnienie atmosferyczne
      if (pid is! ExtendedPid && pid.shortName == "BOOST" && _baroKpa != null) {
        value += (100.0 - _baroKpa!) / 100.0;
      }
      if (!value.isFinite) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // Kody błędów (Mode 03 / 07 / 04)
  // ===========================================================================

  String _ecuLabel(String ecu) {
    final e = ecu.toUpperCase();
    String? last;
    if (_bus == ObdBusType.can11 && e.length == 3) {
      if (e == "7E8") return "Silnik (7E8)";
      if (e == "7E9") return "Skrzynia biegów (7E9)";
      return "Sterownik $e";
    }
    if (_bus == ObdBusType.can29 && e.length == 8) last = e.substring(6);
    if (_bus == ObdBusType.legacy) last = e;
    if (last == "10") return "Silnik ($e)";
    if (last == "18") return "Skrzynia biegów ($e)";
    return e == "?" ? "Sterownik" : "Sterownik $e";
  }

  /// Odczytuje zapisane (Mode 03) i oczekujące (Mode 07) kody błędów ze wszystkich
  /// sterowników emisyjnych. Zwraca null, gdy nie udało się odczytać pamięci błędów.
  Future<List<DtcCode>?> readDtcCodes() async {
    if (_status == ObdConnectionStatus.simulated) {
      switch (_selectedScenario) {
        case SimScenario.skodaRapidInjector:
          return [DtcCode.getByCode("P0087"), DtcCode.getByCode("P0301"), DtcCode.getByCode("P0172")];
        case SimScenario.boostLeak:
          return [DtcCode.getByCode("P0299")];
        case SimScenario.knockRetard:
          return [DtcCode.getByCode("P0300")];
        case SimScenario.peugeotIdleHunting:
          return [DtcCode.getByCode("P0443"), DtcCode.getByCode("P0106"), DtcCode.getByCode("P0300")];
        default:
          return [];
      }
    }
    if (_status != ObdConnectionStatus.connected) return null;

    final result = <DtcCode>[];
    final seen = <String>{};
    bool anyValidResponse = false;

    for (final (mode, pending) in [("03", false), ("07", true)]) {
      final responses = await _query(mode, broadcast: true, timeout: const Duration(seconds: 6));
      for (final r in responses) {
        if (r.isNegative || r.data.isEmpty) continue;
        if (r.data[0] != int.parse(mode, radix: 16) + 0x40) continue;
        anyValidResponse = true;
        for (final code in ElmParser.decodeDtcs(r.data, isCan: _isCan || _bus == ObdBusType.unknown)) {
          final key = "$code@${r.ecu}";
          if (!seen.add(key)) continue; // oczekujący, który jest już zapisany
          result.add(DtcCode.getByCode(code).withSource(ecuLabel: _ecuLabel(r.ecu), pending: pending));
        }
      }
      if (mode == "03" && !anyValidResponse) return null;
    }
    return result;
  }

  /// Kasuje kody błędów (Mode 04). Zwraca true, jeśli sterownik potwierdził.
  /// Wymaga włączonego zapłonu przy wyłączonym silniku.
  Future<bool> clearDtcCodes() async {
    if (_status == ObdConnectionStatus.simulated) return true;
    if (_status != ObdConnectionStatus.connected) return false;
    final responses = await _query("04", broadcast: true, timeout: const Duration(seconds: 6));
    return responses.any((r) => r.data.isNotEmpty && r.data[0] == 0x44);
  }

  // ===========================================================================
  // Dane pojazdu (Mode 09)
  // ===========================================================================

  Future<VehicleInfo?> readVehicleInfo() async {
    if (_status == ObdConnectionStatus.simulated) {
      if (_selectedScenario == SimScenario.skodaRapidInjector) {
        _vehicleInfo = VehicleInfo.skodaRapidSample;
      } else if (_selectedScenario == SimScenario.peugeotIdleHunting) {
        _vehicleInfo = VehicleInfo.peugeot307Sample;
      } else {
        _vehicleInfo = VehicleInfo.genericSample;
      }
      notifyListeners();
      return _vehicleInfo;
    }
    if (!_hasTransport) return null;

    try {
      Future<List<String>> mode09(int pid, {int itemLength = 0}) async {
        final hex = pid.toRadixString(16).padLeft(2, '0').toUpperCase();
        final r = await _query("09$hex", timeout: const Duration(seconds: 6));
        final match = r.where((e) => e.matches(0x49, [pid])).firstOrNull;
        if (match == null) return const [];
        return ElmParser.decodeMode09Strings(match.data, itemLength: itemLength);
      }

      final vin = await mode09(0x02);
      final calIds = await mode09(0x04, itemLength: 16);
      final ecuName = await mode09(0x0A, itemLength: 20);

      final voltageResp = await _sendCommand("ATRV");
      final volt = double.tryParse(voltageResp.replaceAll(RegExp(r'[^0-9.]'), ''));

      int? distSinceDtc;
      if (_supportedPids.contains(0x31)) {
        final d = await _readMode01Raw(0x31);
        if (d != null && d.length >= 2) distSinceDtc = d[0] * 256 + d[1];
      }
      int? distMil;
      if (_supportedPids.contains(0x21)) {
        final d = await _readMode01Raw(0x21);
        if (d != null && d.length >= 2) distMil = d[0] * 256 + d[1];
      }
      FuelType fuel = FuelType.unknown;
      if (_supportedPids.contains(0x51)) {
        final d = await _readMode01Raw(0x51);
        if (d != null && d.isNotEmpty) fuel = FuelTypeExt.fromObdCode(d[0]);
      }

      _vehicleInfo = VehicleInfo.decodeFromRawData(
        rawVin: vin.isNotEmpty ? vin.first : "BRAK-VIN",
        rawCalId: calIds.isNotEmpty ? calIds.join(" / ") : null,
        rawEcuName: ecuName.isNotEmpty ? ecuName.first : null,
        protocol: _protocolName.isNotEmpty ? _protocolName : null,
        voltage: volt,
        distSinceDtc: distSinceDtc,
        distMil: distMil,
        fuelType: fuel,
      );
      notifyListeners();
      return _vehicleInfo;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _closeTransport();
    _scanSub?.cancel();
    super.dispose();
  }
}
