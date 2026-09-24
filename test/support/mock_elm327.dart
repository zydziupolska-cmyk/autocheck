import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Magistrala emulowanego samochodu.
enum MockBus {
  /// ISO 15765-4 CAN 11-bit (większość aut od ok. 2008 r.)
  can11,

  /// ISO 15765-4 CAN 29-bit (np. część aut GM)
  can29,

  /// ISO 14230-4 KWP2000 (starsze auta, bez ISO-TP, 3 bajty nagłówka + suma kontrolna)
  kwp,
}

/// Emulator adaptera ELM327 na TCP, udający samochód z dwoma sterownikami:
/// silnik i skrzynia biegów (domyślnie VW Touran 2.0 TDI na CAN 11-bit,
/// na którym zgłoszono problem). Dostępne warianty: benzyna z licznikami
/// wypadania zapłonów (Mode 06), CAN 29-bit i KWP2000.
///
/// Odpowiedzi są wysyłane w małych kawałkach (jak przez BLE), obsługiwane są
/// nagłówki (ATH1/ATH0), ATSH (adresowanie fizyczne), liczba odpowiedzi
/// ("01001") oraz ISO-TP dla wiadomości wieloramkowych.
class MockElm327 {
  final MockBus bus;
  final bool petrol;

  /// Adapter z układem STN (komendy ST: STI, STDI, STPX) — np. vLinker, OBDLink.
  final bool stn;

  /// Zachowanie części klonów (np. vLinker FS): ATSP przywraca domyślne formatowanie
  /// (nagłówki i spacje wyłączone).
  final bool resetsFormattingOnProtocol;

  MockElm327({this.bus = MockBus.can11, this.petrol = false, this.stn = false, this.resetsFormattingOnProtocol = false});

  late final ServerSocket _server;
  final List<String> receivedCommands = [];

  bool _echo = true;
  bool _headers = false;
  bool _spaces = true;
  bool _searched = false;
  late String _header = _defaultHeader;

  String get _defaultHeader => bus == MockBus.can29 ? "DB33F1" : (bus == MockBus.kwp ? "" : "7DF");

  /// Narastający licznik wypadania zapłonów cylindra 3 (Mode 06, MID $A4).
  int misfireCyl3 = 0;

  /// Kody błędów zapisane w sterowniku silnika (Mode 03), np. [[0x00, 0x87]] = P0087.
  List<List<int>> engineDtcs = [];

  /// Symuluje wyłączony zapłon: adapter odpowiada, ale żaden sterownik nie.
  bool ignitionOff = false;

  /// Dodatkowe moduły VAG na CAN 11-bit: adres zapytania → (adres odpowiedzi, rekordy DTC UDS
  /// po 4 bajty: 3 bajty kodu + status).
  final Map<String, (String, List<List<int>>)> vagModules = {};

  bool debugLog = false;

  /// Moduły VAG na TP2.0 (starsze platformy): adres → lista (kod VAG, status).
  final Map<int, List<(int, int)>> tp20Modules = {};

  /// Moduły TP2.0, które na odczyt kodów najpierw odpowiadają „czekaj” (7F 18 78).
  final Set<int> tp20SlowModules = {};

  // --- Stan TP2.0 (surowy CAN, protokół użytkownika B) ---
  bool _rawMode = false;
  int? _tpDest;
  int _tpEcuSeq = 0;
  final List<int> _tpIncoming = [];
  final List<List<int>> _tpOutQueue = [];
  bool _tpPending = false;
  List<int>? _tpPendingResponse;

  /// Dodatkowe identyfikatory UDS (usługa 22) sterownika silnika: "1234" → bajty danych.
  final Map<String, List<int>> udsDids = {};

  /// Ruch na magistrali oddawany w trybie podsłuchu (ATMA/STMA) — linie jak z adaptera.
  final List<String> monitorTraffic = [];
  /// Po tylu liniach adapter zgłasza BUFFER FULL i wraca do '>' (raz).
  int? monitorBufferFullAfter;
  bool _monitoring = false;
  int _monitorPos = 0;
  int _monitorStarts = 0;
  int get monitorStarts => _monitorStarts;

