/// VW Transport Protocol 2.0 (TP2.0) przez adapter ELM327/STN.
///
/// Starsze moduły VAG (platformy PQ, np. Touran 1T, Golf V/VI, Passat B6/B7,
/// Skoda Octavia II, Rapid, Fabia II/III) rozmawiają protokołem KWP2000 przez TP2.0
/// na zwykłym CAN 500 kbps, a nie przez ISO-TP/UDS. Schemat działania za
/// jazdw/vag-blocks (tp20.cpp) i dokumentacją jazdw.net/tp20:
///
/// 1. Otwarcie kanału: na ID 0x200 `<adres> C0 00 10 00 03 01`, odpowiedź z
///    0x200+adres: `00 D0 <rx lo> <rx hi> <tx lo> <tx hi> 01` — tester odbiera na
///    rx (zwykle 0x300) i wysyła na tx (zwykle 0x740).
/// 2. Parametry kanału: `A0 0F 8A FF 4A FF` → `A1 <rozmiar bloku> ...`.
/// 3. Dane: bajt 0 = kod (4 bity) + sekwencja (4 bity): 0x0 = czeka na ACK, będą
///    kolejne; 0x1 = czeka na ACK, ostatni; 0x2 = bez ACK, będą kolejne; 0x3 = bez
///    ACK, ostatni. Pierwszy pakiet wiadomości zawiera 2 bajty długości. ACK = 0xB0 +
///    następny oczekiwany numer sekwencji.
/// 4. Zamknięcie: `A8`.
///
/// Adapter pracuje w protokole użytkownika B (`AT PB C0 01`: CAN 11-bit, 500 kbps,
/// zmienna długość ramki, bez formatowania ISO-TP).
library;

/// Wysyła komendę do adaptera i zwraca surową odpowiedź (bez znaku '>').
typedef ElmSender = Future<String> Function(String cmd, {Duration timeout});

/// Ramka CAN z odpowiedzi adaptera (z włączonymi nagłówkami).
class RawCanFrame {
  final int id;
  final List<int> data;
  const RawCanFrame(this.id, this.data);
}

class Tp20Exception implements Exception {
  final String message;
  Tp20Exception(this.message);
  @override
  String toString() => message;
}

class Tp20Client {
  final ElmSender send;

  int _txId = 0;
  int _rxId = 0;
  int _txSeq = 0;
  int _rxSeq = 0;
  int _blockSize = 0x0F;
  String _activeHeader = "";
  String _activeFilter = "";

  Tp20Client(this.send);

  /// Przełącza adapter na surowy CAN 11-bit 500 kbps (protokół użytkownika B).
  Future<void> enterRawMode() async {
    await send("ATPBC001");
    await send("ATSPB");
    // Po zmianie protokołu część adapterów resetuje formatowanie
    await send("ATH1");
    await send("ATS1");
    await send("ATL0");
    await send("ATAT0");
    await send("ATST60"); // ok. 384 ms na odpowiedź modułu
    _activeHeader = "";
    _activeFilter = "";
  }

