import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/log_point.dart';
import '../models/obd_pid.dart';
import 'analysis/evap_test.dart';
import 'analysis/signal_stats.dart';
import 'engine_memory.dart';
import 'obd_service.dart';

enum EvapStep { ready, before, clamp, settle, after, done, cancelled, error }

/// Przebieg prowadzonego testu EVAP: faza A (normalnie) → zaciśnięcie węża → stabilizacja
/// → faza B (zaciśnięty wąż) → werdykt. Fazy trwają co najmniej [phaseDuration] i aż
/// zbierze się [minSamples] odczytów — przy wolnym aucie (K-line) test sam się wydłuża.
class EvapTestRunner extends ChangeNotifier {
  final ObdService obd;
  final Duration phaseDuration;
  final Duration settleDuration;
  final int minSamples;

  EvapTestRunner({
    required this.obd,
    this.phaseDuration = const Duration(seconds: 30),
    this.settleDuration = const Duration(seconds: 10),
    this.minSamples = 12,
  });

  static const _keys = {"RPM", "STFT", "LTFT", "BOOST", "ECT", "SPEED", "EVAP_VP", "TPS", "PEDAL"};

  EvapStep step = EvapStep.ready;
  final List<LogPoint> points = [];
  double? liveRpm;
  double? liveTrim;
  double? ect;
  double progress = 0; // postęp bieżącej fazy 0..1
  int samplesInPhase = 0;
  String? error;
  EvapTestVerdict? verdict;
  DateTime? startedAt;

  final Stopwatch _clock = Stopwatch();
  bool _running = false;

  List<ObdPid> get _pids => obd.discoveredPids.where((p) => _keys.contains(p.shortName)).toList();
  bool get hasTrims => _pids.any((p) => p.shortName == "STFT" || p.shortName == "LTFT");
  bool get canRun => obd.status == ObdConnectionStatus.connected && _pids.any((p) => p.shortName == "RPM");
  bool get engineCold => ect != null && ect! < 70;

  /// Faza A: normalny bieg jałowy. Po zakończeniu czeka na zaciśnięcie węża.
  Future<void> start() async {
    if (!canRun) {
      _fail("Brak połączenia z autem albo sterownik nie podaje obrotów.");
      return;
    }
    points.clear();
    verdict = null;
    error = null;
    startedAt = DateTime.now();
    _running = true;
    _clock
      ..reset()
      ..start();
    step = EvapStep.before;
    notifyListeners();
    if (!await _phase(0, phaseDuration)) return;
    step = EvapStep.clamp;
    progress = 0;
    notifyListeners();
  }

  /// Użytkownik zacisnął wąż: stabilizacja, faza B i werdykt.
  Future<void> confirmClamped() async {
    if (step != EvapStep.clamp) return;
    step = EvapStep.settle;
    notifyListeners();
    if (!await _phase(null, settleDuration)) return; // odczyty tylko do podglądu
    step = EvapStep.after;
    notifyListeners();
    if (!await _phase(1, phaseDuration)) return;
    _running = false;
    _clock.stop();
    verdict = EvapTestVerdict.evaluate(points);
    step = EvapStep.done;
    notifyListeners();
  }

  void cancel() {
    _running = false;
    _clock.stop();
    step = EvapStep.cancelled;
    notifyListeners();
  }

  void _fail(String msg) {
    _running = false;
    _clock.stop();
    error = msg;
    step = EvapStep.error;
    notifyListeners();
  }

  /// Odpytuje auto przez [length] (i do [minSamples] odczytów, gdy [phase] != null).
  /// Zwraca false, gdy test przerwano albo zabrakło odczytów.
  Future<bool> _phase(int? phase, Duration length) async {
    final start = _clock.elapsedMilliseconds;
    samplesInPhase = 0;
    int failures = 0;
    while (_running) {
      final vals = await obd.readPids(_pids);
      if (!_running) return false;
      final rpm = vals["RPM"];
      if (rpm != null) {
        failures = 0;
        liveRpm = rpm;
        if (vals["ECT"] != null) ect = vals["ECT"];
        final p = LogPoint(timeMs: _clock.elapsedMilliseconds.toDouble(), values: {
          ...vals,
          if (phase != null) evapTestPhaseKey: phase.toDouble(),
        });
        liveTrim = SignalStats.totalTrim(p);
        if (phase != null) {
          points.add(p);
          samplesInPhase++;
        }
      } else if (++failures >= 15) {
        _fail("Auto przestało odpowiadać (brak odczytu obrotów). Sprawdź połączenie i powtórz test.");
        return false;
      }
      final elapsed = _clock.elapsedMilliseconds - start;
      progress = min(1.0, elapsed / length.inMilliseconds);
      notifyListeners();
      final enough = phase == null || samplesInPhase >= minSamples;
      if (elapsed >= length.inMilliseconds && enough) return true;
      if (elapsed >= length.inMilliseconds * 3) return true; // bardzo wolne auto — kończymy z tym, co jest
      await Future.delayed(const Duration(milliseconds: 20));
    }
    return false;
  }

  /// Log testu do historii (trafia do Diagnozy i raportu dla klienta).
  LogSession buildSession() {
    final info = obd.vehicleInfo;
    final t = startedAt ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return LogSession(
      id: "evap_${t.millisecondsSinceEpoch}",
      title: "Test EVAP ${two(t.hour)}:${two(t.minute)}",
      createdAt: t,
      activePidKeys: {for (final p in points) ...p.values.keys}.toList(),
      points: List.of(points),
      isDiesel: info?.isDiesel ?? false,
      vehicleLabel: info?.label,
      engineInfo: info == null ? "" : EngineMemory.engineHaystack(info),
      vin: info?.vin ?? "",
    );
  }

  @override
  void dispose() {
    _running = false;
    super.dispose();
  }
}
