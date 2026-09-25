import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/services/analysis/sniff_analyzer.dart';
import 'package:autocheck/services/analysis/did_correlator.dart';

/// Buduje parametr OBD PID (odniesienie) z szeregu wartości surowych (bajty danych).
LearnedParam _obd(int pid, List<(int, List<int>)> samples) {
  final p = LearnedParam("7E0", LearnedKind.obdPid, pid);
  for (final (t, b) in samples) {
    p.samples.add(LearnedSample(t, b));
  }
  return p;
}

LearnedParam _did(int did, List<(int, List<int>)> samples) {
  final p = LearnedParam("7E0", LearnedKind.udsDid, did);
  for (final (t, b) in samples) {
    p.samples.add(LearnedSample(t, b));
  }
  return p;
}

void main() {
  test("nieznany DID śledzący RPM jest rozpoznany jako RPM ze skalą", () {
    // RPM od 800 do 3000; OBD 010C: wartość = (A*256+B)/4  → raw = rpm*4
    // Nieznany DID: uint16 = rpm*8  → oczekiwana skala ≈ 0.125 (rpm = raw*0.125)
    final rpmObd = <(int, List<int>)>[];
    final unknown = <(int, List<int>)>[];
    for (int i = 0; i < 20; i++) {
      final t = i * 100;
      final rpm = 800 + i * 110; // 800..2890
      final raw4 = rpm * 4;
      rpmObd.add((t, [raw4 >> 8, raw4 & 0xFF]));
      final raw8 = rpm * 8;
      unknown.add((t, [raw8 >> 8, raw8 & 0xFF, 0x00]));
    }

    final params = [_obd(0x0C, rpmObd), _did(0x20AB, unknown)];
    final guesses = DidCorrelator.analyze(params, minR: 0.95, minPoints: 8);

    expect(guesses, isNotEmpty);
    final g = guesses.first;
    expect(g.canonicalKey, "RPM");
    expect(g.r.abs(), greaterThan(0.99));
    expect(g.byteOffset, 0);
    expect(g.byteLen, 2);
    expect(g.scale, closeTo(0.125, 0.01));
    expect(g.offset, closeTo(0.0, 1.0));
    expect(g.confidencePct, greaterThanOrEqualTo(99));
  });

  test("stały (niezmienny) DID nie generuje propozycji", () {
    final rpmObd = <(int, List<int>)>[];
    for (int i = 0; i < 20; i++) {
      final rpm = 800 + i * 110;
      final raw4 = rpm * 4;
      rpmObd.add((i * 100, [raw4 >> 8, raw4 & 0xFF]));
    }
    final constDid = [for (int i = 0; i < 20; i++) (i * 100, [0x12, 0x34])];
    final guesses = DidCorrelator.analyze([_obd(0x0C, rpmObd), _did(0x2000, constDid)]);
    expect(guesses, isEmpty);
  });

  test("bez sygnałów odniesienia brak propozycji", () {
    final noise = [for (int i = 0; i < 20; i++) (i * 100, [i & 0xFF, (i * 3) & 0xFF])];
    final guesses = DidCorrelator.analyze([_did(0x2000, noise)]);
    expect(guesses, isEmpty);
  });

  test("słaba korelacja poniżej progu jest odrzucana", () {
    // Odniesienie rośnie liniowo, nieznany DID skacze pseudolosowo → niska korelacja
    final rpmObd = <(int, List<int>)>[];
    final rnd = [3, 200, 15, 180, 40, 90, 250, 5, 130, 70, 210, 33, 190, 8, 160, 99, 240, 12, 140, 60];
    final unknown = <(int, List<int>)>[];
    for (int i = 0; i < 20; i++) {
      final rpm = 800 + i * 110;
      final raw4 = rpm * 4;
      rpmObd.add((i * 100, [raw4 >> 8, raw4 & 0xFF]));
      unknown.add((i * 100, [rnd[i]]));
    }
    final guesses = DidCorrelator.analyze([_obd(0x0C, rpmObd), _did(0x2000, unknown)], minR: 0.9);
    expect(guesses, isEmpty);
  });
}
