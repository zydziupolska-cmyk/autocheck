/// Analiza nagrania z podsłuchu magistrali: składa ramki w wiadomości (ISO-TP i VW TP2.0),
/// paruje zapytania testera z odpowiedziami modułów i zbiera parametry, które tester
/// odczytywał (UDS 22 DID, KWP 21 bloki pomiarowe, OBD Mode 01).
///
/// Dzięki temu po sesji z Autelem widać np.: „silnik 7E0: DID 0x20AB, 2 bajty, zmienia się
/// od 980 do 2150” — i taki parametr można zapisać do własnej biblioteki i odczytywać
/// potem samym vLinkerem.
library;

import '../../models/sniff_recording.dart';
import '../../models/vag_block_formulas.dart';
import '../../models/vag_modules.dart';
import '../elm_parser.dart';

class SniffFrame {
  final int tMs;
  final int id;
  final List<int> data;
  const SniffFrame(this.tMs, this.id, this.data);
}

/// Złożona wiadomość diagnostyczna.
class SniffMessage {
  final int tMs;
  final String channel; // np. "7E8", "18DAF110", "TP2.0 01"
  final int canId;
  final bool? fromTester; // TP2.0: znany kierunek; ISO-TP: z bajtu usługi
  final List<int> bytes;
  final int? tp20Address;
  const SniffMessage(this.tMs, this.channel, this.canId, this.bytes, {this.fromTester, this.tp20Address});

  bool get isResponse => fromTester != null ? !fromTester! : bytes.isNotEmpty && (bytes[0] & 0x40) != 0;
}

enum LearnedKind { udsDid, kwpLocalId, tp20Block, obdPid }

class LearnedSample {
  final int tMs;
  final List<int> bytes;
  const LearnedSample(this.tMs, this.bytes);
}

/// Parametr odczytywany przez tester.
class LearnedParam {
  final String ecuKey;
  final LearnedKind kind;
  final int identifier; // DID, numer bloku, PID
  final int? field; // pole bloku TP2.0 (1-4)
  final List<LearnedSample> samples = [];
  /// Nagłówek zapytań (np. „7E0”, „714”) — do zapisania w bibliotece.
  String? requestHeader;
  /// Definicja dynamicznego DID (UDS 2C), jeśli tester sam go złożył.
  String? dynamicDefinition;

  LearnedParam(this.ecuKey, this.kind, this.identifier, {this.field});

  static const maxSamples = 3000;

  String get idHex => identifier.toRadixString(16).padLeft(kind == LearnedKind.udsDid ? 4 : 2, '0').toUpperCase();

  /// Zapytanie do odczytu samym adapterem (np. „22F40C”); null dla bloków TP2.0.
  String? get requestCommand {
    switch (kind) {
      case LearnedKind.udsDid:
        return "22$idHex";
      case LearnedKind.kwpLocalId:
        return "21$idHex";
      case LearnedKind.obdPid:
        return "01$idHex";
      case LearnedKind.tp20Block:
        return null;
    }
  }

  String get title {
    switch (kind) {
      case LearnedKind.udsDid:
        return "DID 0x$idHex";
      case LearnedKind.kwpLocalId:
        return "Blok KWP 0x$idHex";
      case LearnedKind.obdPid:
        return "OBD PID 0x$idHex";
      case LearnedKind.tp20Block:
        final f = formula;
        return "Blok ${identifier.toString().padLeft(3, '0')}, pole $field${f != null ? ' — ${f.name}' : ''}";
    }
  }

  int get length => samples.isEmpty ? 0 : samples.last.bytes.length;

  /// Formuła VAG z bloku pomiarowego (bajt formuły z ostatniej próbki).
  VagBlockFormula? get formula =>
      kind == LearnedKind.tp20Block && samples.isNotEmpty ? VagBlockFormula.byId(samples.last.bytes[0]) : null;

  /// Wartości zdekodowane (tylko bloki TP2.0 — mają formułę w odpowiedzi).
  List<double?> get decodedValues => [
        for (final s in samples) s.bytes.length >= 3 ? VagBlockFormula.decode(s.bytes[0], s.bytes[1], s.bytes[2]) : null,
      ];

  int get distinctValues => samples.map((s) => s.bytes.join(",")).toSet().length;
  bool get changes => distinctValues > 1;

  /// Pozycje bajtów, które zmieniały się w trakcie nagrania.
  List<int> get varyingBytes {
    if (samples.isEmpty) return const [];
    final n = samples.map((s) => s.bytes.length).reduce((a, b) => a < b ? a : b);
    return [
      for (int i = 0; i < n; i++)
        if (samples.any((s) => s.bytes[i] != samples.first.bytes[i])) i,
    ];
  }

