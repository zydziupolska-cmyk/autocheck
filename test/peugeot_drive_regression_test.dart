import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/services/anomaly_engine.dart';

import 'support/synthetic_logs.dart';

/// Jazda diagnostyczna wolnossącej benzyny (jak Peugeot 307 2.0): lekkie obciążenie z dużym
/// wyprzedzeniem zapłonu, odpuszczanie gazu, zmiany biegów, wolne obroty. Korekty co jakiś
/// czas mają wartość-wartownik +99,2% (0xFF, pętla otwarta), sonda odpytywana ~1 raz/s.
List<LogPoint> _normalDrive({bool sentinelTrims = true}) {
  final rnd = Random(7);
  final pts = <LogPoint>[];
  double t = 0;
  for (int i = 0; i < 600; i++) {
    t += 500; // 2 próbki/s, 300 s
    final phase = (i ~/ 20) % 4; // 10-sekundowe fazy
    double rpm, tps, ign;
    switch (phase) {
      case 0: // spokojna jazda — duże wyprzedzenie
        rpm = 2600 + rnd.nextDouble() * 400;
        tps = 15 + rnd.nextDouble() * 8;
        ign = 38 + rnd.nextDouble() * 8;
      case 1: // przyspieszanie z mocnym gazem (bez stuku, kąt stabilny/rosnący)
        rpm = 2800 + (i % 20) * 60.0;
        tps = 70;
        ign = 18 + (i % 20) * 0.2 + rnd.nextDouble() * 0.6;
      case 2: // odpuszczenie gazu / zmiana biegu — kąt spada do -2,5°
        rpm = 3000 - (i % 20) * 80.0;
        tps = i % 5 == 0 ? 60 : 0;
        ign = -2.5;
      default: // wolne obroty
        rpm = 800;
        tps = 0;
        ign = 10 + rnd.nextDouble() * 4;
    }
    final stft = sentinelTrims && i % 7 == 0 ? 99.2 : (rnd.nextDouble() * 6 - 3);
    pts.add(LogPoint(timeMs: t, values: {
      "RPM": rpm,
      "TPS": tps,
      "IGN": ign,
      "STFT": stft,
      "LTFT": 2.3,
      "ECT": 90,
      "IAT": 30,
      "O2_V": i.isEven ? 0.15 + rnd.nextDouble() * 0.1 : 0.7 + rnd.nextDouble() * 0.1,
      "SPEED": 60,
    }));
  }
  return pts;
}

/// Mocne przyspieszenie z prawdziwym cofaniem zapłonu (stuk) w kilku miejscach.
List<LogPoint> _wotWithKnock({int dips = 3}) {
  final pts = <LogPoint>[];
  for (int i = 0; i < 200; i++) {
    final rpm = 2000 + i * 22.0;
    double ign = 20 + i * 0.03;
    for (int d = 0; d < dips; d++) {
      final at = 50 + d * 45;
      if (i >= at && i < at + 6) ign -= 9; // cofnięcie o ~9° przez 0,3 s
    }
    pts.add(LogPoint(timeMs: i * 50.0, values: {"RPM": rpm, "TPS": 100, "IGN": ign, "ECT": 90, "IAT": 30}));
  }
  return pts;
}

void main() {
  test("zwykła jazda: brak fałszywego stuku, korekt +99% i leniwej sondy", () {
    final a = AnomalyEngine.analyzeSession(_normalDrive());
    expect(a.where((x) => x.paramKey == "IGN"), isEmpty, reason: a.map((e) => e.title).join(", "));
    expect(a.where((x) => x.id.startsWith("trim_")), isEmpty);
    expect(a.where((x) => x.id.startsWith("lazy_o2")), isEmpty);
  });

  test("prawdziwy stuk pod pełnym gazem: jeden scalony wynik z liczbą zdarzeń", () {
    final a = AnomalyEngine.analyzeSession(_wotWithKnock(dips: 3));
    final knock = a.where((x) => x.paramKey == "IGN").toList();
    expect(knock, hasLength(1));
    expect(knock.single.observedValueText, contains("3 zdarzenia"));
    expect(knock.single.plainSummary, isNotNull);
  });

  test("syntetyczny scenariusz stuku (turbo, 4000–5300 obr/min) jest wykrywany", () {
    final a = AnomalyEngine.analyzeSession(generateSyntheticRun(SyntheticScenario.knockRetard));
    expect(a.where((x) => x.paramKey == "IGN"), hasLength(1));
  });

  test("korekty: stale +20% w rozgrzanej jeździe to uboga mieszanka", () {
    final pts = [
      for (int i = 0; i < 120; i++)
        LogPoint(timeMs: i * 500.0, values: {"RPM": 2200, "TPS": 20, "STFT": 8, "LTFT": 13, "ECT": 90}),
    ];
    final a = AnomalyEngine.analyzeSession(pts);
    expect(a.where((x) => x.id.startsWith("trim_pos")), hasLength(1));
  });

  test("korekty: ubogo tylko na wolnych obrotach wskazuje lewe powietrze", () {
    final pts = [
      for (int i = 0; i < 120; i++)
        LogPoint(timeMs: i * 500.0, values: {
          "RPM": i < 60 ? 780 : 2400,
          "TPS": i < 60 ? 0 : 20,
          "STFT": i < 60 ? 12 : 1,
          "LTFT": i < 60 ? 8 : 1,
          "ECT": 90,
        }),
    ];
    final a = AnomalyEngine.analyzeSession(pts);
    final t = a.where((x) => x.id.startsWith("trim_pos")).toList();
    expect(t, hasLength(1));
    expect(t.single.title, contains("lewe powietrze"));
  });
}
