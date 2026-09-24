import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/services/anomaly_engine.dart';

/// Regresje fałszywych alarmów na prawdziwych logach.
void main() {
  List<LogPoint> idleLog({required double boost, double tps = 0, bool withEngineOffStart = true}) {
    final points = <LogPoint>[];
    double t = 0;
    if (withEngineOffStart) {
      for (int i = 0; i < 20; i++, t += 200) {
        points.add(LogPoint(timeMs: t, values: {"RPM": 0, "BOOST": 0.0, "TPS": tps, "SPEED": 0, "STFT": 0}));
      }
    }
    for (int i = 0; i < 60; i++, t += 200) {
      points.add(LogPoint(timeMs: t, values: {
        "RPM": 800 + (i.isEven ? 15 : -15),
        "BOOST": boost,
        "TPS": tps,
        "SPEED": 0,
        "STFT": 0,
      }));
    }
    return points;
  }

  test('rozruch (RPM 0 → 800) nie jest „falowaniem obrotów”', () {
    final anomalies = AnomalyEngine.analyzeSession(idleLog(boost: -0.65));
    expect(anomalies.where((a) => a.id.startsWith("idle_hunting")), isEmpty);
  });

  test('diesel: brak podciśnienia na jałowym to norma, nie zacięte VVT', () {
    final anomalies = AnomalyEngine.analyzeSession(idleLog(boost: 0.0, withEngineOffStart: false), isDiesel: true);
    expect(anomalies, isEmpty);
  });

  test('diesel: otwarta klapa dławiąca (TPS 98%) bez pedału nie jest „gazem w podłodze”', () {
    final points = <LogPoint>[
      for (int i = 0; i < 60; i++)
        LogPoint(timeMs: i * 200.0, values: {"RPM": 1500 + i * 30.0, "BOOST": 0.2, "TPS": 98, "LOAD": 30, "SPEED": 50}),
    ];
    final anomalies = AnomalyEngine.analyzeSession(points, isDiesel: true);
    expect(anomalies.where((a) => a.id.startsWith("dpf_underboost")), isEmpty);
  });

  test('hamowanie silnikiem na biegu nie jest „falowaniem obrotów”', () {
    final points = <LogPoint>[
      for (int i = 0; i < 60; i++)
        LogPoint(timeMs: i * 200.0, values: {"RPM": 1390 - i * 10.0, "TPS": 0, "SPEED": 40 - i * 0.5, "STFT": 0}),
    ];
    final anomalies = AnomalyEngine.analyzeSession(points);
    expect(anomalies.where((a) => a.id.startsWith("idle_hunting")), isEmpty);
  });
}