  /// Proponowane równanie Torque na podstawie zmieniających się bajtów.
  String suggestEquation() {
    final n = length;
    if (n == 0) return "A";
    final v = varyingBytes;
    int start;
    int count;
    if (v.isEmpty) {
      start = 0;
      count = n >= 2 ? 2 : 1;
    } else {
      start = v.first;
      final span = v.last - v.first + 1;
      if (span == 1) {
        // Zmienia się jeden bajt — jeśli przed nim jest bajt (starszy), też go bierzemy przy 2-bajtowych wartościach
        if (n == 2 && start == 1) {
          start = 0;
          count = 2;
        } else {
          count = 1;
        }
      } else {
        count = 2;
      }
    }
    final a = byteName(start);
    if (count == 1 || start + 1 >= n) return a;
    return "($a*256)+${byteName(start + 1)}";
  }

  static String byteName(int i) {
    if (i < 26) return String.fromCharCode(65 + i);
    return String.fromCharCode(64 + i ~/ 26) + String.fromCharCode(65 + i % 26);
  }
}

/// Moduł (sterownik), z którym rozmawiał tester.
class SniffEcu {
  final String key;
  String label;
  String? identification;
  final Map<String, LearnedParam> params = {};
  int requests = 0;
  int responses = 0;
  SniffEcu(this.key, this.label);
}

class SniffAnalysis {
  final Map<String, SniffEcu> ecus;
  final int frames;
  final int messages;
  final int unpairedResponses;
  final Duration duration;
  const SniffAnalysis(this.ecus, {required this.frames, required this.messages, required this.unpairedResponses, required this.duration});

  List<LearnedParam> get allParams => [for (final e in ecus.values) ...e.params.values];
}

class _IsoTpState {
  final List<int> buf = [];
  int length = 0;
  int startT = 0;
}

class _Tp20State {
  final List<int> buf = [];
  int? length;
  int startT = 0;
}

class _PendingRequest {
  final SniffMessage msg;
  const _PendingRequest(this.msg);
}

class SniffAnalyzer {
  // --- Parsowanie linii ---

  static SniffFrame? parseLine(SniffLine line, {required bool extendedIds}) {
    final tokens = line.raw.trim().split(RegExp(r'\s+'));
    if (tokens.isEmpty) return null;
    final hex = RegExp(r'^[0-9A-Fa-f]+$');
    if (!tokens.every(hex.hasMatch)) return null;
    int id;
    List<String> dataTokens;
    if (tokens.length == 1) {
      // Bez spacji (ATS0): nagłówek 3 lub 8 znaków
      final c = tokens[0];
      final hl = extendedIds ? 8 : 3;
      if (c.length < hl || (c.length - hl).isOdd) return null;
      id = int.parse(c.substring(0, hl), radix: 16);
      dataTokens = [for (int i = hl; i + 1 < c.length; i += 2) c.substring(i, i + 2)];
    } else if (extendedIds) {
      if (tokens.length < 4) return null;
      final h = tokens.take(4).join();
      if (h.length != 8) return null;
      id = int.parse(h, radix: 16);
      dataTokens = tokens.sublist(4);
    } else {
      if (tokens[0].length != 3) return null;
      id = int.parse(tokens[0], radix: 16);
      dataTokens = tokens.sublist(1);
    }
    if (dataTokens.any((t) => t.length != 2) || dataTokens.length > 8) return null;
    return SniffFrame(line.tMs, id, [for (final t in dataTokens) int.parse(t, radix: 16)]);
  }

  static String _hex(int v, int width) => v.toRadixString(16).padLeft(width, '0').toUpperCase();

  // --- Główna analiza ---

  static SniffAnalysis analyze(SniffRecording rec) {
    final frames = <SniffFrame>[
      for (final l in rec.lines) ?parseLine(l, extendedIds: rec.extendedIds),
    ];
    final messages = reassemble(frames, extendedIds: rec.extendedIds);
    return _collect(messages, frames.length, rec.duration, extendedIds: rec.extendedIds);
  }