  /// Czy sterownik obsługuje zapytania o kilka PIDów naraz (większość aut na CAN tak).
  bool multiPidSupported = true;

  /// Obroty zwracane przez ECU silnika.
  double rpm = 850;

  // --- Stan silnika sterowany przez testy (np. symulacja przyspieszenia) ---
  double pedalPct = 0; // pedał gazu 0-100%
  double mapKpa = 101; // ciśnienie w kolektorze (bezwzględne)
  double targetKpa = 101; // doładowanie zadane (bezwzględne)
  double mafGs = 5.0;
  double dpfDpKpa = 2.0;
  double railTgtBar = 300;
  double railActBar = 298;
  double vgtCmdPct = 50;
  double vgtActPct = 50;
  double egrCmdPct = 30;
  double egrActPct = 30;

  int get port => _server.port;

  static const vin = "WVGZZZ1TZFW011407";

  static Future<MockElm327> start({
    MockBus bus = MockBus.can11,
    bool petrol = false,
    bool stn = false,
    bool resetsFormattingOnProtocol = false,
  }) async {
    final mock = MockElm327(bus: bus, petrol: petrol, stn: stn, resetsFormattingOnProtocol: resetsFormattingOnProtocol);
    mock._server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    mock._server.listen(mock._handleClient);
    return mock;
  }

  Future<void> close() => _server.close();

  void _handleClient(Socket client) {
    var buffer = "";
    client.done.catchError((_) => null);
    client.listen(onError: (_) {}, (data) async {
      buffer += latin1.decode(data);
      if (_monitoring && buffer.isNotEmpty) {
        // Dowolny znak przerywa podsłuch; sam znak jest pomijany
        _monitoring = false;
        buffer = buffer.substring(1);
        try {
          client.add(latin1.encode("STOPPED\r\r>"));
          await client.flush();
        } catch (_) {
          return;
        }
      }
      while (buffer.contains("\r")) {
        final idx = buffer.indexOf("\r");
        final cmd = buffer.substring(0, idx);
        buffer = buffer.substring(idx + 1);
        final norm = cmd.replaceAll(" ", "").toUpperCase();
        if (norm == "ATMA" || (stn && norm == "STMA")) {
          receivedCommands.add(norm);
          _monitoring = true;
          _monitorStarts++;
          _streamMonitor(client);
          continue;
        }
        final response = _respond(cmd);
        // Wysyłaj w kawałkach po 20 bajtów (jak notyfikacje BLE)
        final bytes = latin1.encode(response);
        try {
          for (int i = 0; i < bytes.length; i += 20) {
            client.add(bytes.sublist(i, i + 20 > bytes.length ? bytes.length : i + 20));
            await client.flush();
          }
        } catch (_) {
          return; // klient się rozłączył
        }
      }
    });
  }

  Future<void> _streamMonitor(Socket client) async {
    try {
      while (_monitoring && _monitorPos < monitorTraffic.length) {
        final limit = monitorBufferFullAfter;
        if (limit != null && _monitorPos == limit) {
          monitorBufferFullAfter = null;
          _monitoring = false;
          client.add(latin1.encode("BUFFER FULL\r\r>"));
          await client.flush();
          return;
        }
        client.add(latin1.encode("${monitorTraffic[_monitorPos++]}\r"));
        await client.flush();
        await Future.delayed(const Duration(milliseconds: 1));
      }
    } catch (_) {}
  }

  String _respond(String rawCmd) {
    final cmd = rawCmd.replaceAll(" ", "").toUpperCase();
    receivedCommands.add(cmd);
    if (debugLog) print(">> $cmd  (header $_header, raw $_rawMode)");
    final echo = _echo ? "$rawCmd\r" : "";
    return "$echo${_body(cmd)}\r\r>";
  }

