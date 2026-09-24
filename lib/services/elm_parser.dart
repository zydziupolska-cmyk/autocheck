/// Parser odpowiedzi adaptera ELM327 / STN (vLinker) pracującego z nagłówkami (ATH1).
///
/// Adapter wysyła zapytanie OBD na magistralę, a odpowiedzieć może kilka
/// sterowników naraz (np. silnik 7E8 i skrzynia biegów 7E9). Bez nagłówków
/// ich odpowiedzi zlewają się w jeden ciąg bajtów, co daje fikcyjne kody
/// błędów i skaczące wartości czujników. Dlatego każdą ramkę przypisujemy do
/// nadawcy i składamy wiadomości wieloramkowe (ISO-TP) osobno dla każdego ECU.
library;

enum ObdBusType {
  /// ISO 15765-4 CAN, 11-bit (protokoły 6 i 8)
  can11,

  /// ISO 15765-4 CAN, 29-bit (protokoły 7 i 9)
  can29,

  /// J1850 / ISO 9141-2 / ISO 14230-4 (KWP) — nagłówek 3 bajty + suma kontrolna
  legacy,

  unknown,
}

/// Kompletna odpowiedź jednego sterownika.
class EcuResponse {
  /// Adres nadawcy, np. "7E8", "18DAF110" lub "10" (legacy).
  final String ecu;

  /// Dane usługi zaczynające się od bajtu odpowiedzi, np. [0x41, 0x0C, 0x1A, 0xF8].
  final List<int> data;

  const EcuResponse(this.ecu, this.data);

  bool get isNegative => data.isNotEmpty && data[0] == 0x7F;

  /// Czy odpowiedź dotyczy danej usługi i identyfikatora (np. 0x41 + [0x0C]).
  bool matches(int responseService, List<int> id) {
    if (data.length < 1 + id.length || data[0] != responseService) return false;
    for (int i = 0; i < id.length; i++) {
      if (data[1 + i] != id[i]) return false;
    }
    return true;
  }

  @override
  String toString() => "$ecu: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}";
}

class ElmParser {
  static final RegExp _hex = RegExp(r'^[0-9A-Fa-f]+$');

  /// Komunikaty adaptera, które nie niosą danych.
  static const List<String> _noiseMarkers = [
    "SEARCHING",
    "BUS INIT",
    "NO DATA",
    "NODATA",
    "UNABLE TO CONNECT",
    "CAN ERROR",
    "BUS ERROR",
    "BUS BUSY",
    "FB ERROR",
    "DATA ERROR",
    "STOPPED",
    "ERROR",
    "ELM",
    "STN",
    "OK",
    "?",
  ];

  /// Numer protokołu z odpowiedzi na ATDPN (np. "A6", "6", "A7") → typ magistrali.
  static ObdBusType busFromProtocolNumber(String dpn) {
    final clean = dpn.trim().toUpperCase().replaceAll(RegExp(r'[^0-9A-C]'), '');
    if (clean.isEmpty) return ObdBusType.unknown;
    final n = clean.length > 1 && clean.startsWith("A") ? clean.substring(1) : clean;
    switch (n) {
      case "6":
      case "8":
      case "B":
        return ObdBusType.can11;
      case "7":
      case "9":
      case "C":
        return ObdBusType.can29;
      case "1":
      case "2":
      case "3":
      case "4":
      case "5":
        return ObdBusType.legacy;
      default:
        return ObdBusType.unknown;
    }
  }

  /// Rozbija surową odpowiedź na linie danych (bez komunikatów statusu).
  static List<String> dataLines(String raw) {
    final result = <String>[];
    for (var line in raw.split(RegExp(r'[\r\n]+'))) {
      line = line.replaceAll('>', '').trim();
      if (line.isEmpty) continue;
      final upper = line.toUpperCase();
      if (_noiseMarkers.any(upper.contains)) {
        // "SEARCHING..." bywa doklejone na początku linii z danymi
        final stripped = upper.replaceAll("SEARCHING...", "").trim();
        if (stripped.isEmpty || _noiseMarkers.any(stripped.contains)) continue;
        line = stripped;
      }
      result.add(line);
    }
    return result;
  }

