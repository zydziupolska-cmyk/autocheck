import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/anomaly.dart';
import 'package:autocheck/models/engine_profiles.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/services/report_builder.dart';

LogSession _session() => LogSession(
      id: "s1",
      title: "Test",
      createdAt: DateTime(2026, 3, 14, 10, 30),
      activePidKeys: const ["RPM", "BOOST"],
      mode: LogMode.pull,
      vehicleLabel: "Volkswagen Passat (B7)",
      vin: "WVWZZZ3CZEE000001",
      engineInfo: "Volkswagen 2.0 TDI CFFB",
      points: [
        const LogPoint(timeMs: 0, values: {"RPM": 900, "BOOST": 0.1}),
        const LogPoint(timeMs: 2000, values: {"RPM": 3200, "BOOST": 1.35}),
        const LogPoint(timeMs: 4000, values: {"RPM": 4100, "BOOST": 1.28}),
      ],
    );

Anomaly _boostLeak() => const Anomaly(
      id: "boost_leak",
      title: "Spadek doładowania pod obciążeniem",
      severity: AnomalySeverity.critical,
      paramKey: "BOOST",
      startMs: 2000,
      endMs: 3000,
      startRpm: 3200,
      endRpm: 3600,
      observedValueText: "Spadek z 1.35 bar do 0.80 bar",
      description: "Ciśnienie doładowania nie utrzymuje wartości zadanej.",
      hypotheses: ["Nieszczelność intercoolera", "Zawór N75"],
      recommendations: ["Sprawdź szczelność układu dolotowego", "Sprawdź zawór regulacji"],
      plainSummary: "Turbina nie utrzymuje doładowania — spadek mocy pod obciążeniem.",
    );

void main() {
  group("DiagnosisReport", () {
    test("tekst zawiera pojazd, pomiar, wynik i usterkę", () {
      final r = DiagnosisReport(
        session: _session(),
        anomalies: [_boostLeak()],
        engine: EngineProfiles.identify("Volkswagen 2.0 TDI CFFB"),
        generatedAt: DateTime(2026, 3, 14, 12, 0),
      );
      final t = r.toPlainText();
      expect(t, contains("RAPORT DIAGNOSTYCZNY"));
      expect(t, contains("Volkswagen Passat (B7)"));
      expect(t, contains("WVWZZZ3CZEE000001"));
      expect(t, contains("Spadek doładowania pod obciążeniem"));
      expect(t, contains("poważną usterkę"));
      expect(t, contains("Do sprawdzenia:"));
      expect(t, contains("Sprawdź szczelność układu dolotowego"));
    });

    test("HTML jest poprawnie escapowany i zawiera markę Dynomic", () {
      final r = DiagnosisReport(
        session: _session(),
        anomalies: [_boostLeak()],
        generatedAt: DateTime(2026, 3, 14, 12, 0),
      );
      final h = r.toHtml();
      expect(h, contains("<!doctype html>"));
      expect(h, contains("Dynomic"));
      expect(h, contains("#E51C1C"));
      expect(h, contains("Spadek doładowania pod obciążeniem"));
      // brak surowych nawiasów z danych wejściowych w treści usterki
      expect(h, isNot(contains("<script")));
    });

    test("bez usterek daje pozytywny werdykt", () {
      final r = DiagnosisReport(session: _session(), anomalies: const []);
      final t = r.toPlainText();
      expect(t, contains("Nie wykryto usterek"));
      expect(r.hasIssues, isFalse);
      expect(r.hasCritical, isFalse);
    });

    test("escapuje znaki specjalne HTML", () {
      final session = LogSession(
        id: "s2",
        title: "x",
        createdAt: DateTime(2026, 1, 1),
        activePidKeys: const [],
        vehicleLabel: "Test <b>&</b>",
        points: [const LogPoint(timeMs: 0, values: {"RPM": 800})],
      );
      final h = DiagnosisReport(session: session, anomalies: const []).toHtml();
      expect(h, contains("Test &lt;b&gt;&amp;&lt;/b&gt;"));
    });
  });
}