  String _body(String cmd) {
    if (cmd.startsWith("AT")) return _atCommand(cmd.substring(2));
    if (_rawMode) return _tp20Frame(cmd);
    if (cmd.startsWith("ST")) {
      if (!stn) return "?";
      if (cmd == "STI") return "STN2255 v5.10.3";
      if (cmd == "STDI") return "vLinker MC+ (emulator)";
      final m = RegExp(r'^STPXD:([0-9A-F]+)(?:,R:(\d+))?$').firstMatch(cmd);
      if (m != null) return _body(m.group(1)!);
      return "?";
    }

    var obd = cmd;
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(obd)) return "?";
    if (obd.length.isOdd) obd = obd.substring(0, obd.length - 1); // liczba odpowiedzi
    final request = [for (int i = 0; i < obd.length; i += 2) int.parse(obd.substring(i, i + 2), radix: 16)];

    if (ignitionOff) return "UNABLE TO CONNECT";

    // (adres odpowiedzi, czy to silnik)
    final targets = <(String, bool)>[];
    switch (bus) {
      case MockBus.can11:
        if (_header == "7DF" || _header == "7E0") targets.add(("7E8", true));
        if (_header == "7DF" || _header == "7E1") targets.add(("7E9", false));
        final module = vagModules[_header];
        if (module != null) {
          if (request.length >= 2 && request[0] == 0x19 && request[1] == 0x02) {
            return _format(module.$1, [0x59, 0x02, 0xFF, for (final r in module.$2) ...r]).join("\r");
          }
          return "NO DATA";
        }
      case MockBus.can29:
        if (_header == "DB33F1" || _header == "DA10F1") targets.add(("18DAF110", true));
        if (_header == "DB33F1" || _header == "DA18F1") targets.add(("18DAF118", false));
      case MockBus.kwp:
        targets.add(("10", true));
    }