  /// Parsuje odpowiedź na listę kompletnych wiadomości — po jednej na sterownik.
  static List<EcuResponse> parse(String raw, ObdBusType bus) {
    final lines = dataLines(raw);
    if (lines.isEmpty) return const [];

    switch (bus) {
      case ObdBusType.can11:
      case ObdBusType.can29:
        final parsed = _parseCan(lines, bus == ObdBusType.can11 ? 3 : 8);
        if (parsed.isNotEmpty) return parsed;
        return _parseHeaderless(lines);
      case ObdBusType.legacy:
        final parsed = _parseLegacy(lines);
        if (parsed.isNotEmpty) return parsed;
        return _parseHeaderless(lines);
      case ObdBusType.unknown:
        // Spróbuj rozpoznać format po pierwszej linii
        final first = lines.first.replaceAll(' ', '');
        if (RegExp(r'^7E[89A-F][0-9A-Fa-f]').hasMatch(first)) {
          final parsed = _parseCan(lines, 3);
          if (parsed.isNotEmpty) return parsed;
        }
        if (first.toUpperCase().startsWith("18DA")) {
          final parsed = _parseCan(lines, 8);
          if (parsed.isNotEmpty) return parsed;
        }
        return _parseHeaderless(lines);
    }
  }

  /// Zamienia linię na (nagłówek, bajty). Obsługuje format ze spacjami (ATS1) i bez (ATS0).
  static (String, List<int>)? _splitCanLine(String line, int headerHexLen) {
    final compact = line.replaceAll(RegExp(r'\s+'), '');
    if (!_hex.hasMatch(compact) || compact.length <= headerHexLen) return null;
    final header = compact.substring(0, headerHexLen).toUpperCase();
    final rest = compact.substring(headerHexLen);
    if (rest.length.isOdd) return null;
    return (header, _hexToBytes(rest));
  }

  static List<EcuResponse> _parseCan(List<String> lines, int headerHexLen) {
    final order = <String>[];
    final buffers = <String, List<int>>{};
    final expected = <String, int>{};
    final complete = <String, List<int>>{};

    for (final line in lines) {
      final split = _splitCanLine(line, headerHexLen);
      if (split == null) continue;
      final (ecu, frame) = split;
      if (frame.isEmpty) continue;

      final pci = frame[0] >> 4;
      switch (pci) {
        case 0x0: // Single Frame
          final len = frame[0] & 0x0F;
          if (len == 0 || frame.length < 1 + len) continue;
          if (!order.contains(ecu)) order.add(ecu);
          complete[ecu] = [...?complete[ecu], ...frame.sublist(1, 1 + len)];
          break;
        case 0x1: // First Frame
          if (frame.length < 2) continue;
          final len = ((frame[0] & 0x0F) << 8) | frame[1];
          if (!order.contains(ecu)) order.add(ecu);
          expected[ecu] = len;
          buffers[ecu] = frame.sublist(2);
          break;
        case 0x2: // Consecutive Frame
          final buf = buffers[ecu];
          if (buf == null) continue;
          buf.addAll(frame.sublist(1));
          break;
        default: // Flow control / nieznane — pomiń
          break;
      }
    }

    // Domknij wiadomości wieloramkowe
    for (final entry in buffers.entries) {
      final len = expected[entry.key] ?? entry.value.length;
      final data = entry.value.length > len ? entry.value.sublist(0, len) : entry.value;
      complete[entry.key] = [...?complete[entry.key], ...data];
    }

    return [
      for (final ecu in order)
        if (complete[ecu] != null && complete[ecu]!.isNotEmpty) EcuResponse(ecu, complete[ecu]!),
    ];
  }

