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
import '../models/vag_modules.dart';
import 'elm_parser.dart';
import 'vag_tp20.dart';

enum ObdConnectionStatus {
  disconnected,
  connecting,
  initializing,
  connected,
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
  bool _multiPidSupported = false;
  String? _stnId; // np. "STN2120 v5.6.19" — adapter obsługuje komendy ST
  String _protocolNumber = "6"; // z ATDPN — do przywrócenia po trybie surowego CAN
  bool _stpxSupported = false;
  final Map<String, String> _adapterInfo = {};
  int _multiPidFailures = 0;
  Set<int> _supportedPids = {};
  Set<int> _supportedMode06 = {};
  double? _baroKpa;
  String _adapterId = "";
  String _protocolName = "";

  List<ObdPid> _discoveredPids = uniqueStandardPids();
  VehicleInfo? _vehicleInfo;

  ObdConnectionStatus get status => _status;
  String get statusMessage => _statusMessage;
  bool get isScanning => _isScanning;
  bool get isLive => _status == ObdConnectionStatus.connected;
  BluetoothDevice? get connectedDevice => _bleDevice;
  List<ObdPid> get discoveredPids => _discoveredPids;
  VehicleInfo? get vehicleInfo => _vehicleInfo;
  String get adapterId => _adapterId;
  String get protocolName => _protocolName;
  String? get engineEcuAddress => _engineEcu;
  Set<int> get supportedPidNumbers => _supportedPids;

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
    if (_status == ObdConnectionStatus.disconnected) return;
    _closeTransport();
    _updateStatus(ObdConnectionStatus.disconnected, msg);
  }

  /// Rozłączenie
  void disconnect() {
    _closeTransport();
    _updateStatus(ObdConnectionStatus.disconnected, "Rozłączono");
  }

  Future<void> _closeTransport() async {
    _closing = true;
    try {
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
      _multiPidSupported = false;
      _multiPidFailures = 0;
      _stnId = null;
      _stpxSupported = false;
      _adapterInfo.clear();
      _supportedPids = {};
      _supportedMode06 = {};
      _udsPressureScale.clear();
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
    final String wire;
    if (_stpxSupported && !broadcast && targetHeader != null) {
      // Jeden sterownik → dokładnie jedna odpowiedź (także wieloramkowa)
      wire = "STPX D:$cmd,R:1";
    } else {
      final useCount = singleFrame && !broadcast && _responseCountSupported && targetHeader != null;
      wire = useCount ? "${cmd}1" : cmd;
    }
    final raw = await _sendCommand(wire, timeout: timeout);
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
    // Protokół przed formatowaniem: niektóre adaptery (np. vLinker FS i klony) po ATSP
    // przywracają domyślne formatowanie, a wtedy znikałyby nagłówki sterowników
    await _sendCommand("ATSP0"); // automatyczny wybór protokołu
    await _applyFormatting();
    _adapterId = (await _sendCommand("ATI")).replaceAll("\n", " ").trim();
    _adapterInfo["ATI (identyfikator)"] = _adapterId;
    _adapterInfo["AT@1 (opis urządzenia)"] = (await _sendCommand("AT@1")).replaceAll("\n", " ").trim();

    // Komendy rozszerzone ST (układ STN — vLinker, OBDLink): identyfikacja
    final sti = (await _sendCommand("STI")).replaceAll("\n", " ").trim();
    if (sti.isNotEmpty && !sti.contains("?")) {
      _stnId = sti;
      _adapterInfo["STI (układ STN)"] = sti;
      final stdi = (await _sendCommand("STDI")).replaceAll("\n", " ").trim();
      if (stdi.isNotEmpty && !stdi.contains("?")) _adapterInfo["STDI (sprzęt)"] = stdi;
    } else {
      _adapterInfo["STI (układ STN)"] = "brak — zwykły ELM327";
    }

    _updateStatus(ObdConnectionStatus.initializing, "Wyszukiwanie protokołu OBD (do 20 s)...");
    final raw0100 = await _sendCommand("0100", timeout: const Duration(seconds: 20));
    final dpn = await _sendCommand("ATDPN");
    _protocolNumber = dpn.trim().toUpperCase().replaceFirst(RegExp(r'^A'), '');
    _bus = ElmParser.busFromProtocolNumber(dpn);
    _protocolName = (await _sendCommand("ATDP")).trim();
    _adapterInfo["Protokół"] = _protocolName;
    // Po wyszukaniu protokołu formatowanie jeszcze raz — na wypadek resetu przez adapter
    await _applyFormatting();

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

    // Mode 06 — monitory testów pokładowych; $A2-$AD to liczniki wypadania
    // zapłonów cylindrów 1-12 (tylko CAN, silniki benzynowe).
    if (_isCan) {
      final mids = <int>{};
      for (int range = 0x00; range <= 0xA0; range += 0x20) {
        if (range > 0 && !mids.contains(range)) break;
        final hex = range.toRadixString(16).padLeft(2, '0').toUpperCase();
        final r = await _query("06$hex");
        final match = r.where((e) => e.matches(0x46, [range])).firstOrNull;
        if (match == null || match.data.length < 6) break;
        // Format jak maska Mode 01: [46, MID, A, B, C, D]
        mids.addAll(ElmParser.decodeSupportedPids([0x41, ...match.data.sublist(1)]));
      }
      _supportedMode06 = mids;
    }

    // Sprawdź, czy adapter obsługuje liczbę oczekiwanych odpowiedzi (np. "010C1")
    if (_isCan && _engineHeader != null) {
      await _setHeader(_engineHeader!);
      final raw = await _sendCommand("01001");
      _responseCountSupported = ElmParser.parse(raw, _bus).any((r) => r.matches(0x41, [0x00]));
    }

    // STPX (komenda STN): wysłanie z liczbą oczekiwanych odpowiedzi — działa także dla
    // odpowiedzi wieloramkowych, więc adapter nie czeka na timeout magistrali przy żadnym zapytaniu
    if (_stnId != null && _isCan && _engineHeader != null) {
      await _setHeader(_engineHeader!);
      final raw = await _sendCommand("STPX D:0100,R:1");
      _stpxSupported = ElmParser.parse(raw, _bus).any((r) => r.matches(0x41, [0x00]));
    }

    // Kilka PIDów w jednym zapytaniu (SAE J1979 na CAN pozwala do 6) — kilkukrotnie
    // szybsze logowanie. Sprawdzamy na obrotach i prędkości (obsługuje je prawie każde auto).
    if (_isCan && _supportedPids.contains(0x0C) && _supportedPids.contains(0x0D)) {
      final r = await _query("010C0D");
      final data = r.where((e) => e.data.isNotEmpty && e.data[0] == 0x41).firstOrNull;
      final split = data != null ? ElmParser.splitMultiPid(data.data) : null;
      _multiPidSupported = split != null && split.containsKey(0x0C) && split.containsKey(0x0D);
    }

    // Ciśnienie atmosferyczne — do przeliczenia MAP na doładowanie względne
    if (_supportedPids.contains(0x33)) {
      final baro = await _readMode01Raw(0x33);
      if (baro != null && baro.isNotEmpty && baro[0] > 50) _baroKpa = baro[0].toDouble();
    }

    _updateStatus(ObdConnectionStatus.initializing, "Odczyt danych pojazdu (VIN, sterownik)...");
    await readVehicleInfo();

    _updateStatus(ObdConnectionStatus.initializing, "Sprawdzanie parametrów zadanych i rzeczywistych...");
    await _discoverChannels();

    if (_vehicleInfo != null && _vehicleInfo!.profile != VehicleProfile.generic) {
      _updateStatus(ObdConnectionStatus.initializing, "Sprawdzanie parametrów producenta (UDS)...");
      await _probeExtendedPids(_vehicleInfo!.profile);
    }

    if (importedPids.isNotEmpty) {
      _updateStatus(ObdConnectionStatus.initializing, "Sprawdzanie zaimportowanych definicji (${importedPids.length})...");
      await _probeImported();
    }

    _adapterInfo["Sterownik silnika"] = _engineEcu ?? "—";
    _adapterInfo["Szybkie zapytania STPX"] = _stpxSupported ? "tak" : "nie";
    _adapterInfo["Kilka PID-ów w zapytaniu"] = _multiPidSupported ? "tak" : "nie";
    _adapterInfo["Liczba odpowiedzi (np. 010C1)"] = _responseCountSupported ? "tak" : "nie";
    _adapterInfo["Obsługiwane PID-y Mode 01"] = "${_supportedPids.length}";

    if (!_hasTransport) return false;
    final ecuTxt = _engineEcu != null ? " | ECU $_engineEcu" : "";
    _updateStatus(
      ObdConnectionStatus.connected,
      "Połączono ($transportLabel) • ${_discoveredPids.length} parametrów$ecuTxt | ${_vehicleInfo?.modelName ?? 'Pojazd'}",
    );
    return true;
  }

  bool _isSupportedByMask(ObdPid pid) {
    final mid = pid.mode06Mid;
    if (mid != null) return _supportedMode06.contains(mid);
    final n = pid.mode01Pid;
    if (n == null) return false;
    return _supportedPids.isEmpty || _supportedPids.contains(n);
  }

  /// Wybiera źródło każdego kanału. Dla kanałów z kilkoma możliwymi PIDami
  /// (np. BOOST: 70 → 87 → 0B) bierze pierwszy, który ECU obsługuje. PIDy
  /// wielowartościowe są odczytywane raz, żeby sprawdzić bity obsługi —
  /// np. PID 70 może podawać rzeczywiste doładowanie, ale nie zadane.
  Future<void> _discoverChannels() async {
    final rawCache = <String, List<int>?>{};
    final list = <ObdPid>[];
    final seen = <String>{};

    for (final pid in ObdPid.standardPids) {
      if (seen.contains(pid.shortName) || !_isSupportedByMask(pid)) continue;
      if (pid.hasSupportByte) {
        if (!rawCache.containsKey(pid.code)) {
          rawCache[pid.code] = await _readPayload(pid);
        }
        final raw = rawCache[pid.code];
        if (raw == null || !pid.decoder(raw).isFinite) continue;
      }
      seen.add(pid.shortName);
      list.add(pid);
    }
    _discoveredPids = list;
  }

  /// Parametry producenta (UDS / Mode 22) — uzupełniają kanały, których nie ma
  /// w standardzie OBD-II (np. zadane doładowanie w benzynie). Każdy jest
  /// sprawdzany: odpowiedź pozytywna (62), wiarygodna wartość po przeliczeniu.
  Future<void> _probeExtendedPids(VehicleProfile profile) async {
    if (_bus != ObdBusType.can11) return;
    final seen = _discoveredPids.map((p) => p.shortName).toSet();
    for (final ep in ExtendedPid.channelsFor(profile)) {
      if (!_hasTransport) return;
      if (seen.contains(ep.shortName)) continue; // standard OBD-II ma pierwszeństwo
      if (ep.canHeader != null && ep.canHeader!.length != 3) continue;

      final payload = await _readPayload(ep);
      if (payload == null) continue;
      final raw = ep.decoder(payload);
      if (!raw.isFinite) continue;

      if (ep.kind == UdsValueKind.boostPressure) {
        final scale = _detectPressureScale(raw);
        if (scale == null) continue;
        _udsPressureScale["${ep.requestCommand}|${ep.shortName}"] = scale;
      }
      final value = _transform(ep, raw);
      if (value == null || !_isPlausible(ep.shortName, value)) continue;

      _discoveredPids.add(ep);
      seen.add(ep.shortName);
    }
  }

  /// Definicje zaimportowane przez użytkownika (pliki CSV Torque) — sprawdzane przy
  /// każdym połączeniu; do logowania trafiają tylko te, na które auto odpowiada.
  List<ExtendedPid> importedPids = [];

  /// Sprawdza zaimportowane definicje w trakcie połączenia (np. zaraz po imporcie).
  /// Zwraca liczbę parametrów, które auto obsługuje.
  Future<int> probeImportedNow() async {
    if (_status != ObdConnectionStatus.connected) return 0;
    final before = _discoveredPids.length;
    await _probeImported();
    notifyListeners();
    return _discoveredPids.length - before;
  }

  Future<void> _probeImported() async {
    _discoveredPids.removeWhere((p) => p is ExtendedPid && p.profile == VehicleProfile.custom);
    final seen = _discoveredPids.map((p) => p.shortName).toSet();
    final groups = <String, List<ExtendedPid>>{};
    for (final p in importedPids) {
      groups.putIfAbsent("${p.canHeader ?? ''}|${p.requestCommand}", () => []).add(p);
    }
    for (final group in groups.values.take(200)) {
      if (!_hasTransport) return;
      final candidates = group.where((p) => !seen.contains(p.shortName)).toList();
      if (candidates.isEmpty) continue;
      final payload = await _readPayload(candidates.first);
      if (payload == null) continue;
      for (final p in candidates) {
        final raw = p.decoder(payload);
        if (!raw.isFinite) continue;
        if (p.kind == UdsValueKind.boostPressure) {
          final scale = _detectPressureScale(raw);
          if (scale == null) continue;
          _udsPressureScale["${p.requestCommand}|${p.shortName}"] = scale;
        }
        final v = _transform(p, raw);
        if (v == null) continue;
        final range = (p.maxExpected - p.minExpected).abs();
        final plausible = p.shortName.startsWith("U_")
            ? v >= p.minExpected - range - 1 && v <= p.maxExpected + range + 1
            : _isPlausible(p.shortName, v);
        if (!plausible) continue;
        _discoveredPids.add(p);
        seen.add(p.shortName);
      }
    }
  }

  /// Skala ciśnienia doładowania z UDS wykrywana przy połączeniu (silnik stoi lub
  /// pracuje na jałowym, więc ciśnienie ≈ atmosferyczne): wartość × skala = kPa
  /// bezwzględne. 0 oznacza, że ECU podaje już nadciśnienie w bar.
  final Map<String, double> _udsPressureScale = {};

  static double? _detectPressureScale(double v) {
    for (final scale in [1.0, 0.1, 100.0, 0.01]) {
      final kpa = v * scale;
      if (kpa >= 60 && kpa <= 140) return scale;
    }
    if (v.abs() <= 0.4) return 0; // już względne, w bar
    return null;
  }

  static bool _isPlausible(String key, double v) {
    switch (key) {
      case "BOOST":
      case "TARGET_BOOST":
        return v >= -1.0 && v <= 3.5;
      case "F_RAIL":
      case "RAIL_TGT":
        return v >= 0 && v <= 3000;
      case "LAMBDA":
      case "LAMBDA_CMD":
        return v >= 0.5 && v <= 15;
      case "IGN":
        return v >= -30 && v <= 70;
      case "EGT":
        return v >= -40 && v <= 1200;
      default:
        return v.abs() < 1e6;
    }
  }

  double? _transform(ObdPid pid, double raw) {
    if (!raw.isFinite) return null;
    if (pid is ExtendedPid) {
      switch (pid.kind) {
        case UdsValueKind.boostPressure:
          final scale = _udsPressureScale["${pid.requestCommand}|${pid.shortName}"];
          if (scale == null) return null;
          if (scale == 0) return raw;
          return (raw * scale - (_baroKpa ?? 101.3)) / 100.0;
        case UdsValueKind.railPressure:
          final unit = ExtendedPid.rawUnitOf(pid).toLowerCase();
          if (unit == "kpa") return raw / 100.0;
          if (unit == "mbar" || unit == "hpa") return raw / 1000.0;
          if (unit == "mpa") return raw * 10.0;
          return raw;
        case UdsValueKind.scaled:
          return raw * pid.scale + pid.offset;
        case UdsValueKind.raw:
          return raw;
      }
    }
    switch (pid.transform) {
      case ValueTransform.absKpaToRelBar:
        return (raw - (_baroKpa ?? 101.3)) / 100.0;
      case ValueTransform.none:
        return raw;
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

  /// Wysyła zapytanie danego PIDu i zwraca bajty danych (bez usługi i numeru PID),
  /// albo null, gdy ECU nie odpowiedziało poprawnie.
  Future<List<int>?> _readPayload(ObdPid pid) async {
    if (!_hasTransport) return null;
    final cmd = pid.command.toUpperCase();
    final header = pid is ExtendedPid ? pid.canHeader : null;
    if (cmd.length < 4 || cmd.length.isOdd || !RegExp(r'^[0-9A-F]+$').hasMatch(cmd)) return null;

    final service = int.parse(cmd.substring(0, 2), radix: 16);
    final id = [
      for (int i = 2; i < cmd.length; i += 2) int.parse(cmd.substring(i, i + 2), radix: 16),
    ];

    try {
      // Odpowiedzi Mode 06 i PIDy wielowartościowe bywają wieloramkowe —
      // wtedy bez skróconego oczekiwania na liczbę odpowiedzi.
      // Liczba oczekiwanych odpowiedzi tylko dla krótkich odpowiedzi Mode 01 — odpowiedzi
      // producenta (21xx/22xxxx) bywają wieloramkowe
      final single = service == 0x01 && !pid.hasSupportByte;
      final responses = await _query(cmd, header: header, singleFrame: single);
      final match = responses.where((r) => r.matches(service + 0x40, id)).firstOrNull;
      if (match == null) return null;
      // Mode 06: rekordy testów zaczynają się od MID, więc zostawiamy go w danych
      final payload = service == 0x06 ? match.data.sublist(1) : match.data.sublist(1 + id.length);
      return payload.isEmpty ? null : payload;
    } catch (_) {
      return null;
    }
  }

  /// Odczytuje wartość czujnika. Zwraca null, gdy ECU nie odpowiedziało
  /// poprawnie — taka próbka jest pomijana zamiast zapisywać fałszywe 0.
  Future<double?> readPid(ObdPid pid) async {
    if (_status != ObdConnectionStatus.connected) return null;
    final payload = await _readPayload(pid);
    if (payload == null) return null;
    return _transform(pid, pid.decoder(payload));
  }

  /// Odczytuje kilka kanałów naraz. Kanały dzielące to samo zapytanie
  /// (np. zadane i rzeczywiste doładowanie z PID 70) kosztują jedno zapytanie.
  Future<Map<String, double>> readPids(List<ObdPid> pids) async {
    final result = <String, double>{};
    if (_status != ObdConnectionStatus.connected) return result;

    final groups = <String, List<ObdPid>>{};
    for (final p in pids) {
      final key = "${p is ExtendedPid ? p.canHeader ?? '' : ''}|${p.command.toUpperCase()}";
      groups.putIfAbsent(key, () => []).add(p);
    }

    // Standardowe PIDy Mode 01 o znanej długości — pakujemy po 6 w jedno zapytanie
    if (_multiPidSupported) {
      final batchable = <int, List<ObdPid>>{};
      groups.removeWhere((key, group) {
        final pid = group.first;
        final n = pid.mode01Pid;
        if (pid is ExtendedPid || n == null || !ElmParser.mode01DataLength.containsKey(n)) return false;
        batchable[n] = group;
        return true;
      });
      final numbers = batchable.keys.toList();
      for (int i = 0; i < numbers.length; i += 6) {
        if (_status != ObdConnectionStatus.connected) break;
        final batch = numbers.sublist(i, i + 6 > numbers.length ? numbers.length : i + 6);
        final split = await _readMultiPid(batch);
        for (final n in batch) {
          final payload = split?[n];
          if (payload == null) {
            // Sterownik pominął PID albo zapytanie się nie udało — spróbuj pojedynczo
            if (split == null) groups["|01${n.toRadixString(16).padLeft(2, '0').toUpperCase()}"] = batchable[n]!;
            continue;
          }
          for (final p in batchable[n]!) {
            final v = _transform(p, p.decoder(payload));
            if (v != null) result[p.shortName] = v;
          }
        }
      }
    }

    for (final group in groups.values) {
      if (_status != ObdConnectionStatus.connected) break;
      final payload = await _readPayload(group.first);
      if (payload == null) continue;
      for (final p in group) {
        final v = _transform(p, p.decoder(payload));
        if (v != null) result[p.shortName] = v;
      }
    }
    // Aktualne ciśnienie atmosferyczne poprawia przeliczanie doładowania
    final baro = result["BARO"];
    if (baro != null && baro > 50 && baro < 120) _baroKpa = baro;
    return result;
  }

  Future<Map<int, List<int>>?> _readMultiPid(List<int> pids) async {
    final cmd = "01${pids.map((n) => n.toRadixString(16).padLeft(2, '0').toUpperCase()).join()}";
    final responses = await _query(cmd);
    final data = responses.where((e) => e.data.isNotEmpty && e.data[0] == 0x41).firstOrNull;
    final split = data != null ? ElmParser.splitMultiPid(data.data) : null;
    if (split == null || split.isEmpty) {
      // Po kilku nieudanych próbach wracamy na stałe do pojedynczych zapytań
      if (++_multiPidFailures >= 3) _multiPidSupported = false;
      return null;
    }
    _multiPidFailures = 0;
    return split;
  }

  bool get multiPidEnabled => _multiPidSupported;
  bool get stpxEnabled => _stpxSupported;
  String? get stnId => _stnId;

  /// Szczegóły adaptera i wykrytych możliwości (do ekranu informacji i zgłoszeń problemów).
  Map<String, String> get adapterInfo => Map.unmodifiable(_adapterInfo);

  Future<void> _applyFormatting() async {
    await _sendCommand("ATL0"); // bez dodatkowych LF
    await _sendCommand("ATS1"); // spacje między bajtami
    await _sendCommand("ATH1"); // nagłówki ON — rozróżniamy sterowniki
    await _sendCommand("ATCAF1"); // automatyczne formatowanie ISO-TP
    await _sendCommand("ATAT1"); // adaptacyjny timeout
  }

  // ===========================================================================
  // Skan wszystkich modułów VAG (UDS)
  // ===========================================================================

  /// Czy można wykonać skan modułów VAG (auto VAG na CAN 11-bit).
  bool get canScanVagModules =>
      _status == ObdConnectionStatus.connected &&
      _bus == ObdBusType.can11 &&
      _vehicleInfo?.profile == VehicleProfile.vag;

  /// Odczytuje kody błędów ze wszystkich modułów VAG adresowanych przez UDS (usługa 19 02),
  /// podobnie jak Auto-Scan w VCDS. Moduły, które nie odpowiadają, są pomijane — w autach
  /// starszych platform (PQ) wiele modułów używa innego protokołu (TP2.0).
  Future<List<ModuleScanResult>> scanVagModules({
    void Function(int done, int total, VagModule module)? onProgress,
    List<VagModule> modules = VagModule.all,
  }) async {
    final results = <ModuleScanResult>[];
    if (!canScanVagModules) return results;
    try {
      // Sterowanie przepływem dla długich odpowiedzi (inne adresy niż 7E0/7E8)
      await _sendCommand("ATFCSD300000");
      await _sendCommand("ATFCSM1");
      for (int i = 0; i < modules.length; i++) {
        if (!_hasTransport) break;
        final m = modules[i];
        onProgress?.call(i, modules.length, m);
        await _sendCommand("ATSH${m.requestId}");
        _activeHeader = m.requestId;
        await _sendCommand("ATFCSH${m.requestId}");
        await _sendCommand("ATCRA${m.responseId}");
        final raw = await _sendCommand("1902FF", timeout: const Duration(seconds: 3));
        final resp = ElmParser.parse(raw, _bus).where((r) => r.ecu == m.responseId).firstOrNull;
        if (resp == null) {
          results.add(ModuleScanResult(m, responded: false, dtcs: const []));
          continue;
        }
        final dtcs = [
          for (final (code, ftb, pending) in ElmParser.decodeUdsDtcs(resp.data))
            DtcCode.getByCode(code, profile: VehicleProfile.vag)
                .withSource(ecuLabel: "${m.name} (${m.requestId}) • typ usterki ${ftb.toRadixString(16).padLeft(2, '0').toUpperCase()}", pending: pending),
        ];
        results.add(ModuleScanResult(m, responded: true, dtcs: dtcs));
      }
      if (modules.isNotEmpty) onProgress?.call(modules.length, modules.length, modules.last);
    } finally {
      // Przywróć normalny tryb: odbiór wszystkich ramek, domyślne sterowanie przepływem
      await _sendCommand("ATCRA");
      await _sendCommand("ATFCSM0");
      _activeHeader = null;
    }
    return results;
  }

  /// Odczytuje kody usterek z modułów VAG starszych platform (PQ) przez TP2.0 / KWP2000.
  /// Adapter jest na czas skanu przełączany na surowy CAN (protokół użytkownika B),
  /// a potem przywracany do normalnej pracy.
  Future<List<ModuleScanResult>> scanVagTp20Modules({
    void Function(int done, int total, String moduleName)? onProgress,
    List<VagTp20Module> modules = VagTp20Module.all,
  }) async {
    final results = <ModuleScanResult>[];
    if (!canScanVagModules) return results;
    final tp = Tp20Client((cmd, {timeout = const Duration(seconds: 4)}) => _sendCommand(cmd, timeout: timeout));
    try {
      await tp.enterRawMode();
      for (int i = 0; i < modules.length; i++) {
        if (!_hasTransport) break;
        final m = modules[i];
        onProgress?.call(i, modules.length, m.name);
        final descriptor = VagModule(m.name, "TP2.0 ${m.addressHex}", m.addressHex, "");
        bool opened = false;
        try {
          opened = await tp.open(m.address);
          if (!opened) {
            results.add(ModuleScanResult(descriptor, responded: false, dtcs: const []));
            continue;
          }
          await tp.startSession();
          final ident = await tp.identification();
          final faults = await tp.readFaults() ?? const <(int, int)>[];
          final dtcs = [
            for (final (code, status) in faults)
              DtcCode.fromVagFault(code, obdCode: Tp20Client.vagToObdCode(code)).withSource(
                ecuLabel: "${m.name} (adres ${m.addressHex}, TP2.0) • status ${status.toRadixString(16).padLeft(2, '0').toUpperCase()}",
              ),
          ];
          results.add(ModuleScanResult(descriptor, responded: true, dtcs: dtcs, identification: ident));
        } on Tp20Exception catch (_) {
          results.add(ModuleScanResult(descriptor, responded: opened, dtcs: const []));
        } finally {
          if (opened) await tp.close();
        }
      }
      if (modules.isNotEmpty) onProgress?.call(modules.length, modules.length, modules.last.name);
    } finally {
      // Powrót do normalnej pracy: protokół z autodetekcji, formatowanie, domyślny timeout
      await _sendCommand("ATSP$_protocolNumber");
      await _applyFormatting();
      await _sendCommand("ATST32");
      await _sendCommand("ATCRA");
      _activeHeader = null;
    }
    return results;
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
          result.add(DtcCode.getByCode(code, profile: _vehicleInfo?.profile).withSource(ecuLabel: _ecuLabel(r.ecu), pending: pending));
        }
      }
      if (mode == "03" && !anyValidResponse) return null;
    }
    return result;
  }

  /// Kasuje kody błędów (Mode 04). Zwraca true, jeśli sterownik potwierdził.
  /// Wymaga włączonego zapłonu przy wyłączonym silniku.
  Future<bool> clearDtcCodes() async {
    if (_status != ObdConnectionStatus.connected) return false;
    final responses = await _query("04", broadcast: true, timeout: const Duration(seconds: 6));
    return responses.any((r) => r.data.isNotEmpty && r.data[0] == 0x44);
  }

  // ===========================================================================
  // Dane pojazdu (Mode 09)
  // ===========================================================================

  Future<VehicleInfo?> readVehicleInfo() async {
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

/// Wynik odczytu jednego modułu podczas skanu VAG.
class ModuleScanResult {
  final VagModule module;
  final bool responded;
  final List<DtcCode> dtcs;

  /// Identyfikacja modułu (TP2.0: numer części i nazwa), jeśli dostępna.
  final String? identification;

  const ModuleScanResult(this.module, {required this.responded, required this.dtcs, this.identification});
}