    final lines = <String>[];
    for (final (ecu, isEngine) in targets) {
      final data = isEngine ? _engine(request) : _transmission(request);
      if (data != null) lines.addAll(bus == MockBus.kwp ? _formatKwp(ecu, data) : _format(ecu, data));
    }
    var out = lines.isEmpty ? "NO DATA" : lines.join("\r");
    if (!_searched) {
      _searched = true;
      out = "SEARCHING...\r$out";
    }
    return out;
  }

  String _atCommand(String at) {
    if (at == "Z") {
      _echo = true;
      _headers = false;
      _header = _defaultHeader;
      return "\r\rELM327 v1.5";
    }
    if (at == "I") return "ELM327 v1.5";
    if (at == "E0") _echo = false;
    if (at == "E1") _echo = true;
    if (at == "H1") _headers = true;
    if (at == "H0") _headers = false;
    if (at == "S0") _spaces = false;
    if (at == "S1") _spaces = true;
    if (at == "DPN") return {MockBus.can11: "A6", MockBus.can29: "A7", MockBus.kwp: "A5"}[bus]!;
    if (at == "DP") {
      return {
        MockBus.can11: "AUTO, ISO 15765-4 (CAN 11/500)",
        MockBus.can29: "AUTO, ISO 15765-4 (CAN 29/500)",
        MockBus.kwp: "AUTO, ISO 14230-4 (KWP FAST)",
      }[bus]!;
    }
    if (at == "RV") return "14.5V";
    if (at.startsWith("SH")) _header = at.substring(2);
    if (at == "SPB") _rawMode = true;
    if (at.startsWith("SP") && at != "SPB") _rawMode = false;
    if (at.startsWith("SP") && resetsFormattingOnProtocol) {
      _headers = false;
      _spaces = false;
    }
    return "OK";
  }

  String _hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();

  List<String> _format(String ecu, List<int> data) {
    String line(List<int> frame) {
      final headerParts = ecu.length == 8
          ? [for (int i = 0; i < 8; i += 2) ecu.substring(i, i + 2)]
          : [ecu];
      final parts = [if (_headers) ...headerParts, ...frame.map(_hex)];
      return _spaces ? parts.join(" ") : parts.join();
    }

    if (data.length <= 7) return [line([data.length, ...data])];
    final frames = <String>[];
    frames.add(line([0x10 | (data.length >> 8), data.length & 0xFF, ...data.sublist(0, 6)]));
    int seq = 1;
    for (int i = 6; i < data.length; i += 7) {
      final end = i + 7 > data.length ? data.length : i + 7;
      final chunk = data.sublist(i, end);
      while (chunk.length < 7) {
        chunk.add(0x00); // wypełnienie ramki
      }
      frames.add(line([0x20 | (seq & 0x0F), ...chunk]));
      seq++;
    }
    return frames;
  }

  /// KWP2000: bez ISO-TP. Każda linia to nagłówek (83 F1 10), maks. 7 bajtów danych
  /// i suma kontrolna. Mode 03/07 bez licznika kodów (3 kody na linię), Mode 09
  /// dzielony na linie z numerem sekwencji i 4 bajtami danych.
  List<String> _formatKwp(String ecu, List<int> data) {
    final payloads = <List<int>>[];
    final service = data[0];
    if (service == 0x43 || service == 0x47) {
      final codes = data.sublist(2); // bez licznika — w KWP go nie ma
      final padded = [...codes];
      while (padded.isEmpty || padded.length % 6 != 0) {
        padded.add(0);
      }
      for (int i = 0; i < padded.length; i += 6) {
        payloads.add([service, ...padded.sublist(i, i + 6)]);
      }
    } else if (service == 0x49 && data.length > 7) {
      final body = data.sublist(3);
      while (body.length % 4 != 0) {
        body.insert(0, 0);
      }
      int seq = 1;
      for (int i = 0; i < body.length; i += 4) {
        payloads.add([0x49, data[1], seq++, ...body.sublist(i, i + 4)]);
      }
    } else {
      payloads.add(data);
    }
    return [
      for (final payload in payloads)
        () {
          final bytes = [0x83, 0xF1, int.parse(ecu, radix: 16), ...payload];
          bytes.add(bytes.fold<int>(0, (a, b) => a + b) & 0xFF);
          final parts = (_headers ? bytes : bytes.sublist(3, bytes.length - 1)).map(_hex);
          return _spaces ? parts.join(" ") : parts.join();
        }(),
    ];
  }

  static List<int> _mask(int base, Set<int> supported) {
    final bytes = [0, 0, 0, 0];
    for (final pid in supported) {
      final offset = pid - base - 1;
      if (offset < 0 || offset >= 32) continue;
      bytes[offset ~/ 8] |= 0x80 >> (offset % 8);
    }
    return bytes;
  }

  static List<int> _ascii(String s, int len) {
    final out = s.codeUnits.toList();
    while (out.length < len) {
      out.add(0);
    }
    return out;
  }

  // Silnik diesla EA189 — brak kąta zapłonu, AFR, STFT/LTFT
  static const engineSupported = {
    0x04, 0x05, 0x0B, 0x0C, 0x0D, 0x0F, 0x10, 0x11, 0x1C, 0x20,
    0x21, 0x23, 0x2C, 0x2D, 0x31, 0x33, 0x40,
    0x49, 0x51, 0x60,
    0x78, 0x7A,
  };

  // Dodatkowe PIDy silnika benzynowego: korekty paliwa i kąt zapłonu
  static const petrolExtra = {0x06, 0x07, 0x0E};

  // Mode 06: maski zakresów + liczniki wypadania zapłonów cylindrów 1-4 ($A2-$A5)
  static const mode06Supported = {0x01, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xA2, 0xA3, 0xA4, 0xA5};

  // Diesel EDC17: doładowanie zadane/rzeczywiste (70), szyna (6D), VGT (71), EGR (69),
  // ciśnienie spalin (73), moment żądany/rzeczywisty (61/62)
  static const dieselExtra = {0x61, 0x62, 0x69, 0x6D, 0x70, 0x71, 0x73};

  Set<int> get _supported => petrol ? {...engineSupported, ...petrolExtra} : {...engineSupported, ...dieselExtra};

  List<int> _u16(double v) {
    final i = v.round().clamp(0, 0xFFFF);
    return [i >> 8, i & 0xFF];
  }

  int _pct(double p) => (p * 255 / 100).round().clamp(0, 255);

  List<int> _misfireRecord(int mid, int count) => [
        mid, 0x0B, 0x24, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, // średnia z 10 cykli
        mid, 0x0C, 0x24, count >> 8, count & 0xFF, 0x00, 0x00, 0xFF, 0xFF, // bieżący cykl
      ];

  List<int>? _engine(List<int> req) {
    if (req.isEmpty) return null;
    // Zapytanie o kilka PIDów naraz: 01 0C 0D 0B ... → 41 0C dane 0D dane 0B dane ...
    if (req[0] == 0x01 && req.length > 2 && bus != MockBus.kwp) {
      if (!multiPidSupported) return null;
      final out = <int>[0x41];
      for (final pid in req.sublist(1)) {
        final single = _engine([0x01, pid]);
        if (single != null) out.addAll(single.sublist(1));
      }
      return out.length > 1 ? out : null;
    }
    switch (req[0]) {
      case 0x06:
        if (!petrol || bus == MockBus.kwp || req.length < 2) return null;
        final mid = req[1];
        if (mid % 0x20 == 0) return [0x46, mid, ..._mask(mid, mode06Supported)];
        if (mid >= 0xA2 && mid <= 0xA5) return [0x46, ..._misfireRecord(mid, mid == 0xA4 ? misfireCyl3 : 0)];
        return null;
      case 0x01:
        if (req.length < 2) return null;
        final pid = req[1];
        if (pid % 0x20 == 0) return [0x41, pid, ..._mask(pid, _supported)];
        if (!_supported.contains(pid)) return null;
        switch (pid) {
          case 0x06:
            return [0x41, 0x06, 128]; // STFT 0%
          case 0x07:
            return [0x41, 0x07, 133]; // LTFT +3.9%
          case 0x0E:
            return [0x41, 0x0E, 150]; // 11°
          case 0x0C:
            final raw = (rpm * 4).round();
            return [0x41, 0x0C, raw >> 8, raw & 0xFF];
          case 0x0B:
            return [0x41, 0x0B, mapKpa.round().clamp(0, 255)];
          case 0x70:
            return [0x41, 0x70, 0x03, ..._u16(targetKpa * 32), ..._u16(mapKpa * 32), 0, 0, 0, 0, 0];
          case 0x6D:
            return [0x41, 0x6D, 0x03, ..._u16(railTgtBar * 10), ..._u16(railActBar * 10), 0x50, 0, 0, 0, 0, 0];
          case 0x71:
            return [0x41, 0x71, 0x03, _pct(vgtCmdPct), _pct(vgtActPct), 0, 0, 0];
          case 0x69:
            return [0x41, 0x69, 0x03, _pct(egrCmdPct), _pct(egrActPct), 128, 0, 0, 0];
          case 0x73:
            return [0x41, 0x73, 0x01, ..._u16((mapKpa + 10) * 100), 0, 0];
          case 0x61:
            return [0x41, 0x61, (125 + pedalPct).round()];
          case 0x62:
            return [0x41, 0x62, (125 + pedalPct * 0.9).round()];
          case 0x33:
            return [0x41, 0x33, 99];
          case 0x0D:
            return [0x41, 0x0D, 0];
          case 0x05:
            return [0x41, 0x05, 130];
          case 0x0F:
            return [0x41, 0x0F, 60];
          case 0x04:
            return [0x41, 0x04, 51];
          case 0x10:
            return [0x41, 0x10, ..._u16(mafGs * 100)];
          case 0x11:
            return [0x41, 0x11, 250]; // klapa dławiąca diesla — prawie otwarta
          case 0x49:
            // czujnik pedału D: ok. 15% w spoczynku, ok. 80% przy pełnym wciśnięciu
            return [0x41, 0x49, ((15 + pedalPct * 0.65) * 255 / 100).round()];
          case 0x51:
            return [0x41, 0x51, petrol ? 1 : 4]; // Benzyna / Diesel
          case 0x31:
            return [0x41, 0x31, 0x04, 0xD2]; // 1234 km
          case 0x21:
            return [0x41, 0x21, 0x00, 0x00];
          case 0x23:
            return [0x41, 0x23, 0x0B, 0xB8]; // 3000 * 10 kPa = 300 bar
          case 0x7A:
            return [0x41, 0x7A, 0x01, ..._u16(dpfDpKpa * 100)];
          case 0x78:
            return [0x41, 0x78, 0x01, 0x10, 0x68, 0, 0, 0, 0, 0, 0]; // (4200/10)-40 = 380 °C
          default:
            return [0x41, pid, 0x00, 0x00];
        }
      case 0x03:
        return [0x43, engineDtcs.length, for (final d in engineDtcs) ...d];
      case 0x19:
        // UDS ReadDTCInformation (reportDTCByStatusMask): 3 bajty kodu + status 0x08 (potwierdzony)
        if (req.length >= 2 && req[1] == 0x02) {
          return [0x59, 0x02, 0xFF, for (final d in engineDtcs) ...[...d, 0x00, 0x08]];
        }
        return [0x7F, 0x19, 0x12];
      case 0x07:
        return [0x47, 0x00];
      case 0x04:
        engineDtcs = [];
        return [0x44];
      case 0x09:
        if (req.length < 2) return null;
        switch (req[1]) {
          case 0x02:
            return [0x49, 0x02, 0x01, ...vin.codeUnits];
          case 0x04:
            return [0x49, 0x04, 0x01, ..._ascii(petrol ? "04E906027HA" : "03L906023PJ", 16)];
          case 0x0A:
            return [0x49, 0x0A, 0x01, ..._ascii("ECM\u0000-EngineControl", 20)];
        }
        return null;
      case 0x22:
        if (req.length >= 3) {
          final did = "${_hex(req[1])}${_hex(req[2])}";
          final data = udsDids[did];
          if (data != null) return [0x62, req[1], req[2], ...data];
        }
        // UDS VAG (tylko wersja benzynowa): doładowanie rzeczywiste 202A i zadane 2029 w hPa
        if (petrol && req.length >= 3 && req[1] == 0x20 && (req[2] == 0x2A || req[2] == 0x29)) {
          final hPa = (req[2] == 0x2A ? mapKpa : targetKpa) * 10;
          return [0x62, 0x20, req[2], ..._u16(hPa * 10)]; // dekoder: (A*256+B)*0.1
        }
        return [0x7F, 0x22, 0x31]; // requestOutOfRange
    }
    return null;
  }

  List<int>? _transmission(List<int> req) {
    if (req.isEmpty) return null;
    switch (req[0]) {
      case 0x01:
        if (req.length < 2) return null;
        if (req[1] == 0x00) return [0x41, 0x00, ..._mask(0, {0x05, 0x0D})];
        if (req[1] == 0x0D) return [0x41, 0x0D, 0];
        return null;
      case 0x03:
        return [0x43, 0x00];
      case 0x07:
        return [0x47, 0x00];
      case 0x04:
        return [0x44];
      case 0x09:
        if (req.length >= 2 && req[1] == 0x0A) {
          return [0x49, 0x0A, 0x01, ..._ascii("TCM\u0000-TransmisCtrl", 20)];
        }
        if (req.length >= 2 && req[1] == 0x04) {
          return [0x49, 0x04, 0x01, ..._ascii("9978I0AM300064B", 16)];
        }
        return null;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Emulacja TP2.0 (moduł odbiera na 0x740, wysyła na 0x300)
  // ---------------------------------------------------------------------------

  String _tpLine(int id, List<int> data) {
    final parts = [id.toRadixString(16).padLeft(3, '0').toUpperCase(), ...data.map(_hex)];
    return _headers ? (_spaces ? parts.join(" ") : parts.join()) : data.map(_hex).join(_spaces ? " " : "");
  }

  String _tp20Frame(String hex) {
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(hex) || hex.length.isOdd) return "?";
    final d = [for (int i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

    if (_header == "200") {
      if (d.length == 7 && d[1] == 0xC0 && tp20Modules.containsKey(d[0])) {
        _tpDest = d[0];
        _tpEcuSeq = 0;
        _tpIncoming.clear();
        _tpOutQueue.clear();
        return _tpLine(0x200 + d[0], [0x00, 0xD0, 0x00, 0x03, 0x40, 0x07, 0x01]);
      }
      return "NO DATA";
    }
    if (_header != "740" || _tpDest == null) return "NO DATA";

    final op = d[0] >> 4;
    if (d[0] == 0xA0 || d[0] == 0xA3) {
      final lines = [_tpLine(0x300, [0xA1, 0x0F, 0x8A, 0xFF, 0x4A, 0xFF])];
      // Moduł, który wcześniej odpowiedział „czekaj”, teraz wysyła właściwą odpowiedź
      if (d[0] == 0xA3 && _tpPending && _tpPendingResponse != null) {
        _tpPending = false;
        _queueResponse(_tpPendingResponse!);
        lines.addAll(_flushQueue());
      }
      return lines.join("\r");
    }
    if (d[0] == 0xA8) {
      _tpDest = null;
      return _tpLine(0x300, [0xA8]);
    }
    if (op == 0xB) {
      final lines = _flushQueue();
      return lines.isEmpty ? "NO DATA" : lines.join("\r");
    }
    if (op <= 0x3) {
      _tpIncoming.addAll(d.sublist(1));
      final lines = <String>[];
      if (op == 0x0 || op == 0x1) lines.add(_tpLine(0x300, [0xB0 | ((d[0] + 1) & 0x0F)]));
      if (op == 0x1 || op == 0x3) {
        final len = (_tpIncoming[0] << 8) | _tpIncoming[1];
        final req = _tpIncoming.sublist(2, 2 + len);
        _tpIncoming.clear();
        final resp = _kwp(req);
        if (resp != null) {
          _queueResponse(resp);
          lines.addAll(_flushQueue());
        }
      }
      return lines.isEmpty ? "NO DATA" : lines.join("\r");
    }
    return "NO DATA";
  }

  List<int>? _kwp(List<int> req) {
    final dest = _tpDest!;
    if (req.length == 2 && req[0] == 0x10) return [0x50, req[1]];
    if (req.length == 2 && req[0] == 0x1A && req[1] == 0x9B) {
      final id = dest == 0x01 ? "03L906023PJ  R4 2,0L EDC G000SG  5201" : "1K0907379AC ESP MK60EC1  H30 0107";
      return [0x5A, 0x9B, ...id.codeUnits];
    }
    if (req.length == 4 && req[0] == 0x18) {
      final faults = tp20Modules[dest]!;
      final resp = [0x58, faults.length, for (final (code, status) in faults) ...[code >> 8, code & 0xFF, status]];
      if (tp20SlowModules.contains(dest)) {
        _tpPending = true;
        _tpPendingResponse = resp;
        return [0x7F, 0x18, 0x78];
      }
      return resp;
    }
    return [0x7F, req.isEmpty ? 0 : req[0], 0x11];
  }

  /// Dzieli odpowiedź na pakiety TP2.0; co 4. pakiet (i ostatni) wymaga ACK od testera.
  void _queueResponse(List<int> msg) {
    final payload = [msg.length >> 8, msg.length & 0xFF, ...msg];
    final chunks = [
      for (int i = 0; i < payload.length; i += 7) payload.sublist(i, i + 7 > payload.length ? payload.length : i + 7),
    ];
    for (int i = 0; i < chunks.length; i++) {
      final last = i == chunks.length - 1;
      final op = last ? 0x10 : ((i + 1) % 4 == 0 ? 0x00 : 0x20);
      _tpOutQueue.add([op | _tpEcuSeq, ...chunks[i]]);
      _tpEcuSeq = (_tpEcuSeq + 1) & 0x0F;
    }
  }

  /// Wysyła pakiety do pierwszego wymagającego ACK (włącznie).
  List<String> _flushQueue() {
    final lines = <String>[];
    while (_tpOutQueue.isNotEmpty) {
      final f = _tpOutQueue.removeAt(0);
      lines.add(_tpLine(0x300, f));
      if ((f[0] >> 4) & 0x2 == 0) break; // czeka na ACK
    }
    return lines;
  }
}