  /// J1850 / ISO 9141 / KWP: "48 6B 10 41 0C 1A F8 C3" — 3 bajty nagłówka, dane, suma kontrolna.
  static List<EcuResponse> _parseLegacy(List<String> lines) {
    final order = <String>[];
    final data = <String, List<int>>{};

    for (final line in lines) {
      final compact = line.replaceAll(RegExp(r'\s+'), '');
      if (!_hex.hasMatch(compact) || compact.length.isOdd) continue;
      final bytes = _hexToBytes(compact);
      if (bytes.length < 5) continue;
      final ecu = bytes[2].toRadixString(16).padLeft(2, '0').toUpperCase();
      var payload = bytes.sublist(3, bytes.length - 1);

      final existing = data[ecu];
      if (existing == null) {
        order.add(ecu);
        data[ecu] = List.of(payload);
      } else if (payload.isNotEmpty && payload[0] == existing[0]) {
        // Kolejna linia tej samej odpowiedzi — pomiń powtórzony bajt usługi
        // (a dla Mode 09 także PID i numer sekwencji).
        payload = existing[0] == 0x49 && payload.length > 3 ? payload.sublist(3) : payload.sublist(1);
        existing.addAll(payload);
      }
    }
    return [for (final ecu in order) EcuResponse(ecu, data[ecu]!)];
  }

  /// Awaryjny parser dla odpowiedzi bez nagłówków (ATH0 lub nietypowe klony).
  /// Zwraca każdą odpowiedź jako osobną wiadomość, żeby nie sklejać różnych ECU.
  static List<EcuResponse> _parseHeaderless(List<String> lines) {
    final result = <EcuResponse>[];
    List<int>? multi;
    int multiLen = 0;

    for (var line in lines) {
      line = line.trim();
      // Linia z długością wiadomości wieloramkowej, np. "014"
      if (RegExp(r'^[0-9A-Fa-f]{3}$').hasMatch(line)) {
        multiLen = int.parse(line, radix: 16);
        multi = [];
        continue;
      }
      final seq = RegExp(r'^([0-9A-Fa-f]):\s*(.*)$').firstMatch(line);
      if (seq != null && multi != null) {
        final compact = seq.group(2)!.replaceAll(RegExp(r'\s+'), '');
        if (_hex.hasMatch(compact) && compact.length.isEven) multi.addAll(_hexToBytes(compact));
        continue;
      }
      final compact = line.replaceAll(RegExp(r'\s+'), '');
      if (!_hex.hasMatch(compact) || compact.length.isOdd) continue;
      result.add(EcuResponse("?", _hexToBytes(compact)));
    }
    if (multi != null && multi.isNotEmpty) {
      result.insert(0, EcuResponse("?", multiLen > 0 && multi.length > multiLen ? multi.sublist(0, multiLen) : multi));
    }
    return result;
  }