  /// Składa ramki w wiadomości: kanały TP2.0 (otwierane na 0x200) i ISO-TP.
  static List<SniffMessage> reassemble(List<SniffFrame> frames, {required bool extendedIds}) {
    final out = <SniffMessage>[];
    final iso = <int, _IsoTpState>{};
    final tp = <int, _Tp20State>{};
    // id ramki → (adres modułu, czy od testera)
    final tpChannels = <int, (int, bool)>{};
    final tpSetupPending = <int>{};

    for (final f in frames) {
      final d = f.data;
      if (!extendedIds) {
        // --- TP2.0: otwarcie kanału ---
        if (f.id == 0x200 && d.length >= 7 && d[1] == 0xC0) {
          tpSetupPending.add(d[0]);
          continue;
        }
        if (f.id > 0x200 && f.id <= 0x2FF && d.length >= 7 && d[1] == 0xD0) {
          // Odpowiedź modułu: tester odbiera na d[2..3], wysyła na d[4..5]
          final addr = f.id - 0x200;
          tpSetupPending.remove(addr);
          final testerRx = d[2] | ((d[3] & 0x0F) << 8);
          final testerTx = d[4] | ((d[5] & 0x0F) << 8);
          tpChannels[testerTx] = (addr, true);
          tpChannels[testerRx] = (addr, false);
          tp.remove(testerTx);
          tp.remove(testerRx);
          continue;
        }
        final ch = tpChannels[f.id];
        if (ch != null) {
          if (d.isEmpty) continue;
          final op = d[0] >> 4;
          if (d[0] == 0xA8) {
            // Zamknięcie kanału
            tp.remove(f.id);
            continue;
          }
          if (op > 0x3) continue; // A0/A1/A3/B* — sterowanie kanałem
          final st = tp.putIfAbsent(f.id, () => _Tp20State());
          var body = d.sublist(1);
          if (st.length == null) {
            if (body.length < 2) continue;
            st.length = ((body[0] << 8) | body[1]) & 0x7FFF;
            st.startT = f.tMs;
            body = body.sublist(2);
          }
          st.buf.addAll(body);
          if (op & 0x1 != 0) {
            final len = st.length!;
            final msg = st.buf.length > len ? st.buf.sublist(0, len) : List<int>.from(st.buf);
            tp.remove(f.id);
            if (msg.isNotEmpty) {
              out.add(SniffMessage(f.tMs, "TP2.0 ${_hex(ch.$1, 2)}", f.id, msg, fromTester: ch.$2, tp20Address: ch.$1));
            }
          }
          continue;
        }
        if (f.id >= 0x200 && f.id <= 0x2FF) continue;
        // ISO-TP diagnostyka na 11-bit: zakres 0x600-0x7FF
        if (f.id < 0x600) continue;
      } else {
        // 29-bit: adresowanie diagnostyczne 18DA/18DB
        final prefix = f.id >> 16;
        if (prefix != 0x18DA && prefix != 0x18DB) continue;
      }

      // --- ISO-TP ---
      if (d.isEmpty) continue;
      final pci = d[0] >> 4;
      switch (pci) {
        case 0x0:
          final len = d[0] & 0x0F;
          if (len == 0 || len > d.length - 1) continue;
          out.add(SniffMessage(f.tMs, _hex(f.id, extendedIds ? 8 : 3), f.id, d.sublist(1, 1 + len)));
          iso.remove(f.id);
        case 0x1:
          if (d.length < 3) continue;
          final st = _IsoTpState()
            ..length = ((d[0] & 0x0F) << 8) | d[1]
            ..startT = f.tMs;
          st.buf.addAll(d.sublist(2));
          iso[f.id] = st;
        case 0x2:
          final st = iso[f.id];
          if (st == null) continue;
          st.buf.addAll(d.sublist(1));
          if (st.buf.length >= st.length) {
            out.add(SniffMessage(f.tMs, _hex(f.id, extendedIds ? 8 : 3), f.id, st.buf.sublist(0, st.length)));
            iso.remove(f.id);
          }
        default:
          break; // 0x3 = sterowanie przepływem
      }
    }
    return out;
  }

  static String _ecuLabel(String key, int? tp20Address) {
    if (tp20Address != null) {
      final m = VagTp20Module.all.where((m) => m.address == tp20Address).firstOrNull;
      return "${m?.name ?? 'Moduł'} (adres ${_hex(tp20Address, 2)}, TP2.0)";
    }
    final m = VagModule.all.where((m) => m.responseId == key).firstOrNull;
    if (m != null) return "${m.name} ($key)";
    const obd = {"7E8": "Silnik (7E8)", "7E9": "Skrzynia biegów (7E9)", "7EA": "Sterownik 7EA", "7EB": "Sterownik 7EB"};
    if (obd.containsKey(key)) return obd[key]!;
    if (key.length == 8 && key.startsWith("18DAF1")) {
      final a = key.substring(6);
      return a == "10" ? "Silnik ($key)" : a == "18" ? "Skrzynia biegów ($key)" : "Sterownik $a ($key)";
    }
    return "Sterownik $key";
  }