  static List<RawCanFrame> parseFrames(String raw) {
    final out = <RawCanFrame>[];
    for (var line in raw.split(RegExp(r'[\r\n]+'))) {
      line = line.trim();
      if (line.isEmpty) continue;
      final compact = line.replaceAll(RegExp(r'\s+'), '');
      // 3 znaki nagłówka 11-bit + parzysta liczba znaków danych
      if (!RegExp(r'^[0-9A-Fa-f]+$').hasMatch(compact) || compact.length < 5 || (compact.length - 3).isOdd) continue;
      final id = int.parse(compact.substring(0, 3), radix: 16);
      final data = <int>[
        for (int i = 3; i + 1 < compact.length; i += 2) int.parse(compact.substring(i, i + 2), radix: 16),
      ];
      out.add(RawCanFrame(id, data));
    }
    return out;
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

  Future<void> _route(int sendId, int recvId) async {
    final h = sendId.toRadixString(16).padLeft(3, '0').toUpperCase();
    final f = recvId.toRadixString(16).padLeft(3, '0').toUpperCase();
    if (_activeHeader != h) {
      await send("ATSH$h");
      _activeHeader = h;
    }
    if (_activeFilter != f) {
      await send("ATCRA$f");
      _activeFilter = f;
    }
  }

  Future<List<RawCanFrame>> _sendFrame(List<int> data) async {
    final raw = await send(_hex(data), timeout: const Duration(seconds: 3));
    return parseFrames(raw).where((f) => f.id == _rxId).toList();
  }

  /// Otwiera kanał do modułu o adresie logicznym VAG (np. 0x01 silnik, 0x03 ABS).
  /// Zwraca false, gdy moduł nie odpowiada.
  Future<bool> open(int address) async {
    await _route(0x200, 0x200 + address);
    final raw = await send("${_hex([address])}C00010000301", timeout: const Duration(seconds: 2));
    final setup = parseFrames(raw).where((f) => f.id == 0x200 + address && f.data.length >= 7 && f.data[1] == 0xD0).firstOrNull;
    if (setup == null) return false;
    final d = setup.data;
    _rxId = d[2] | ((d[3] & 0x0F) << 8);
    _txId = d[4] | ((d[5] & 0x0F) << 8);
    if ((d[3] >> 4) != 0 || (d[5] >> 4) != 0) return false; // identyfikatory oznaczone jako nieważne
    _txSeq = 0;
    _rxSeq = 0;

    await _route(_txId, _rxId);
    final params = await _sendFrame([0xA0, 0x0F, 0x8A, 0xFF, 0x4A, 0xFF]);
    final a1 = params.where((f) => f.data.isNotEmpty && f.data[0] == 0xA1).firstOrNull;
    if (a1 == null) return false;
    if (a1.data.length > 1 && a1.data[1] > 0 && a1.data[1] <= 0x0F) _blockSize = a1.data[1];
    return true;
  }

  /// Wysyła wiadomość KWP2000 i zwraca odpowiedź (np. [0x58, ...]) albo null.
  /// Odpowiedzi „czekaj” (7F xx 78) są pomijane — czekamy na właściwą.
  Future<List<int>?> request(List<int> kwp) async {
    final payload = [kwp.length >> 8, kwp.length & 0xFF, ...kwp];
    final chunks = <List<int>>[
      for (int i = 0; i < payload.length; i += 7)
        payload.sublist(i, i + 7 > payload.length ? payload.length : i + 7),
    ];

    var frames = <RawCanFrame>[];
    for (int i = 0; i < chunks.length; i++) {
      final last = i == chunks.length - 1;
      final int op;
      if (last) {
        op = 0x10; // czeka na ACK, ostatni
      } else if ((i + 1) % _blockSize == 0) {
        op = 0x00; // czeka na ACK, będą kolejne
      } else {
        op = 0x20; // bez ACK, będą kolejne
      }
      final seq = _txSeq;
      _txSeq = (_txSeq + 1) & 0x0F;
      frames = await _sendFrame([op | seq, ...chunks[i]]);
      if (op != 0x20) {
        final ack = frames.indexWhere((f) => f.data.isNotEmpty && (f.data[0] & 0xF0) == 0xB0);
        if (ack < 0) throw Tp20Exception("Moduł nie potwierdził pakietu");
        frames = frames.sublist(ack + 1);
      }
    }

    // Odbiór odpowiedzi (z pominięciem odpowiedzi „czekaj” 7F xx 78)
    for (int attempt = 0; attempt < 8; attempt++) {
      final message = await _receive(frames);
      if (message == null) return null;
      if (message.length >= 3 && message[0] == 0x7F && message[2] == 0x78) {
        frames = [];
        continue;
      }
      return message;
    }
    return null;
  }

  /// Składa wiadomość z pakietów, wysyłając ACK tam, gdzie moduł go oczekuje.
  Future<List<int>?> _receive(List<RawCanFrame> initial) async {
    var frames = initial;
    final message = <int>[];
    int? length;
    int idle = 0;
    while (true) {
      final data = frames.where((f) => f.data.isNotEmpty && (f.data[0] >> 4) <= 0x3).toList();
      if (data.isEmpty) {
        // Moduł jeszcze nie odpowiedział — test kanału (A3) otwiera nowe okno odbioru
        if (++idle > 5) return null;
        frames = await _sendFrame([0xA3]);
        continue;
      }
      idle = 0;
      bool complete = false;
      bool needAck = false;
      int lastSeq = 0;
      for (final f in data) {
        final op = f.data[0] >> 4;
        lastSeq = f.data[0] & 0x0F;
        var body = f.data.sublist(1);
        if (length == null) {
          if (body.length < 2) return null;
          length = ((body[0] << 8) | body[1]) & 0x7FFF;
          body = body.sublist(2);
        }
        message.addAll(body);
        _rxSeq = (lastSeq + 1) & 0x0F;
        if (op & 0x01 != 0) complete = true;
        needAck = op & 0x02 == 0;
        if (complete) break;
      }
      if (needAck) {
        frames = await _sendFrame([0xB0 | _rxSeq]);
      } else {
        frames = [];
      }
      if (complete) {
        final len = length!;
        return len < message.length ? message.sublist(0, len) : message;
      }
    }
  }

  Future<void> close() async {
    try {
      await _sendFrame([0xA8]);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // KWP2000 (VAG) — kody usterek
  // ---------------------------------------------------------------------------

  /// Rozpoczęcie sesji diagnostycznej VAG (10 89).
  Future<bool> startSession() async {
    final r = await request([0x10, 0x89]);
    return r != null && r.isNotEmpty && r[0] == 0x50;
  }

  /// Identyfikacja modułu (1A 9B): numer części i nazwa, np. „03L906023PJ R4 2,0L EDC”.
  Future<String?> identification() async {
    final r = await request([0x1A, 0x9B]);
    if (r == null || r.length < 3 || r[0] != 0x5A) return null;
    final text = String.fromCharCodes(r.sublist(2).map((b) => b >= 0x20 && b <= 0x7E ? b : 0x20));
    final clean = text.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return clean.isEmpty ? null : clean;
  }

  /// Odczyt kodów usterek (18 02 FF 00). Zwraca listę (kod, bajt statusu).
  Future<List<(int, int)>?> readFaults() async {
    final r = await request([0x18, 0x02, 0xFF, 0x00]);
    if (r == null || r.isEmpty) return null;
    if (r[0] != 0x58) return null;
    final out = <(int, int)>[];
    for (int i = 2; i + 2 < r.length; i += 3) {
      final code = (r[i] << 8) | r[i + 1];
      if (code == 0 || code == 0xFFFF) continue;
      out.add((code, r[i + 2]));
    }
    return out;
  }

  /// 5-cyfrowy kod VAG → kod P, gdy mieści się w zakresie kodów OBD (16384+):
  /// 16684 → P0300, 17978 → P1570. Dla pozostałych null.
  static String? vagToObdCode(int code) {
    if (code < 16384 || code >= 16384 + 4 * 1024) return null;
    final off = code - 16384;
    final digit = off ~/ 1024;
    final rest = off % 1024;
    if (rest >= 1000) return null;
    return "P$digit${rest.toString().padLeft(3, '0')}";
  }
}
