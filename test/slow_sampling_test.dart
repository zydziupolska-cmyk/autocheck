import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/anomaly.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/services/anomaly_engine.dart';

/// Postój na wolnych obrotach z falowaniem (okres ~3 s) próbkowany co [dtMs].
List<LogPoint> _idleHunting({
  required double dtMs,
  double seconds = 40,
  double? stft,
  double? ltft,
  double boost = -0.65,
  double? evap,
  double amplitude = 180,
}) {
  final rnd = Random(3);
  return [
    for (double t = 0; t <= seconds * 1000; t += dtMs)
      LogPoint(timeMs: t, values: {
        "RPM": 850 + sin(t / 1000 * 2 * pi / 3) * amplitude + rnd.nextDouble() * 20,
        "TPS": 0,
        "SPEED": 0,
        "ECT": 90,
        "BOOST": boost,
        if (stft != null) "STFT": stft + rnd.nextDouble() * 2 - 1,
        if (ltft != null) "LTFT": ltft,
        if (evap != null) "EVAP_VP": evap,
      }),
  ];
}

Anomaly? _hunt(List<Anomaly> a) => a.where((x) => x.id.startsWith("idle_hunting_")).firstOrNull;

void main() {
  group("Falowanie / EVAP przy różnej szybkości odpytywania", () {
    test("wolne auto (1 próbka/s): falowanie + mocno ujemne korekty → zawór EVAP", () {
      final a = AnomalyEngine.analyzeSession(_idleHunting(dtMs: 1000, stft: -9, ltft: -8));
      final h = _hunt(a);
      expect(h, isNotNull, reason: "reguła musi działać przy 1 próbce/s");
      expect(h!.title, contains("EVAP"));
      expect(h.plainSummary, contains("Testem zaworu EVAP"));
    });

    test("bardzo wolne auto (1 próbka / 1,7 s) nadal wykrywa falowanie", () {
      expect(_hunt(AnomalyEngine.analyzeSession(_idleHunting(dtMs: 1700, seconds: 60, stft: -10, ltft: -9))), isNotNull);
    });

    test("szybki CAN (20 próbek/s): falowanie + dodatnie korekty → lewe powietrze", () {
      final h = _hunt(AnomalyEngine.analyzeSession(_idleHunting(dtMs: 50, stft: 9, ltft: 8)));
      expect(h, isNotNull);
      expect(h!.title, contains("lewego powietrza"));
    });

    test("bez korekt w logu: nie zgaduje przyczyny, kieruje do testu EVAP", () {
      final h = _hunt(AnomalyEngine.analyzeSession(_idleHunting(dtMs: 500)));
      expect(h, isNotNull);
      expect(h!.title, isNot(contains("EVAP")));
      expect(h.observedValueText, contains("brak wiarygodnych korekt"));
      expect(h.plainSummary, contains("Test zaworu EVAP"));
    });

    test("korekty-wartowniki (+99,2%) są ignorowane", () {
      final h = _hunt(AnomalyEngine.analyzeSession(_idleHunting(dtMs: 1000, stft: 99.2)));
      expect(h, isNotNull);
      expect(h!.title, isNot(contains("lewego powietrza")));
    });

    test("zawór EVAP niewysterowany (0%), a mieszanka bogata → zawór nie domyka", () {
      final h = _hunt(AnomalyEngine.analyzeSession(_idleHunting(dtMs: 500, stft: -9, ltft: -8, evap: 0)));
      expect(h!.ruledOutCauses!.join(" "), contains("nie domyka"));
    });

    test("jednostajny spadek obrotów po rozgrzaniu to nie falowanie", () {
      final pts = [
        for (double t = 0; t <= 30000; t += 1000)
          LogPoint(timeMs: t, values: {"RPM": 1250 - t / 30000 * 450, "TPS": 0, "SPEED": 0, "ECT": 80}),
      ];
      expect(_hunt(AnomalyEngine.analyzeSession(pts)), isNull);
    });

    test("stabilne wolne obroty nie dają alarmu przy żadnej szybkości", () {
      for (final dt in [50.0, 500.0, 1500.0]) {
        expect(_hunt(AnomalyEngine.analyzeSession(_idleHunting(dtMs: dt, amplitude: 30, stft: 1))), isNull, reason: "dt=$dt");
      }
    });
  });

  group("VVT: czas trwania zamiast liczby próbek", () {
    test("chwilowy (1 s) wzrost ciśnienia w kolektorze przy szybkim próbkowaniu → brak alarmu", () {
      final pts = [
        for (double t = 0; t <= 20000; t += 50)
          LogPoint(timeMs: t, values: {"RPM": 800, "TPS": 0, "SPEED": 0, "BOOST": t > 5000 && t < 6000 ? -0.35 : -0.68}),
      ];
      expect(AnomalyEngine.analyzeSession(pts).where((a) => a.id.startsWith("vvt_jammed_")), isEmpty);
    });

    test("trwały zanik podciśnienia (8 s) przy wolnym próbkowaniu → alarm, bez fikcyjnych korekt", () {
      final pts = [
        for (double t = 0; t <= 30000; t += 1000)
          LogPoint(timeMs: t, values: {"RPM": 800, "TPS": 0, "SPEED": 0, "BOOST": t >= 10000 && t <= 18000 ? -0.35 : -0.68}),
      ];
      final v = AnomalyEngine.analyzeSession(pts).where((a) => a.id.startsWith("vvt_jammed_")).toList();
      expect(v, hasLength(1));
      expect(v.single.correlatedSignals!["Korekty"], "brak korekt w logu");
      expect(v.single.ruledOutCauses!.join(" "), isNot(contains("lewe powietrze")));
    });
  });

  group("Wyłączona ekologia: tylko rozgrzany diesel i minuta danych", () {
    List<LogPoint> egrZero({required double seconds, required double dtMs, double ect = 90}) => [
          for (double t = 0; t <= seconds * 1000; t += dtMs)
            LogPoint(timeMs: t, values: {"RPM": 1500, "TPS": 20, "PEDAL": 20, "ECT": ect, "EGR_CMD": 0, "SPEED": 50}),
        ];
    bool egrDelete(List<Anomaly> a) => a.any((x) => x.id.startsWith("egr_software_delete_"));

    test("3 s danych przy 20 próbkach/s (60 próbek) to za mało na oskarżenie", () {
      expect(egrDelete(AnomalyEngine.analyzeSession(egrZero(seconds: 3, dtMs: 50), isDiesel: true)), isFalse);
    });

    test("benzyna z zamkniętym EGR to nie przeróbka", () {
      expect(egrDelete(AnomalyEngine.analyzeSession(egrZero(seconds: 120, dtMs: 1000))), isFalse);
    });

    test("zimny diesel celowo zamyka EGR", () {
      expect(egrDelete(AnomalyEngine.analyzeSession(egrZero(seconds: 120, dtMs: 1000, ect: 40), isDiesel: true)), isFalse);
    });

    test("rozgrzany diesel, 2 min z EGR = 0% → podejrzenie przeróbki", () {
      expect(egrDelete(AnomalyEngine.analyzeSession(egrZero(seconds: 120, dtMs: 1000), isDiesel: true)), isTrue);
    });
  });

  test("przyspieszenie próbkowane 2 razy/s jest analizowane jako okno pełnego gazu (stuk)", () {
    final pts = [
      for (int i = 0; i < 16; i++)
        LogPoint(timeMs: i * 500.0, values: {
          "RPM": 2000 + i * 250.0,
          "TPS": 100,
          "ECT": 90,
          "IGN": (i >= 8 && i <= 10) ? 12.0 : 22.0,
        }),
    ];
    expect(AnomalyEngine.analyzeSession(pts).where((a) => a.paramKey == "IGN"), hasLength(1));
  });
}
