import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Emulator adaptera ELM327 na TCP, udający samochód z dwoma sterownikami
/// na CAN 11-bit 500k: silnik (7E8) i skrzynia biegów (7E9) — tak jak
/// VW Touran 2.0 TDI, na którym zgłoszono problem.
///
/// Odpowiedzi są wysyłane w małych kawałkach (jak przez BLE), obsługiwane są
/// nagłówki (ATH1/ATH0), ATSH (adresowanie fizyczne), liczba odpowiedzi
/// ("01001") oraz ISO-TP dla wiadomości wieloramkowych.
class MockElm327 {
  late final ServerSocket _server;
  final List<String> receivedCommands = [];

  bool _echo = true;
  bool _headers = false;
  bool _spaces = true;
  bool _searched = false;
  String _header = "7DF";

  /// Kody błędów zapisane w sterowniku silnika (Mode 03), np. [[0x00, 0x87]] = P0087.
  List<List<int>> engineDtcs = [];

  /// Symuluje wyłączony zapłon: adapter odpowiada, ale żaden sterownik nie.
  bool ignitionOff = false;

  /// Obroty zwracane przez ECU silnika.
  double rpm = 850;

  int get port => _server.port;

  static const vin = "WVGZZZ1TZFW011407";

  static Future<MockElm327> start() async {
    final mock = MockElm327();
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

    final targets = <String>[];
    if (_header == "7DF") {
      targets.addAll(["7E8", "7E9"]);
    } else if (_header == "7E0") {
      targets.add("7E8");
    } else if (_header == "7E1") {
      targets.add("7E9");
    }

    final lines = <String>[];
    for (final ecu in targets) {
      final data = ecu == "7E8" ? _engine(request) : _transmission(request);
      if (data != null) lines.addAll(_format(ecu, data));
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
      _header = "7DF";
      return "\r\rELM327 v1.5";
    }
    if (at == "I") return "ELM327 v1.5";
    if (at == "E0") _echo = false;
    if (at == "E1") _echo = true;
    if (at == "H1") _headers = true;
    if (at == "H0") _headers = false;
    if (at == "S0") _spaces = false;
    if (at == "S1") _spaces = true;
    if (at == "DPN") return "A6";
    if (at == "DP") return "AUTO, ISO 15765-4 (CAN 11/500)";
    if (at == "RV") return "14.5V";
    if (at.startsWith("SH")) _header = at.substring(2);
    return "OK";
  }

  String _hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();

  List<String> _format(String ecu, List<int> data) {
    String line(List<int> frame) {
      final parts = [if (_headers) ecu, ...frame.map(_hex)];
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

  List<int>? _engine(List<int> req) {
    if (req.isEmpty) return null;
    switch (req[0]) {
      case 0x01:
        if (req.length < 2) return null;
        final pid = req[1];
        if (pid % 0x20 == 0) return [0x41, pid, ..._mask(pid, engineSupported)];
        if (!engineSupported.contains(pid)) return null;
        switch (pid) {
          case 0x0C:
            final raw = (rpm * 4).round();
            return [0x41, 0x0C, raw >> 8, raw & 0xFF];
          case 0x0B:
            return [0x41, 0x0B, 101];
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
            return [0x41, 0x10, 0x01, 0xF4]; // 5.00 g/s
          case 0x11:
            return [0x41, 0x11, 250]; // klapa dławiąca diesla — prawie otwarta
          case 0x49:
            return [0x41, 0x49, 38]; // pedał w spoczynku (~15%)
          case 0x51:
            return [0x41, 0x51, 4]; // Diesel
          case 0x31:
            return [0x41, 0x31, 0x04, 0xD2]; // 1234 km
          case 0x21:
            return [0x41, 0x21, 0x00, 0x00];
          case 0x23:
            return [0x41, 0x23, 0x0B, 0xB8]; // 3000 * 10 kPa = 300 bar
          case 0x7A:
            return [0x41, 0x7A, 0x01, 0x00, 0xC8]; // 2.00 kPa
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
            return [0x49, 0x04, 0x01, ..._ascii("03L906023PJ", 16)];
          case 0x0A:
            return [0x49, 0x0A, 0x01, ..._ascii("ECM\u0000-EngineControl", 20)];
        }
        return null;
      case 0x22:
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
