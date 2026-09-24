import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/anomaly.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/services/anomaly_engine.dart';
import 'package:autocheck/services/analysis/drive_analyzer.dart';

enum Fault { none, dpf, leak, vgt, egr, limp, railLoad }

/// Fizycznie spójny model diesla 2.0 TDI: przepływ powietrza wynika z obrotów,
/// ciśnienia w kolektorze i napełnienia cylindrów, opór DPF rośnie z przepływem.
Map<String, double> dieselState({
  required double rpm,
  required double pedal,
  required double speed,
  Fault fault = Fault.none,
  Random? rnd,
}) {
  final r = rnd ?? Random(1);
  double noise(double a) => (r.nextDouble() - 0.5) * 2 * a;
  final load = pedal >= 80 ? 1.0 : pedal / 100.0;

  // Zadane doładowanie: rośnie do 1.4 bar przy 2500, trzyma do 3500, potem opada
  double target;
  if (rpm < 1800) {
    target = 0.3 + (rpm - 1000).clamp(0, 800) / 800 * 0.5;
  } else if (rpm < 2500) {
    target = 0.8 + (rpm - 1800) / 700 * 0.6;
  } else if (rpm < 3500) {
    target = 1.4;
  } else {
    target = 1.4 - (rpm - 3500) / 1000 * 0.3;
  }
  target *= load;
  if (fault == Fault.limp) target = min(target, 0.3);

  double actual = target - 0.03;
  double ve = 0.9;
  double dpPerFlow = 0.08;
  double egrAct = 0, egrCmd = pedal < 40 ? 20 : 0;
  double vgtCmd = 50 + 35 * load, vgtAct = vgtCmd;
  double mafFromPressure = 0; // ciśnienie, na podstawie którego przepływomierz mierzy powietrze

  switch (fault) {
    case Fault.dpf:
      if (load >= 1 && rpm > 1900) actual = target * 0.55;
      ve = 0.9 * (1 - 0.35 * ((rpm - 1500) / 2700).clamp(0, 1));
      dpPerFlow = 0.33;
    case Fault.leak:
      if (load >= 1 && rpm > 1900) {
        actual = target * 0.6;
        mafFromPressure = target; // powietrze zmierzone, ale ucieka za przepływomierzem
      }
    case Fault.vgt:
      if (load >= 1 && rpm > 1900) actual = target * 0.6;
      vgtAct = 30;
    case Fault.egr:
      egrCmd = pedal < 40 ? 20 : 0;
      egrAct = 45;
      if (load >= 1 && rpm > 1900) actual = target * 0.7;
      ve = 0.9 * 0.6; // świeże powietrze wypierane przez spaliny
    default:
      break;
  }

  final pAbs = 100 + (mafFromPressure > 0 ? mafFromPressure : actual) * 100;
  final maf = max(4.0, 2.0 / 2 * rpm / 60 * 1.18 * (pAbs / 100) * ve) + noise(1);
  final railTgt = 250 + 1350 * load * (rpm / 4000).clamp(0.3, 1);
  final railAct = fault == Fault.railLoad && load >= 1 ? railTgt * 0.78 : railTgt - 5;

  return {
    "RPM": rpm + noise(10),
    "PEDAL": pedal,
    "LOAD": 20 + 75 * load,
    "SPEED": speed,
    "BOOST": actual + noise(0.02),
    "TARGET_BOOST": target,
    "MAF": maf,
    "DPF_DP": dpPerFlow * maf + noise(0.3),
    "EGR_CMD": egrCmd,
    "EGR_ACT": fault == Fault.egr ? egrAct : egrCmd,
    "VGT_CMD": vgtCmd,
    "VGT_ACT": vgtAct + noise(1),
    "RAIL_TGT": railTgt,
    "F_RAIL": railAct,
    "EGT": 250 + 400 * load + (fault == Fault.dpf ? 150 : 0),
    "BARO": 100,
    "ECT": 90,
    "IAT": 30,
  };
}

/// Jedno przyspieszenie 3. bieg 1500 → 4200 obr/min (10 Hz) z 1 s jazdy przed i po.
List<LogPoint> pull(Fault fault, {double t0 = 0}) {
  final rnd = Random(7);
  final pts = <LogPoint>[];
  double t = t0;
  for (int i = 0; i < 10; i++, t += 100) {
    pts.add(LogPoint(timeMs: t, values: dieselState(rpm: 1500, pedal: 20, speed: 45, fault: fault, rnd: rnd)));
  }
  for (int i = 0; i <= 60; i++, t += 100) {
    final rpm = 1500 + 2700 * i / 60;
    pts.add(LogPoint(timeMs: t, values: dieselState(rpm: rpm, pedal: 100, speed: 45 + i * 0.7, fault: fault, rnd: rnd)));
  }
  for (int i = 0; i < 10; i++, t += 100) {
    pts.add(LogPoint(timeMs: t, values: dieselState(rpm: 3900 - i * 100, pedal: 0, speed: 85, fault: fault, rnd: rnd)));
  }
  return pts;
}

