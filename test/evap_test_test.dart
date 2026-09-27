import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:autocheck/screens/evap_test_screen.dart';
import 'package:autocheck/services/datalogger_service.dart';
import 'package:autocheck/models/anomaly.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/services/analysis/evap_test.dart';
import 'package:autocheck/services/anomaly_engine.dart';
import 'package:autocheck/services/evap_test_runner.dart';
import 'package:autocheck/services/obd_service.dart';

import 'support/mock_elm327.dart';

/// Faza testu: [n] odczytów co 1 s, falowanie o amplitudzie [amp], korekty [trim].
List<LogPoint> _phase(int phase, {int n = 30, double amp = 0, double? trim, double t0 = 0}) {
  final rnd = Random(phase + 1);
  return [
    for (int i = 0; i < n; i++)
      LogPoint(timeMs: t0 + i * 1000.0, values: {
        "RPM": 850 + sin(i * 2 * pi / 3) * amp + rnd.nextDouble() * 15,
        if (trim != null) "STFT": trim + rnd.nextDouble() - 0.5,
        evapTestPhaseKey: phase.toDouble(),
      }),
  ];
}

EvapTestVerdict _eval(List<LogPoint> a, List<LogPoint> b) => EvapTestVerdict.evaluate([...a, ...b]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("Werdykt testu EVAP", () {
    test("falowanie znika po zaciśnięciu węża → zawór do wymiany", () {
      final v = _eval(_phase(0, amp: 180), _phase(1, amp: 20, t0: 40000));
      expect(v.outcome, EvapOutcome.faulty);
      expect(v.rpmImproved, isTrue);
      expect(v.plainSummary, contains("przestał falować"));
    });

    test("korekty wracają z −15% ku zeru → zawór do wymiany (nawet bez falowania)", () {
      final v = _eval(_phase(0, trim: -15), _phase(1, trim: -3, t0: 40000));
      expect(v.outcome, EvapOutcome.faulty);
      expect(v.trimImproved, isTrue);
    });

    test("objawy zostają po odcięciu → zawór sprawny, przyczyna inna", () {
      final v = _eval(_phase(0, amp: 180, trim: -12), _phase(1, amp: 175, trim: -12, t0: 40000));
      expect(v.outcome, EvapOutcome.ok);
      expect(v.plainSummary, contains("to nie zawór"));
    });

    test("równa praca w obu fazach → brak objawów, test nierozstrzygnięty", () {
      expect(_eval(_phase(0, trim: 1), _phase(1, trim: 1, t0: 40000)).outcome, EvapOutcome.noSymptoms);
    });

    test("za mało odczytów → nie ocenia", () {
      expect(_eval(_phase(0, n: 3, amp: 200), _phase(1, n: 3, t0: 10000)).outcome, EvapOutcome.insufficient);
    });

    test("log testu w analizie daje tylko werdykt testu (bez sprzecznych reguł ogólnych)", () {
      final a = AnomalyEngine.analyzeSession([..._phase(0, amp: 180, trim: -14), ..._phase(1, amp: 20, trim: -2, t0: 40000)]);
      expect(a, hasLength(1));
      expect(a.single.id, startsWith("evap_test_faulty_"));
      expect(a.single.severity, AnomalySeverity.critical);
      expect(a.single.recommendations.join(" "), contains("Wymień elektrozawór EVAP"));
    });
  });

  test("pełny przebieg testu na emulatorze auta benzynowego", () async {
    final elm = await MockElm327.start(petrol: true);
    final obd = ObdService();
    addTearDown(() async {
      obd.disconnect();
      await elm.close();
    });
    expect(await obd.connectWifi(ip: "127.0.0.1", port: elm.port), isTrue);

    final runner = EvapTestRunner(
      obd: obd,
      phaseDuration: const Duration(milliseconds: 2500),
      settleDuration: const Duration(milliseconds: 300),
      minSamples: 8,
    );
    expect(runner.canRun, isTrue);

    // Faza A: silnik faluje (±170 obr/min co ~0,35 s), mieszanka bogata (STFT ≈ −18%)
    elm.stftRaw = 105;
    var up = false;
    final wobble = Timer.periodic(const Duration(milliseconds: 350), (_) {
      up = !up;
      elm.rpm = up ? 1020 : 680;
    });
    await runner.start();
    wobble.cancel();
    expect(runner.step, EvapStep.clamp);

    // Zaciśnięty wąż: równe obroty, korekta wraca do zera
    elm.rpm = 850;
    elm.stftRaw = 128;
    await runner.confirmClamped();

    expect(runner.step, EvapStep.done);
    expect(runner.verdict!.outcome, EvapOutcome.faulty);
    final s = runner.buildSession();
    expect(s.title, startsWith("Test EVAP"));
    expect(s.points.where((p) => p.values[evapTestPhaseKey] == 0).length, greaterThanOrEqualTo(8));
    expect(s.points.where((p) => p.values[evapTestPhaseKey] == 1).length, greaterThanOrEqualTo(8));
  });

  testWidgets("ekran testu EVAP: instrukcja i blokada startu bez połączenia", (tester) async {
    final obd = ObdService();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: obd),
        ChangeNotifierProvider.value(value: DataloggerService(obdService: obd, persistHistory: false)),
      ],
      child: const MaterialApp(home: EvapTestScreen()),
    ));
    expect(find.text("Test zaworu EVAP"), findsOneWidget);
    expect(find.textContaining("szczypce do węży"), findsOneWidget);
    expect(find.textContaining("Połącz się z autem"), findsOneWidget);
    expect(find.text("Rozpocznij test"), findsNothing);
  });
}