  /// Nagłówek zapytań fizycznych do modułu, gdy tester pytał adresem funkcyjnym.
  static String? _physicalHeader(String responseKey) {
    if (responseKey.length == 3) {
      final v = int.parse(responseKey, radix: 16);
      if (v >= 0x7E8 && v <= 0x7EF) return _hex(v - 8, 3);
      final m = VagModule.all.where((m) => m.responseId == responseKey).firstOrNull;
      return m?.requestId;
    }
    if (responseKey.length == 8 && responseKey.startsWith("18DAF1")) return "18DA${responseKey.substring(6)}F1";
    return null;
  }

  static bool _isFunctional(int canId, bool extended) => extended ? (canId >> 16) == 0x18DB : canId == 0x7DF;

  static SniffAnalysis _collect(List<SniffMessage> messages, int frames, Duration duration, {required bool extendedIds}) {
    final ecus = <String, SniffEcu>{};
    final pending = <_PendingRequest>[];
    int unpaired = 0;
    // Długości DID poznane z zapytań o pojedynczy DID (do dzielenia odpowiedzi zbiorczych)
    final didLengths = <String, Map<int, int>>{};
    final multiDid = <(SniffEcu, String?, List<int>, SniffMessage)>[];
    final dynamicDefs = <String, Map<int, String>>{};

    SniffEcu ecuFor(SniffMessage resp) {
      return ecus.putIfAbsent(resp.channel, () => SniffEcu(resp.channel, _ecuLabel(resp.channel, resp.tp20Address)));
    }

    for (final m in messages) {
      if (m.bytes.isEmpty) continue;
      if (!m.isResponse) {
        pending.add(_PendingRequest(m));
        if (pending.length > 64) pending.removeAt(0);
        continue;
      }
      final resp = m.bytes;
      final sid = resp[0] == 0x7F && resp.length >= 2 ? resp[1] : resp[0] - 0x40;
      // Najnowsze pasujące zapytanie w ciągu 3 s (dla TP2.0 — z tego samego kanału)
      _PendingRequest? match;
      for (int i = pending.length - 1; i >= 0; i--) {
        final r = pending[i].msg;
        if (m.tMs - r.tMs > 3000) break;
        if (r.bytes[0] != sid) continue;
        if (m.tp20Address != null && r.tp20Address != m.tp20Address) continue;
        if (m.tp20Address == null && r.tp20Address != null) continue;
        if (resp[0] != 0x7F && r.bytes.length >= 2 && resp.length >= 2 && (sid == 0x22 || sid == 0x21 || sid == 0x01)) {
          if (r.bytes[1] != resp[1]) continue;
          if (sid == 0x22 && (r.bytes.length < 3 || resp.length < 3 || r.bytes[2] != resp[2])) continue;
        }
        match = pending[i];
        break;
      }
      final ecu = ecuFor(m);
      ecu.responses++;
      if (match == null) {
        unpaired++;
        continue;
      }
      ecu.requests++;
      if (resp[0] == 0x7F) continue;
      final req = match.msg.bytes;
      final header = m.tp20Address != null
          ? null
          : _isFunctional(match.msg.canId, extendedIds)
              ? _physicalHeader(m.channel)
              : match.msg.channel;

      switch (sid) {
        case 0x22:
          final dids = <int>[for (int i = 1; i + 1 < req.length; i += 2) (req[i] << 8) | req[i + 1]];
          if (dids.length == 1) {
            if (resp.length < 3) break;
            final did = dids.first;
            final data = resp.sublist(3);
            if (_identDids.contains(did)) {
              final text = _ascii(data);
              if (text.isNotEmpty) {
                ecu.identification = ecu.identification == null ? text : "${ecu.identification} • $text";
                if (did == 0xF197 || did == 0xF19E) ecu.label = "$text (${m.channel})";
              }
              break;
            }
            didLengths.putIfAbsent(ecu.key, () => {})[did] = data.length;
            _addSample(ecu, LearnedKind.udsDid, did, null, header, m.tMs, data);
          } else {
            multiDid.add((ecu, header, dids, m));
          }
        case 0x21:
          if (resp.length < 2) break;
          final block = resp[1];
          final data = resp.sublist(2);
          if (m.tp20Address != null) {
            // Blok pomiarowy VAG: do 4 trójek [formuła, NW, MW]
            for (int f = 0; f * 3 + 2 < data.length && f < 4; f++) {
              _addSample(ecu, LearnedKind.tp20Block, block, f + 1, null, m.tMs, data.sublist(f * 3, f * 3 + 3));
            }
          } else {
            _addSample(ecu, LearnedKind.kwpLocalId, block, null, header, m.tMs, data);
          }
        case 0x1A:
          if (resp.length > 2) {
            final text = _ascii(resp.sublist(2));
            if (text.isNotEmpty) ecu.identification = text;
          }
        case 0x01:
          final split = ElmParser.splitMultiPid(resp);
          if (split == null) break;
          for (final e in split.entries) {
            if (e.key % 0x20 == 0) continue; // mapy obsługiwanych PIDów
            _addSample(ecu, LearnedKind.obdPid, e.key, null, header, m.tMs, e.value);
          }
        case 0x2C:
          // Dynamiczna definicja DID: 2C 01 <DID> <źródło DID> <pozycja> <rozmiar> ...
          if (req.length >= 8 && req[1] == 0x01) {
            final dyn = (req[2] << 8) | req[3];
            final parts = <String>[];
            for (int i = 4; i + 3 < req.length; i += 4) {
              parts.add("DID ${_hex((req[i] << 8) | req[i + 1], 4)} od bajtu ${req[i + 2]}, ${req[i + 3]} B");
            }
            dynamicDefs.putIfAbsent(ecu.key, () => {})[dyn] = parts.join("; ");
          }
        default:
          break;
      }
    }

    // Odpowiedzi zbiorcze (kilka DID w jednym zapytaniu)
    for (final (ecu, header, dids, m) in multiDid) {
      final split = _splitMultiDid(m.bytes, dids, didLengths[ecu.key] ?? const {});
      if (split == null) continue;
      split.forEach((did, data) {
        if (_identDids.contains(did)) return;
        _addSample(ecu, LearnedKind.udsDid, did, null, header, m.tMs, data);
      });
    }
    for (final ecu in ecus.values) {
      for (final p in ecu.params.values) {
        p.samples.sort((a, b) => a.tMs.compareTo(b.tMs));
        if (p.kind == LearnedKind.udsDid) p.dynamicDefinition = dynamicDefs[ecu.key]?[p.identifier];
      }
    }
    ecus.removeWhere((_, e) => e.params.isEmpty && e.identification == null);
    return SniffAnalysis(ecus, frames: frames, messages: messages.length, unpairedResponses: unpaired, duration: duration);
  }

