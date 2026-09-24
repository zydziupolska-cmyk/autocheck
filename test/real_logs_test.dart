import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/services/anomaly_engine.dart';

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
}
