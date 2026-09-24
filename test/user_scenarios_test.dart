import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/anomaly.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/services/anomaly_engine.dart';

/// Scenariusze z prawdziwych przypadków warsztatowych.
void main() {
  // ---------------------------------------------------------------------------
  // Skoda Rapid 1.2/1.4 TSI (wtrysk bezpośredni): lejący wtryskiwacz cylindra 1.
  // Na jałowym pompa podaje mało paliwa, a wtrysk upuszcza je z szyny do cylindra:
  // ciśnienie spada (P0087), mieszanka za bogata, cylinder 1 zalewany.
  // Pod obciążeniem pompa nadąża i ciśnienie jest w normie.
  // ---------------------------------------------------------------------------
  List<LogPoint> rapidLog({bool leak = true, bool withMisfireCounters = true, bool portInjection = false}) {
    final rnd = Random(11);
    final pts = <LogPoint>[];
    double t = 0;
    double mis1 = 2;
    void add(Map<String, double> v) {
      pts.add(LogPoint(timeMs: t, values: v));
      t += 200;
    }

    double rail(double nominal) => portInjection ? 3.8 + rnd.nextDouble() * 0.1 : nominal;

    // 2 min wolnych obrotów
    for (int i = 0; i < 600; i++) {
      if (leak && i % 25 == 0) mis1 += 1;
      add({
        "RPM": (leak ? 760 + rnd.nextDouble() * 90 : 790 + rnd.nextDouble() * 20),
        "SPEED": 0,
        "PEDAL": 0,
        "TPS": 3,
        "LOAD": 22,
        "F_RAIL": rail(leak ? 17 + rnd.nextDouble() * 5 : 42 + rnd.nextDouble() * 3),
        "STFT": leak ? -14 + rnd.nextDouble() * 3 : rnd.nextDouble() * 2 - 1,
        "LTFT": leak ? -9 : 1.5,
        "BOOST": -0.65,
        "MAF": 2.8,
        "ECT": 88,
        if (withMisfireCounters) "MIS_1": leak ? mis1 : 0,
        if (withMisfireCounters) "MIS_2": 0,
        if (withMisfireCounters) "MIS_3": 0,
        if (withMisfireCounters) "MIS_4": 0,
      });
    }
    // jazda i dwa przyspieszenia na 3. biegu
    for (int pull = 0; pull < 2; pull++) {
      for (int i = 0; i < 150; i++) {
        add({"RPM": 1900 + rnd.nextDouble() * 200, "SPEED": 50, "PEDAL": 20, "TPS": 15, "LOAD": 35,
            "F_RAIL": rail(60 + rnd.nextDouble() * 5), "STFT": rnd.nextDouble() * 2 - 1, "LTFT": leak ? -9 : 1.5,
            "BOOST": -0.2, "MAF": 12, "ECT": 90});
      }
      for (int i = 0; i <= 30; i++) {
        final rpm = 1600 + 3600 * i / 30;
        add({"RPM": rpm, "SPEED": 50 + i.toDouble(), "PEDAL": 100, "TPS": 100, "LOAD": 90,
            "F_RAIL": rail(110 + rpm / 60), "STFT": 0, "LTFT": leak ? -9 : 1.5,
            "BOOST": rpm < 2000 ? 0.4 : 1.0, "MAF": rpm / 40, "ECT": 90});
      }
    }
    return pts;
  }

  group('Skoda Rapid TSI — lejący wtryskiwacz 1 na wolnych obrotach', () {
    test('z licznikami wypadania zapłonów (Mode 06): wskazuje wtrysk cylindra 1 i tłumaczy', () {
      final anomalies = AnomalyEngine.analyzeSession(rapidLog(), dtcCodes: ["P0087"]);
      final rail = anomalies.firstWhere((a) => a.paramKey == "F_RAIL");
      expect(rail.id, startsWith("rail_low_idle_cyl1_"));
      expect(rail.title, contains("Lejący wtryskiwacz cylindra 1"));
      expect(rail.plainSummary, contains("wolnych obrotach"));
      expect(rail.plainSummary, contains("za bogata"));
      expect(rail.plainSummary, contains("lejącego wtryskiwacza cylindra 1"));
      expect(rail.plainSummary, contains("Nie wymieniaj pompy"));
      expect(rail.correlatedSignals!["Cylinder"], contains("Mode 06"));
      expect(rail.recommendations.any((r) => r.contains("świecę cylindra 1")), isTrue);
      // Wypadanie zapłonu cylindra 1 nie może być opisane jako „uszkodzona cewka”
      expect(anomalies.any((a) => a.id.startsWith("misfire_spark_1")), isFalse);
      // P0087 jest wyjaśniony przez analizę — bez osobnego wpisu
      expect(anomalies.any((a) => a.id == "dtc_P0087"), isFalse);
    });

    test('bez liczników, z kodem P0301: cylinder z kodu błędu', () {
      final anomalies = AnomalyEngine.analyzeSession(rapidLog(withMisfireCounters: false), dtcCodes: ["P0087", "P0301"]);
      final rail = anomalies.firstWhere((a) => a.paramKey == "F_RAIL");
      expect(rail.id, startsWith("rail_low_idle_cyl1_"));
      expect(rail.correlatedSignals!["Cylinder"], contains("P0301"));
      expect(anomalies.any((a) => a.id == "dtc_P0301"), isFalse);
    });

    test('bez informacji o cylindrze: diagnozuje lejący wtrysk, ale NIE zgaduje cylindra', () {
      final anomalies = AnomalyEngine.analyzeSession(rapidLog(withMisfireCounters: false));
      final rail = anomalies.firstWhere((a) => a.paramKey == "F_RAIL");
      expect(rail.id, startsWith("rail_low_idle_"));
      expect(rail.id, isNot(contains("cyl")));
      expect(rail.title, contains("Lejący wtryskiwacz"));
      expect(rail.plainSummary, contains("Którego cylindra — z tych danych nie wynika"));
      expect(rail.plainSummary, isNot(contains("cylindra 1")));
    });

    test('sprawny silnik — brak zastrzeżeń', () {
      expect(AnomalyEngine.analyzeSession(rapidLog(leak: false)), isEmpty);
    });

    test('wtrysk pośredni (ok. 4 bar) nie jest brany za spadek ciśnienia', () {
      final anomalies = AnomalyEngine.analyzeSession(rapidLog(leak: false, portInjection: true));
      expect(anomalies.where((a) => a.paramKey == "F_RAIL"), isEmpty);
    });

    test('sam kod P0087 bez danych o ciśnieniu: wyjaśnienie i co nagrać', () {
      final pts = rapidLog(leak: false).map((p) => LogPoint(timeMs: p.timeMs, values: Map.of(p.values)..remove("F_RAIL"))).toList();
      final dtc = AnomalyEngine.analyzeSession(pts, dtcCodes: ["P0087"]).firstWhere((a) => a.id == "dtc_P0087");
      expect(dtc.plainSummary, contains("nagraj"));
      expect(dtc.hypotheses.any((h) => h.contains("wtryskiwacz")), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Luźna opaska / dziura w dolocie za przepływomierzem
  // ---------------------------------------------------------------------------
  List<LogPoint> turboPull({
    required bool leak,
    bool withTarget = true,
    bool stickyVgt = false,
    bool diesel = true,
  }) {
    final rnd = Random(5);
    final pts = <LogPoint>[];
    double t = 0;
    for (int i = 0; i < 15; i++, t += 100) {
      pts.add(LogPoint(timeMs: t, values: {"RPM": 1500, "PEDAL": 20, "LOAD": 30, "SPEED": 45, "BOOST": 0.2, if (withTarget) "TARGET_BOOST": 0.2, "MAF": 30, "BARO": 100}));
    }
    for (int i = 0; i <= 60; i++, t += 100) {
      final rpm = 1500 + 2700 * i / 60;
      final target = rpm < 2500 ? 0.6 + (rpm - 1500) / 1000 * 0.8 : 1.4 - (rpm - 2500) / 1700 * 0.2;
      double actual = target - 0.03;
      double metered = actual; // ciśnienie, przy którym przepływomierz mierzy powietrze
      if (leak && rpm > 1900) {
        actual = target * 0.65;
        metered = target;
      }
      if (stickyVgt) actual = rpm < 2300 ? target + 0.35 : (rpm > 2700 ? target * 0.6 : target);
      final maf = 2.0 / 2 * rpm / 60 * 1.18 * (1 + metered) * 0.9 + (rnd.nextDouble() - 0.5);
      pts.add(LogPoint(timeMs: t, values: {
        "RPM": rpm, "PEDAL": 100, "LOAD": 95, "SPEED": 45 + i * 0.6, "BOOST": actual,
        if (withTarget) "TARGET_BOOST": target, "MAF": maf, "BARO": 100,
        if (diesel) "DPF_DP": 0.07 * maf, if (diesel) "EGR_ACT": 0, if (diesel) "EGR_CMD": 0,
      }));
    }
    for (int i = 0; i < 10; i++, t += 100) {
      pts.add(LogPoint(timeMs: t, values: {"RPM": 3900 - i * 100.0, "PEDAL": 0, "LOAD": 10, "SPEED": 80, "BOOST": 0.1, if (withTarget) "TARGET_BOOST": 0.0, "MAF": 20, "BARO": 100}));
    }
    return pts;
  }

  Anomaly? boost(List<Anomaly> a) => a.where((x) => x.paramKey == "BOOST" || x.paramKey == "TARGET_BOOST").firstOrNull;

  group('Luźna opaska / nieszczelność dolotu', () {
    test('diesel z zadanym doładowaniem: nieszczelność, DPF i EGR wykluczone', () {
      final a = boost(AnomalyEngine.analyzeSession(turboPull(leak: true), isDiesel: true))!;
      expect(a.id, startsWith("boost_leak_diag_"));
      expect(a.plainSummary, contains("test szczelności dolotu"));
      expect(a.ruledOutCauses!.any((r) => r.contains("DPF")), isTrue);
      expect(a.ruledOutCauses!.any((r) => r.contains("EGR")), isTrue);
    });

    test('benzyna bez zadanego doładowania, ale z kodem P0299 od sterownika: nieszczelność', () {
      final a = boost(AnomalyEngine.analyzeSession(turboPull(leak: true, withTarget: false, diesel: false), dtcCodes: ["P0299"]))!;
      expect(a.correlatedSignals!["DTC"], contains("P0299"));
      expect(a.id, startsWith("boost_leak_diag_"));
    });

    test('benzyna bez zadanego i bez kodu: umiarkowany wyciek NIE jest wykrywany (granica metody)', () {
      // Bez wartości zadanej i bez kodu nie wiadomo, ile turbo powinno dawać — 0.9 bar
      // może być normą dla tego silnika. Asystent mówi wtedy wprost, czego mu brakuje.
      final pts = turboPull(leak: true, withTarget: false, diesel: false);
      expect(boost(AnomalyEngine.analyzeSession(pts)), isNull);
    });

    test('zsunięty wąż pod pełnym gazem (nagły spadek ciśnienia)', () {
      final pts = turboPull(leak: false);
      for (int i = 0; i < pts.length; i++) {
        final rpm = pts[i].values["RPM"]!;
        if (pts[i].values["PEDAL"] == 100 && rpm > 3200) {
          pts[i] = LogPoint(timeMs: pts[i].timeMs, values: {...pts[i].values, "BOOST": 0.35});
        }
      }
      final anomalies = AnomalyEngine.analyzeSession(pts, isDiesel: true);
      expect(anomalies.any((a) => a.id.startsWith("boost_")), isTrue);
    });
  });

  test('zapieczona geometria turbiny bez czujnika pozycji VGT: przeładowanie nisko, brak ciśnienia wysoko', () {
    final a = boost(AnomalyEngine.analyzeSession(turboPull(leak: false, stickyVgt: true), isDiesel: true))!;
    expect(a.id, startsWith("vgt_underboost_"));
    expect(a.rootCauseConclusion, contains("zapieczonych"));
  });
}
