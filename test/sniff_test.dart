import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/sniff_recording.dart';
import 'package:autocheck/services/analysis/sniff_analyzer.dart';
import 'package:autocheck/services/obd_service.dart';
import 'package:autocheck/services/pid_definitions_store.dart';
import 'package:autocheck/services/sniff_service.dart';

import 'support/mock_elm327.dart';

/// Ruch nagrany „z kabla Y”: Autel czyta parametry silnika przez UDS (7E0/7E8)
/// i blok pomiarowy starszego modułu przez VW TP2.0.
List<String> autelTraffic({int repeats = 3}) {
  final out = <String>[];
  // Identyfikacja modułu (wieloramkowa odpowiedź F19E)
  out.addAll([
    "7E0 03 22 F1 9E 55 55 55 55",
    "7E8 10 0E 62 F1 9E 45 56 5F",
    "7E0 30 00 00 55 55 55 55 55",
    "7E8 21 45 43 4D 32 30 54 44",
    "7E8 22 49 AA AA AA AA AA AA",
  ]);
  for (int i = 0; i < repeats; i++) {
    final boost = 1000 + i * 400; // hPa
    final hi = (boost >> 8).toRadixString(16).padLeft(2, '0').toUpperCase();
    final lo = (boost & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
    // Pojedynczy DID: doładowanie rzeczywiste
    out.add("7E0 03 22 20 2A 55 55 55 55");
    out.add("7E8 05 62 20 2A $hi $lo AA AA");
    // Dwa DID w jednym zapytaniu: 202A + 202B (zadane, stałe 1200 hPa = 04 B0)
    out.add("7E0 05 22 20 2A 20 2B 55 55");
    out.add("7E8 10 09 62 20 2A $hi $lo 20");
    out.add("7E0 30 00 00 55 55 55 55 55");
    out.add("7E8 21 2B 04 B0 AA AA AA AA");
  }
  // Szum z innej magistrali (nie diagnostyka)
  out.add("280 49 0E 00 00 0E 00 1B 0E");
  // TP2.0: kanał do silnika (adres 01), blok 011
  out.addAll([
    "200 01 C0 00 10 00 03 01",
    "201 00 D0 00 03 40 07 01",
    "740 A0 0F 8A FF 4A FF",
    "300 A1 0F 8A FF 4A FF",
    "740 10 00 02 21 0B",
    "300 B1",
    // 61 0B + 4 trójki: RPM 1280, temp. 90°C, (0x01 C8 20), (0x05 0A BE), (0x01 C8 20), (0x05 0A BE)
    "300 20 00 0E 61 0B 01 C8 20",
    "300 21 05 0A BE 01 C8 20 05",
    "300 12 0A BE",
    "740 B3",
    "740 A8",
  ]);
  // Dynamiczna definicja DID F200 z DID 202A
  out.addAll([
    "7E0 07 2C 01 F2 00 20 2A 01",
    "7E8 03 6C 01 F2 AA AA AA AA",
  ]);
  return out;
}

SniffRecording recordingOf(List<String> lines) => SniffRecording(
      start: DateTime(2026, 9, 24),
      extendedIds: false,
      lines: [for (int i = 0; i < lines.length; i++) SniffLine(i * 20, lines[i])],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('analiza nagrania', () {
    test('parsuje linie 11- i 29-bit', () {
      final f11 = SniffAnalyzer.parseLine(const SniffLine(0, "7E8 05 62 20 2A 03 E8 AA AA"), extendedIds: false)!;
      expect(f11.id, 0x7E8);
      expect(f11.data, [0x05, 0x62, 0x20, 0x2A, 0x03, 0xE8, 0xAA, 0xAA]);
      final f29 = SniffAnalyzer.parseLine(const SniffLine(0, "18 DA F1 10 03 41 0C 1A"), extendedIds: true)!;
      expect(f29.id, 0x18DAF110);
      expect(f29.data, [0x03, 0x41, 0x0C, 0x1A]);
      expect(SniffAnalyzer.parseLine(const SniffLine(0, "BUFFER FULL"), extendedIds: false), isNull);
    });

    test('UDS: pojedyncze i zbiorcze DID, identyfikacja, dynamiczne DID', () {
      final a = SniffAnalyzer.analyze(recordingOf(autelTraffic()));
      final engine = a.ecus["7E8"]!;
      expect(engine.label, contains("EV_ECM20TDI"));

      final boost = engine.params["udsDid:${0x202A}:"]!;
      expect(boost.requestHeader, "7E0");
      expect(boost.requestCommand, "22202A");
      expect(boost.length, 2);
      // 3 pojedyncze + 3 ze zbiorczych
      expect(boost.samples, hasLength(6));
      expect(boost.changes, isTrue);
      expect(boost.suggestEquation(), "(A*256)+B");

      final target = engine.params["udsDid:${0x202B}:"]!;
      expect(target.samples, hasLength(3));
      expect(target.samples.first.bytes, [0x04, 0xB0]);
      expect(target.changes, isFalse);

      // F200 nie był czytany, ale definicja trafia do DID tylko gdy jest czytany — tu brak
      expect(engine.params.keys.where((k) => k.contains("${0xF200}")), isEmpty);
    });

    test('TP2.0: składa kanał i dekoduje blok pomiarowy formułami VAG', () {
      final a = SniffAnalyzer.analyze(recordingOf(autelTraffic()));
      final tp = a.ecus["TP2.0 01"]!;
      expect(tp.label, contains("Silnik"));
      final rpm = tp.params["tp20Block:11:1"]!;
      expect(rpm.formula!.unit, "/min");
      expect(rpm.decodedValues.single, closeTo(1280, 0.01));
      final temp = tp.params["tp20Block:11:2"]!;
      expect(temp.decodedValues.single, closeTo(90, 0.01));
      expect(rpm.requestCommand, isNull);
      expect(tp.params, hasLength(4));
    });

    test('zapis i odczyt nagrania jako tekst', () {
      final rec = recordingOf(autelTraffic(repeats: 1));
      final back = SniffRecording.fromText(rec.toText());
      expect(back.lines, hasLength(rec.lines.length));
      expect(back.lines[3].raw, rec.lines[3].raw);
      expect(back.lines[3].tMs, rec.lines[3].tMs);
      expect(back.extendedIds, isFalse);
      // Surowy zrzut bez nagłówka też się wczytuje
      final raw = SniffRecording.fromText(autelTraffic(repeats: 1).join("\n"));
      expect(SniffAnalyzer.analyze(raw).ecus.containsKey("7E8"), isTrue);
    });
  });

  group('podsłuch przez adapter', () {
    late MockElm327 elm;
    late ObdService obd;

    setUp(() async {
      elm = await MockElm327.start();
      obd = ObdService();
    });

    tearDown(() async {
      obd.disconnect();
      await elm.close();
    });

    test('nagrywa ruch, wznawia po BUFFER FULL i wraca do normalnej pracy', () async {
      expect(await obd.connectWifi(ip: "127.0.0.1", port: elm.port), isTrue);
      final traffic = autelTraffic();
      elm.monitorTraffic.addAll(traffic);
      elm.monitorBufferFullAfter = 7;

      final sniff = SniffService(obd: obd, persist: false);
      expect(await sniff.start(label: "Touran"), isTrue);
      expect(obd.isMonitoring, isTrue);

      for (int i = 0; i < 200 && sniff.lineCount < traffic.length; i++) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(sniff.lineCount, traffic.length);
      expect(elm.receivedCommands, containsAll(["ATCSM1", "ATCAF0", "ATMA"]));
      expect(elm.monitorStarts, 2);
      expect(obd.monitorRestarts, 1);

      await sniff.stop();
      expect(obd.isMonitoring, isFalse);
      final a = sniff.analysis!;
      expect(a.ecus["7E8"]!.params.containsKey("udsDid:${0x202A}:"), isTrue);
      expect(a.ecus.containsKey("TP2.0 01"), isTrue);

      // Normalne komendy znów działają, formatowanie ISO-TP przywrócone
      final idx = elm.receivedCommands.lastIndexOf("ATCAF1");
      expect(idx, greaterThan(elm.receivedCommands.lastIndexOf("ATMA")));
      final codes = await obd.readDtcCodes();
      expect(codes, isNotNull);
      sniff.dispose();
    });

    test('STN używa STMA', () async {
      await elm.close();
      elm = await MockElm327.start(stn: true);
      expect(await obd.connectWifi(ip: "127.0.0.1", port: elm.port), isTrue);
      elm.monitorTraffic.addAll(autelTraffic(repeats: 1));
      final lines = <String>[];
      expect(await obd.startMonitor(lines.add), isTrue);
      for (int i = 0; i < 100 && lines.length < elm.monitorTraffic.length; i++) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      await obd.stopMonitor();
      expect(elm.receivedCommands, contains("STMA"));
      expect(lines, elm.monitorTraffic);
    });

    test('parametr z nagrania trafia do Mojej biblioteki i jest odczytywany', () async {
      elm.udsDids["202A"] = [0x07, 0xD0]; // 2000 hPa
      expect(await obd.connectWifi(ip: "127.0.0.1", port: elm.port), isTrue);
      final store = PidDefinitionsStore(obd: obd, persist: false);
      final err = await store.addToLibrary(
        name: "Doładowanie rzeczywiste",
        command: "22202A",
        equation: "(A*256)+B",
        unit: "mbar",
        header: "7E0",
      );
      expect(err, isNull);
      expect(store.files.keys, contains(PidDefinitionsStore.libraryFile));
      expect(obd.importedPids.single.shortName, "BOOST");

      // Drugi parametr dopisuje się do tego samego pliku
      expect(await store.addToLibrary(name: "Mój parametr", command: "22202B", equation: "A", unit: ""), isNull);
      expect(obd.importedPids, hasLength(2));

      // Błędne równanie jest odrzucane
      expect(await store.addToLibrary(name: "Zły", command: "22202C", equation: "A+", unit: ""), isNotNull);
      expect(obd.importedPids, hasLength(2));
    });

    test('moduł spoza 7E0: sterowanie przepływem na adres zapytań', () async {
      expect(await obd.connectWifi(ip: "127.0.0.1", port: elm.port), isTrue);
      final store = PidDefinitionsStore(obd: obd, persist: false);
      expect(await store.addToLibrary(name: "Przebieg", command: "222203", equation: "(A*256)+B", unit: "km", header: "714"), isNull);
      await obd.probeImportedNow();
      expect(elm.receivedCommands, containsAll(["ATSH714", "ATFCSH714", "ATFCSM1"]));
    });
  });
}