Anomaly? boostDiag(List<Anomaly> list) =>
    list.where((a) => a.paramKey == "BOOST" || a.paramKey == "TARGET_BOOST").firstOrNull;

void main() {
  group('Diagnoza różnicowa braku doładowania', () {
    test('sprawny silnik — brak zastrzeżeń', () {
      final a = DriveAnalyzer.analyze(pull(Fault.none), isDiesel: true);
      expect(a, isEmpty, reason: a.map((e) => e.id).join(", "));
    });

    test('zapchany DPF: turbo nie dmucha, bo spaliny są dławione', () {
      final a = boostDiag(DriveAnalyzer.analyze(pull(Fault.dpf), isDiesel: true))!;
      expect(a.id, startsWith("dpf_underboost_"));
      expect(a.plainSummary, contains("DPF"));
      expect(a.primarySymptom, contains("obr/min"));
      expect(a.correlatedSignals!.keys, containsAll(["BOOST", "DPF_DP", "MAF"]));
      expect(a.falseLeadWarning, contains("Nie wymieniaj turbosprężarki"));
    });

    test('nieszczelność dolotu: powietrze zmierzone, ale ciśnienie nie rośnie; DPF drożny', () {
      final a = boostDiag(DriveAnalyzer.analyze(pull(Fault.leak), isDiesel: true))!;
      expect(a.id, startsWith("boost_leak_diag_"));
      expect(a.ruledOutCauses!.any((r) => r.contains("DPF")), isTrue);
    });

    test('zacięta geometria VGT: pozycja rzeczywista ≠ zadana', () {
      final all = DriveAnalyzer.analyze(pull(Fault.vgt), isDiesel: true);
      expect(boostDiag(all)!.id, startsWith("vgt_underboost_"));
    });

    test('otwarty zawór EGR pod pełnym gazem', () {
      final a = boostDiag(DriveAnalyzer.analyze(pull(Fault.egr), isDiesel: true))!;
      expect(a.id, startsWith("egr_underboost_"));
    });

    test('tryb awaryjny: sterownik sam nie żąda doładowania', () {
      final a = boostDiag(DriveAnalyzer.analyze(pull(Fault.limp), isDiesel: true))!;
      expect(a.id, startsWith("limp_mode_"));
      expect(a.plainSummary, contains("trybie awaryjnym"));
    });
  });

  test('ciśnienie paliwa poniżej zadanego pod obciążeniem → filtr/zasilanie', () {
    final all = DriveAnalyzer.analyze(pull(Fault.railLoad), isDiesel: true);
    final rail = all.firstWhere((a) => a.id.startsWith("rail_low_load_"));
    expect(rail.plainSummary, contains("filtr paliwa"));
    expect(boostDiag(all), isNull);
  });

  test('30 minut sprawnej jazdy (jałowy, trasa, 3 przyspieszenia) — bez fałszywych alarmów', () {
    final rnd = Random(3);
    final pts = <LogPoint>[];
    double t = 0;
    void add(double rpm, double pedal, double speed) {
      final v = dieselState(rpm: rpm, pedal: pedal, speed: speed, rnd: rnd);
      pts.add(LogPoint(timeMs: t, values: v));
      t += 200; // 5 Hz
    }

    for (int i = 0; i < 300; i++) {
      add(820 + rnd.nextDouble() * 30, 0, 0); // 60 s jałowy
    }
    for (int block = 0; block < 3; block++) {
      for (int i = 0; i < 2700; i++) {
        add(1800 + 500 * sin(i / 90) + rnd.nextDouble() * 50, 25 + 10 * sin(i / 40), 90); // 9 min trasy
      }
      for (final p in pull(Fault.none, t0: t)) {
        pts.add(LogPoint(timeMs: p.timeMs, values: p.values));
      }
      t = pts.last.timeMs + 200;
    }
    for (int i = 0; i < 300; i++) {
      add(820 + rnd.nextDouble() * 30, 0, 0);
    }
    expect(pts.last.timeMs, greaterThan(28 * 60 * 1000));

    final pulls = DriveAnalyzer.findPulls(pts, isDiesel: true);
    expect(pulls.length, 3);
    final anomalies = AnomalyEngine.analyzeSession(pts, isDiesel: true);
    expect(anomalies, isEmpty, reason: anomalies.map((a) => "${a.id}: ${a.title}").join("\n"));
  });

  test('uwagi o brakujących danych', () {
    final cruise = [
      for (int i = 0; i < 50; i++) LogPoint(timeMs: i * 200.0, values: {"RPM": 2000, "BOOST": 0.3, "LOAD": 40}),
    ];
    final notes = DriveAnalyzer.coverageNotes(cruise, isDiesel: true);
    expect(notes.any((n) => n.contains("przyspieszenia")), isTrue);
    expect(notes.any((n) => n.contains("zadanego doładowania")), isTrue);
  });
}
