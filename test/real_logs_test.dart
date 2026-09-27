import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/log_point.dart';
import 'dart:math';
import 'package:autocheck/models/anomaly.dart';
import 'package:autocheck/services/anomaly_engine.dart';
import 'package:autocheck/services/analysis/drive_state.dart';

/// Prawdziwe logi z warsztatu: VW Touran 1T 2.0 TDI (EA189), vLinker MC (STN1151).
/// Pełne przyspieszenia; mechanik potwierdził okopcone, zapieczone cięgno siłownika
/// podciśnieniowego turbiny (VGT) — turbo nie osiągało pełnego doładowania.
List<LogPoint> loadCsv(String path) {
  final lines = File(path).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
  final header = lines.first.split(",");
  return [
    for (final l in lines.skip(1))
      () {
        final f = l.split(",");
        final values = <String, double>{};
        for (int i = 2; i < header.length && i < f.length; i++) {
          final v = double.tryParse(f[i]);
          if (v != null) values[header[i]] = v;
        }
        return LogPoint(timeMs: double.parse(f[0]), values: values);
      }(),
  ];
}

void main() {
  for (final file in ["touran_1t_wot_1.csv", "touran_1t_wot_2.csv"]) {
    test('Touran 1T, $file: niedoładowanie w całym zakresie, podejrzenie VGT', () {
      final anomalies = AnomalyEngine.analyzeSession(loadCsv("test/fixtures/$file"), isDiesel: true);
      final boost = anomalies.where((a) => a.paramKey == "BOOST").toList();
      expect(boost, isNotEmpty, reason: anomalies.map((a) => a.title).join("; "));
      final a = boost.first;
      expect((a.rootCauseConclusion ?? "").toLowerCase(), contains("geometria"));
      expect(a.startRpm, lessThanOrEqualTo(2500));
      expect(a.endRpm, greaterThanOrEqualTo(4000));
    });
  }

  test('Diesel: falowanie na jałowym nie daje benzynowej diagnozy EVAP/EW10', () {
    final pts = loadCsv("test/fixtures/diesel_drive_idle.csv");
    final anomalies = AnomalyEngine.analyzeSession(pts, isDiesel: true);
    // Reguła biegu jałowego jest benzynowa (EVAP, cewki, EW10) — nie może odpalić na dieslu
    expect(anomalies.where((a) => a.id.startsWith("idle_hunting_")), isEmpty);
    for (final a in anomalies) {
      final text = "${a.title} ${a.rootCauseConclusion ?? ''} ${a.hypotheses.join(' ')}".toLowerCase();
      expect(text.contains("evap"), isFalse, reason: "benzynowa usterka na dieslu: ${a.title}");
      expect(text.contains("ew10"), isFalse, reason: "benzynowa usterka na dieslu: ${a.title}");
    }
  });

  group("Peugeot 307 2.0 16V (EW10), prawdziwa jazda: odczyt co ~1,9 s, przepustnica 11% na wolnych", () {
    const file = "test/fixtures/peugeot307_ew10_drive.csv";

    test("zwykła jazda nie daje fałszywych alarmów (stara wersja: 7× „stuk”)", () {
      final a = AnomalyEngine.analyzeSession(loadCsv(file));
      expect(a.where((x) => x.paramKey == "IGN"), isEmpty, reason: a.map((e) => e.title).join("; "));
      expect(a.where((x) => x.id.startsWith("trim_")), isEmpty);
      expect(a.where((x) => x.id.startsWith("lazy_o2")), isEmpty);
      expect(a.where((x) => x.severity == AnomalySeverity.critical), isEmpty);
    });

    test("falowanie na postoju w tym logu byłoby wykryte mimo przepustnicy 11% i wolnego odczytu", () {
      final pts = loadCsv(file);
      // Postój na końcu logu (od ~177 s, prędkość 0): wstawiamy falowanie ±180 obr/min
      final hunted = [
        for (final p in pts)
          p.timeMs >= 177000
              ? (LogPoint(timeMs: p.timeMs, values: {
                  ...p.values,
                  "RPM": 760 + sin(p.timeMs / 1000 * 2 * pi / 5) * 180,
                }))
              : p,
      ];
      final a = AnomalyEngine.analyzeSession(hunted);
      expect(a.where((x) => x.id.startsWith("idle_hunting_")), hasLength(1), reason: a.map((e) => e.title).join("; "));
    });
  });

  group("Kalibracja przepustnicy (PID 11 bezwzględny)", () {
    test("11% na wolnych = 0% otwarcia, 81% przy pełnym gazie ≈ 99%", () {
      expect(DriveState.throttleOpening(11.37, 11.37), 0);
      expect(DriveState.throttleOpening(81.18, 11.37), greaterThan(95));
      expect(DriveState.throttleOpening(52.55, 11.37), inInclusiveRange(55, 62));
    });

    test("stan jazdy na żywo z wyuczonym położeniem zamkniętym", () {
      final wot = DriveState.withThrottleOpening({"TPS": 76, "RPM": 3000}, closed: 11.4, isDiesel: false);
      expect(DriveState.isFullThrottle(wot, isDiesel: false), isTrue, reason: "76% bezwzględnie to pełny gaz");
      final idle = DriveState.withThrottleOpening({"TPS": 12.2, "RPM": 720, "SPEED": 0}, closed: 11.4, isDiesel: false);
      expect(DriveState.isIdle(idle, isDiesel: false), isTrue, reason: "12% bezwzględnie to gaz puszczony");
      expect(DriveState.isIdle({"TPS": 12.2, "RPM": 720, "SPEED": 0}, isDiesel: false), isFalse,
          reason: "bez kalibracji 12% nie jest rozpoznawane jako wolne — stąd poprawka");
    });

    test("log bez puszczonego gazu (sama równa jazda): bez przeliczania", () {
      final cruise = [for (int i = 0; i < 20; i++) LogPoint(timeMs: i * 500.0, values: {"TPS": 20, "RPM": 2200, "LOAD": 35})];
      expect(DriveState.normalizeThrottle(cruise, isDiesel: false).first.values["TPS"], 20);
    });

    test("diesel i przepustnica już względna (0% na wolnych) bez zmian", () {
      final d = [for (int i = 0; i < 10; i++) LogPoint(timeMs: i * 100.0, values: {"TPS": 90, "RPM": 800})];
      expect(DriveState.normalizeThrottle(d, isDiesel: true).first.values["TPS"], 90);
      final rel = [for (int i = 0; i < 10; i++) LogPoint(timeMs: i * 100.0, values: {"TPS": i * 10.0, "RPM": 800})];
      expect(DriveState.normalizeThrottle(rel, isDiesel: false)[5].values["TPS"], 50);
    });
  });
}
