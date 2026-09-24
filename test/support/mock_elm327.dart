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

  MockElm327({this.bus = MockBus.can11, this.petrol = false});

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

  static Future<MockElm327> start({MockBus bus = MockBus.can11, bool petrol = false}) async {
    final mock = MockElm327(bus: bus, petrol: petrol);
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
      while (buffer.contains("\r")) {
        final idx = buffer.indexOf("\r");
        final cmd = buffer.substring(0, idx);
        buffer = buffer.substring(idx + 1);
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

  String _respond(String rawCmd) {
    final cmd = rawCmd.replaceAll(" ", "").toUpperCase();
    receivedCommands.add(cmd);
    final echo = _echo ? "$rawCmd\r" : "";
    return "$echo${_body(cmd)}\r\r>";
  }

  String _body(String cmd) {
    if (cmd.startsWith("AT")) return _atCommand(cmd.substring(2));

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
}