  static const _identDids = {0xF187, 0xF189, 0xF18C, 0xF190, 0xF191, 0xF197, 0xF19E, 0xF1A2, 0xF1AA};

  static String _ascii(List<int> data) {
    final s = String.fromCharCodes(data.map((b) => b >= 0x20 && b <= 0x7E ? b : 0x20));
    return s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  static void _addSample(SniffEcu ecu, LearnedKind kind, int id, int? field, String? header, int t, List<int> data) {
    final key = "${kind.name}:$id:${field ?? ''}";
    final p = ecu.params.putIfAbsent(key, () => LearnedParam(ecu.key, kind, id, field: field));
    p.requestHeader ??= header;
    if (p.samples.length < LearnedParam.maxSamples) p.samples.add(LearnedSample(t, data));
  }

  /// Dzieli odpowiedź `62 D1 … D2 … D3 …` na dane poszczególnych DID.
  /// Znane długości (z pojedynczych zapytań) mają pierwszeństwo; w pozostałych
  /// przypadkach szukamy kolejnego identyfikatora w danych (pierwszy spójny podział).
  static Map<int, List<int>>? _splitMultiDid(List<int> resp, List<int> dids, Map<int, int> known) {
    if (resp.isEmpty || resp[0] != 0x62) return null;
    final out = <int, List<int>>{};
    bool rec(int pos, int idx) {
      if (idx == dids.length) return pos == resp.length;
      final did = dids[idx];
      if (pos + 2 > resp.length || ((resp[pos] << 8) | resp[pos + 1]) != did) return false;
      final start = pos + 2;
      if (idx == dids.length - 1) {
        out[did] = resp.sublist(start);
        return true;
      }
      final k = known[did];
      final candidates = k != null ? [k] : [for (int len = 1; start + len + 2 <= resp.length; len++) len];
      for (final len in candidates) {
        final next = start + len;
        if (next + 2 > resp.length) continue;
        if (((resp[next] << 8) | resp[next + 1]) != dids[idx + 1]) continue;
        out[did] = resp.sublist(start, next);
        if (rec(next, idx + 1)) return true;
      }
      out.remove(did);
      return false;
    }

    return rec(1, 0) ? out : null;
  }
}