  static List<int> _hexToBytes(String hex) => [
        for (int i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
      ];

  // ---------------------------------------------------------------------------
  // Dekodery usług OBD
  // ---------------------------------------------------------------------------

  /// Długość danych (bez numeru PID) standardowych PIDów Mode 01 wg SAE J1979.
  /// Potrzebna do rozdzielenia odpowiedzi na zapytanie o kilka PIDów naraz.
  static const Map<int, int> mode01DataLength = {
    0x04: 1, 0x05: 1, 0x06: 1, 0x07: 1, 0x08: 1, 0x09: 1, 0x0A: 1, 0x0B: 1, 0x0C: 2, 0x0D: 1,
    0x0E: 1, 0x0F: 1, 0x10: 2, 0x11: 1, 0x14: 2, 0x15: 2, 0x1C: 1, 0x1F: 2, 0x21: 2, 0x22: 2,
    0x23: 2, 0x24: 4, 0x2C: 1, 0x2D: 1, 0x2E: 1, 0x2F: 1, 0x31: 2, 0x33: 1, 0x34: 4, 0x3C: 2,
    0x42: 2, 0x43: 2, 0x44: 2, 0x45: 1, 0x46: 1, 0x49: 1, 0x4A: 1, 0x4C: 1, 0x51: 1, 0x59: 2,
    0x5A: 1, 0x5C: 1, 0x5E: 2, 0x61: 1, 0x62: 1, 0x63: 2, 0x66: 5, 0x69: 7, 0x6D: 11, 0x70: 10,
    0x71: 6, 0x72: 5, 0x73: 5, 0x74: 5, 0x77: 5, 0x78: 9, 0x79: 9, 0x7A: 7, 0x7B: 7, 0x7C: 9,
    0x87: 5,
  };

  /// Rozdziela odpowiedź na zapytanie o kilka PIDów naraz ([0x41, PID1, dane1..., PID2, dane2...])
  /// na dane poszczególnych PIDów. Sterownik może pominąć PIDy, których nie obsługuje.
  /// Zwraca null, gdy odpowiedź zawiera PID o nieznanej długości (nie da się jej rozdzielić).
  static Map<int, List<int>>? splitMultiPid(List<int> data) {
    if (data.isEmpty || data[0] != 0x41) return null;
    final out = <int, List<int>>{};
    int i = 1;
    while (i < data.length) {
      final pid = data[i];
      final len = mode01DataLength[pid];
      if (len == null || i + 1 + len > data.length) return out.isEmpty ? null : out;
      out[pid] = data.sublist(i + 1, i + 1 + len);
      i += 1 + len;
    }
    return out;
  }

  /// Maska obsługiwanych PIDów z odpowiedzi 41 00/20/40/... → zbiór numerów PID.
  static Set<int> decodeSupportedPids(List<int> data) {
    final result = <int>{};
    if (data.length < 6 || data[0] != 0x41) return result;
    final base = data[1];
    for (int byteIdx = 0; byteIdx < 4; byteIdx++) {
      final b = data[2 + byteIdx];
      for (int bit = 0; bit < 8; bit++) {
        if (b & (0x80 >> bit) != 0) {
          result.add(base + byteIdx * 8 + bit + 1);
        }
      }
    }
    return result;
  }

  /// Dekoduje kody DTC z odpowiedzi Mode 03 / 07 / 0A (dane zaczynają się od 0x43/0x47/0x4A).
  /// Na CAN po bajcie usługi występuje liczba kodów; w protokołach legacy jej nie ma.
  static List<String> decodeDtcs(List<int> data, {required bool isCan}) {
    if (data.isEmpty || ![0x43, 0x47, 0x4A].contains(data[0])) return const [];
    int idx = 1;
    int? count;
    if (isCan) {
      if (data.length < 2) return const [];
      count = data[1];
      idx = 2;
    }
    final codes = <String>[];
    for (; idx + 1 < data.length; idx += 2) {
      final b1 = data[idx];
      final b2 = data[idx + 1];
      if (b1 == 0 && b2 == 0) continue;
      codes.add(dtcFromBytes(b1, b2));
      if (count != null && codes.length >= count) break;
    }
    return codes;
  }

  static String dtcFromBytes(int b1, int b2) {
    const letters = ["P", "C", "B", "U"];
    final letter = letters[(b1 & 0xC0) >> 6];
    final d1 = (b1 & 0x30) >> 4;
    final d2 = b1 & 0x0F;
    final d3 = (b2 & 0xF0) >> 4;
    final d4 = b2 & 0x0F;
    return "$letter$d1${d2.toRadixString(16)}${d3.toRadixString(16)}${d4.toRadixString(16)}".toUpperCase();
  }

  /// Wyciąga tekst ASCII z odpowiedzi Mode 09 (VIN, CALID, nazwa ECU).
  /// [data] zaczyna się od [0x49, pid, liczba_elementów, ...].
  static List<String> decodeMode09Strings(List<int> data, {int itemLength = 0}) {
    if (data.length < 3 || data[0] != 0x49) return const [];
    final body = data.sublist(3);
    final chunks = <List<int>>[];
    if (itemLength > 0 && body.length > itemLength) {
      for (int i = 0; i < body.length; i += itemLength) {
        chunks.add(body.sublist(i, i + itemLength > body.length ? body.length : i + itemLength));
      }
    } else {
      chunks.add(body);
    }
    return [
      for (final c in chunks)
        String.fromCharCodes(c.where((b) => b >= 0x20 && b <= 0x7E)).trim(),
    ].where((s) => s.isNotEmpty).toList();
  }
}
