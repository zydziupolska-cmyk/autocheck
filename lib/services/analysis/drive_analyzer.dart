import 'dart:math';
import '../../models/anomaly.dart';
import '../../models/log_point.dart';
import 'drive_state.dart';

/// Odcinek pełnego gazu (przyspieszenie) w logu.
class PullSegment {
  final int start; // indeks pierwszego punktu
  final int end; // indeks ostatniego punktu (włącznie)
  final double startRpm;
  final double peakRpm;
  final double durationMs;

  const PullSegment(this.start, this.end, this.startRpm, this.peakRpm, this.durationMs);
}

/// Statystyka jednego przedziału obrotów (np. 2000-2500 obr/min) pod pełnym gazem.
class RpmBin {
  final double lo;
  final double hi;
  final List<LogPoint> points = [];

  RpmBin(this.lo, this.hi);

  double? mean(String key) {
    final v = [for (final p in points) if (p.values.containsKey(key)) p.values[key]!];
    if (v.isEmpty) return null;
    return v.reduce((a, b) => a + b) / v.length;
  }

  String get label => "${lo.toInt()}-${hi.toInt()}";
}

/// Przyczyna brakującego doładowania z punktacją dowodów.
class _Cause {
  final String id;
  final String name;
  double score = 0;
  final List<String> evidenceFor = [];
  final List<String> evidenceAgainst = [];

  _Cause(this.id, this.name);

  void add(double points, String why) {
    score += points;
    (points >= 0 ? evidenceFor : evidenceAgainst).add(why);
  }
}

/// Analizator całej jazdy lub pojedynczego przyspieszenia.
///
/// Zamiast pojedynczych progów porównuje ze sobą czujniki w tych samych
/// warunkach (zakres obrotów, pełny gaz) i wskazuje najbardziej prawdopodobną
/// przyczynę — np. „turbo nie dmucha, bo zapchany DPF dławi przepływ spalin”.
class DriveAnalyzer {
  static const double _binWidth = 500;

  // ---------------------------------------------------------------------------
  // Segmentacja
  // ---------------------------------------------------------------------------

  /// Odcinki pełnego gazu z przyrostem obrotów (przyspieszenia).
  static List<PullSegment> findPulls(List<LogPoint> pts, {required bool isDiesel}) {
    final pulls = <PullSegment>[];
    int? start;
    int lastWot = -1;
    double peak = 0;

    void close() {
      if (start == null || lastWot < 0) return;
      final s = start!;
      final duration = pts[lastWot].timeMs - pts[s].timeMs;
      final startRpm = pts[s].values["RPM"] ?? 0;
      if (duration >= 1500 && peak - startRpm >= 800) {
        pulls.add(PullSegment(s, lastWot, startRpm, peak, duration));
      }
      start = null;
      lastWot = -1;
      peak = 0;
    }

    for (int i = 0; i < pts.length; i++) {
      final v = pts[i].values;
      final rpm = v["RPM"];
      final wot = rpm != null && DriveState.isFullThrottle(v, isDiesel: isDiesel);
      if (wot) {
        start ??= i;
        lastWot = i;
        if (rpm > peak) peak = rpm;
        // Spadek obrotów pod pełnym gazem = zmiana biegu → nowe przyspieszenie
        if (rpm < peak - 500) {
          close();
          start = i;
          lastWot = i;
          peak = rpm;
        }
      } else if (start != null && pts[i].timeMs - pts[lastWot].timeMs > 400) {
        close();
      }
    }
    close();
    return pulls;
  }

  /// Punkty przyspieszeń po fazie rozpędzania turbo (pierwsze 0,8 s pomijamy — turbo ma
  /// prawo „nie nadążać” tuż po wciśnięciu gazu).
  static List<LogPoint> _settledPullPoints(List<LogPoint> pts, List<PullSegment> pulls) {
    final out = <LogPoint>[];
    for (final pull in pulls) {
      final t0 = pts[pull.start].timeMs;
      for (int i = pull.start; i <= pull.end; i++) {
        if (pts[i].timeMs - t0 >= 800) out.add(pts[i]);
      }
    }
    return out;
  }

  static List<RpmBin> _bins(List<LogPoint> points) {
    final bins = <int, RpmBin>{};
    for (final p in points) {
      final rpm = p.values["RPM"];
      if (rpm == null) continue;
      final idx = (rpm / _binWidth).floor();
      bins.putIfAbsent(idx, () => RpmBin(idx * _binWidth, (idx + 1) * _binWidth)).points.add(p);
    }
    final list = bins.values.where((b) => b.points.length >= 2).toList()..sort((a, b) => a.lo.compareTo(b.lo));
    return list;
  }

  static double? _mean(Iterable<LogPoint> pts, String key) {
    final v = [for (final p in pts) if (p.values.containsKey(key)) p.values[key]!];
    if (v.isEmpty) return null;
    return v.reduce((a, b) => a + b) / v.length;
  }

  static bool _has(List<LogPoint> pts, String key) => pts.any((p) => p.values.containsKey(key));

  static String _f(double v, [int d = 2]) => v.toStringAsFixed(d);

  // ---------------------------------------------------------------------------
  // Analiza
  // ---------------------------------------------------------------------------

  static List<Anomaly> analyze(List<LogPoint> rawPoints, {required bool isDiesel}) {
    if (rawPoints.length < 5) return const [];
    final pts = DriveState.forwardFill(rawPoints);
    final pulls = findPulls(pts, isDiesel: isDiesel);
    final pullPts = _settledPullPoints(pts, pulls);

    final anomalies = <Anomaly>[];
    final boost = _diagnoseBoost(pts, pulls, pullPts, isDiesel: isDiesel);
    if (boost != null) anomalies.add(boost);
    final rail = _diagnoseRail(pts, pullPts, isDiesel: isDiesel);
    if (rail != null) anomalies.add(rail);
    final vgt = _diagnoseActuatorTracking(pts, "VGT_CMD", "VGT_ACT", "vgt_tracking",
        "Kierownice turbiny (VGT) nie nadążają za sterownikiem",
        "zmiennej geometrii turbiny (VGT)",
        boostAnomalyPresent: boost != null);
    if (vgt != null) anomalies.add(vgt);
    final wg = _diagnoseActuatorTracking(pts, "WG_CMD", "WG_ACT", "wg_tracking",
        "Zawór wastegate nie nadąża za sterownikiem", "zaworu upustowego turbiny (wastegate)",
        boostAnomalyPresent: boost != null);
    if (wg != null) anomalies.add(wg);
    final egr = _diagnoseEgrTracking(pts);
    if (egr != null) anomalies.add(egr);
    final dpf = _diagnoseDpfLoad(pts, pullPts, boostAnomalyPresent: boost?.id.startsWith("dpf_") == true);
    if (dpf != null) anomalies.add(dpf);
    final torque = _diagnoseTorqueLimit(pullPts, boostAnomalyPresent: boost != null);
    if (torque != null) anomalies.add(torque);
    return anomalies;
  }

  /// Uwagi o kompletności danych — czego log nie pozwolił ocenić.
  static List<String> coverageNotes(List<LogPoint> rawPoints, {required bool isDiesel}) {
    if (rawPoints.isEmpty) return const [];
    final pts = DriveState.forwardFill(rawPoints);
    final notes = <String>[];
    final pulls = findPulls(pts, isDiesel: isDiesel);
    if (pulls.isEmpty) {
      notes.add("W logu nie ma przyspieszenia na pełnym gazie — turbo, ciśnienie paliwa i moment pod obciążeniem nie zostały ocenione.");
    }
    if (!_has(pts, "TARGET_BOOST") && _has(pts, "BOOST")) {
      notes.add("Sterownik nie udostępnia zadanego doładowania — doładowanie oceniane względem typowych wartości (mniejsza pewność).");
    }
    if (!_has(pts, "PEDAL") && !_has(pts, "TPS")) {
      notes.add("Brak pozycji pedału/przepustnicy — pełny gaz wykrywany z obciążenia silnika.");
    }
    if (isDiesel && !_has(pts, "DPF_DP")) {
      notes.add("Brak odczytu różnicy ciśnień DPF — nie da się bezpośrednio ocenić zapchania filtra.");
    }
    return notes;
  }

  // ---------------------------------------------------------------------------
  // Doładowanie — diagnoza różnicowa
  // ---------------------------------------------------------------------------

  static Anomaly? _diagnoseBoost(List<LogPoint> pts, List<PullSegment> pulls, List<LogPoint> pullPts,
      {required bool isDiesel}) {
    if (pullPts.length < 5 || !_has(pullPts, "BOOST")) return null;
    final hasTarget = _has(pullPts, "TARGET_BOOST");
    final minRpm = isDiesel ? 1600.0 : 2000.0;
    final evalPts = pullPts.where((p) => (p.values["RPM"] ?? 0) >= minRpm && p.values.containsKey("BOOST")).toList();
    if (evalPts.length < 5) return null;

    final maxBoostSeen = pts.map((p) => p.values["BOOST"] ?? -9).reduce(max);
    final isTurbo = isDiesel || hasTarget && evalPts.any((p) => (p.values["TARGET_BOOST"] ?? 0) > 0.3) || maxBoostSeen > 0.3;
    if (!isTurbo) return null; // silnik wolnossący — nie oceniamy doładowania

    // Deficyt względem zadanego (lub typowych wartości, gdy ECU nie podaje zadanego)
    double expectedFor(LogPoint p) {
      if (hasTarget && p.values.containsKey("TARGET_BOOST")) return p.values["TARGET_BOOST"]!;
      final rpm = p.values["RPM"] ?? 0;
      if (isDiesel) return rpm >= 2000 && rpm <= 3500 ? 0.9 : 0.5;
      return 0.5;
    }

    final deficitPts = <LogPoint>[];
    final overPts = <LogPoint>[];
    for (final p in evalPts) {
      final actual = p.values["BOOST"]!;
      final expected = expectedFor(p);
      if (hasTarget && p.values.containsKey("TARGET_BOOST")) {
        if (expected > 0.3 && expected - actual > max(0.2, 0.15 * expected)) deficitPts.add(p);
        if (actual - expected > 0.25) overPts.add(p);
      } else if (actual < expected - 0.3) {
        deficitPts.add(p);
      }
    }

    // Tryb awaryjny: sterownik sam nie żąda doładowania
    if (hasTarget && isDiesel) {
      final midRange = evalPts.where((p) {
        final rpm = p.values["RPM"] ?? 0;
        return rpm >= 2000 && rpm <= 3500 && p.values.containsKey("TARGET_BOOST");
      }).toList();
      if (midRange.length >= 5) {
        final maxTarget = midRange.map((p) => p.values["TARGET_BOOST"]!).reduce(max);
        if (maxTarget < 0.45) return _limpMode(midRange, maxTarget);
      }
    }

    if (overPts.length >= 4) return _overboost(pts, overPts);
    if (deficitPts.length < 5) return null;

    // --- Opis objawu: w jakim zakresie obrotów i o ile brakuje ---
    final bins = _bins(evalPts);
    final badBins = bins.where((b) {
      final a = b.mean("BOOST");
      if (a == null) return false;
      final e = hasTarget
          ? b.mean("TARGET_BOOST")
          : b.points.map(expectedFor).reduce((x, y) => x + y) / b.points.length;
      if (e == null) return false;
      return e - a > (hasTarget ? max(0.2, 0.15 * e) : 0.3);
    }).toList();
    final rangeLo = badBins.isNotEmpty ? badBins.first.lo : deficitPts.map((p) => p.values["RPM"]!).reduce(min);
    final rangeHi = badBins.isNotEmpty ? badBins.last.hi : deficitPts.map((p) => p.values["RPM"]!).reduce(max);
    final actualAvg = _mean(deficitPts, "BOOST")!;
    final expectedAvg = deficitPts.map(expectedFor).reduce((a, b) => a + b) / deficitPts.length;
    final lossPct = expectedAvg > 0 ? ((expectedAvg - actualAvg) / expectedAvg * 100) : 0.0;

    // --- Dowody dla przyczyn ---
    final dpf = _Cause("dpf", "Zapchany filtr DPF / ograniczony przepływ spalin");
    final leak = _Cause("leak", "Nieszczelność układu dolotowego (za przepływomierzem)");
    final vgt = _Cause("vgt", isDiesel ? "Zacięta geometria turbiny (VGT) lub jej sterowanie" : "Wastegate / sterowanie turbiną");
    final egr = _Cause("egr", "Zawór EGR zawieszony w pozycji otwartej");
    final intake = _Cause("intake", "Ograniczony dolot powietrza (zapchany filtr powietrza / zgnieciony przewód przed turbiną)");
    final turbo = _Cause("turbo", "Zużyta turbosprężarka");

    final correlated = <String, String>{
      "BOOST": hasTarget
          ? "średnio ${_f(actualAvg)} bar zamiast zadanych ${_f(expectedAvg)} bar (−${lossPct.toStringAsFixed(0)}%)"
          : "średnio ${_f(actualAvg)} bar (typowo ≥ ${_f(expectedAvg)} bar)",
    };

    // DPF / przeciwciśnienie spalin
    final dp = _mean(deficitPts, "DPF_DP");
    final maf = _mean(deficitPts, "MAF");
    // Bezpośredni pomiar oporu DPF jest mocniejszym dowodem niż wnioskowanie z przepływu
    bool dpfMeasuredHigh = false;
    if (dp != null) {
      final dpPerFlow = maf != null && maf > 20 ? dp / maf : null;
      correlated["DPF_DP"] = "${_f(dp, 1)} kPa${dpPerFlow != null ? ' (${_f(dpPerFlow, 2)} kPa na każdy g/s powietrza)' : ''}";
      if (dp >= 25 || (dpPerFlow != null && dpPerFlow >= 0.25)) {
        dpfMeasuredHigh = true;
        dpf.add(5, "Bardzo duża różnica ciśnień na DPF (${_f(dp, 1)} kPa) — spaliny nie mają którędy uciec");
      } else if (dp >= 15 || (dpPerFlow != null && dpPerFlow >= 0.15)) {
        dpf.add(2, "Podwyższona różnica ciśnień na DPF (${_f(dp, 1)} kPa)");
      } else {
        dpf.add(-4, "Różnica ciśnień na DPF jest w normie (${_f(dp, 1)} kPa) — filtr jest drożny");
        leak.add(1, "DPF drożny — przyczyna leży po stronie dolotu lub sterowania turbiną");
      }
    }
    final exh = _mean(deficitPts, "EXH_P");
    final baro = _mean(pts, "BARO") ?? 101.3;
    if (exh != null) {
      final exhRel = exh - baro;
      correlated["EXH_P"] = "${_f(exhRel, 0)} kPa nadciśnienia w wydechu";
      if (exhRel >= 80 && actualAvg < expectedAvg) {
        dpf.add(2, "Wysokie ciśnienie w wydechu (${_f(exhRel, 0)} kPa) przy niskim doładowaniu — wydech jest dławiony");
      }
    }
    final egt = _mean(deficitPts, "EGT");
    if (egt != null) {
      correlated["EGT"] = "${_f(egt, 0)} °C";
      if (egt >= (isDiesel ? 650 : 900)) dpf.add(1, "Wysoka temperatura spalin (${_f(egt, 0)} °C) — spaliny zalegają w układzie wydechowym");
    }

    // Przepływ powietrza względem ciśnienia: k = MAF / (obroty × ciśnienie bezwzględne) to miara
    // napełnienia cylindrów. Porównujemy k w chwilach braku doładowania z k tego samego silnika
    // w chwilach, gdy doładowanie było prawidłowe. Spadek k = coś dławi przepływ (DPF, filtr
    // powietrza, EGR); wzrost k = powietrze jest zmierzone, ale ucieka z dolotu (nieszczelność).
    final flow = _airflowRatio(pts, deficitPts.toSet(), baro, hasTarget) ?? _airflowTrend(evalPts, baro);
    if (maf != null) correlated["MAF"] = "${_f(maf, 0)} g/s";
    if (flow != null) {
      final pct = ((flow - 1) * 100).abs().toStringAsFixed(0);
      if (flow <= 0.82) {
        final why = "Silnik zasysa o $pct% mniej powietrza, niż wynikałoby z obrotów i ciśnienia — przepływ jest dławiony";
        dpf.add(1.5, why);
        intake.add(1.5, why);
        leak.add(-1.5, "Przepływ powietrza jest niski, a przy nieszczelności przepływomierz mierzyłby dużo powietrza");
      } else if (flow >= 1.15 && !dpfMeasuredHigh) {
        leak.add(3, "Przepływomierz mierzy o $pct% więcej powietrza, niż pasuje do ciśnienia w dolocie — powietrze ucieka po drodze");
        dpf.add(-1, "Przepływ powietrza jest wysoki — wydech nie jest dławiony");
        intake.add(-1, "Przepływ powietrza jest wysoki — dolot nie jest zdławiony");
      } else {
        vgt.add(1, "Przepływ powietrza proporcjonalny do doładowania — turbo po prostu nie pompuje");
        turbo.add(0.5, "Przepływ proporcjonalny do doładowania");
        leak.add(-1, "Przepływ powietrza pasuje do ciśnienia — brak oznak ucieczki powietrza");
      }
    }

    // Geometria turbiny / wastegate
    for (final (cmdKey, actKey, label) in [("VGT_CMD", "VGT_ACT", "VGT"), ("WG_CMD", "WG_ACT", "wastegate")]) {
      final cmd = _mean(deficitPts, cmdKey);
      final act = _mean(deficitPts, actKey);
      if (cmd != null && act != null) {
        correlated[cmdKey] = "zadane ${_f(cmd, 0)}% / rzeczywiste ${_f(act, 0)}%";
        if ((cmd - act).abs() >= 15) {
          vgt.add(4, "Pozycja $label nie zgadza się z zadaną (zadane ${_f(cmd, 0)}%, rzeczywiste ${_f(act, 0)}%) — mechanizm się zacina");
        } else {
          vgt.add(-1.5, "Pozycja $label zgadza się z zadaną — mechanizm działa");
          if (cmd >= 80 || cmd <= 20) {
            leak.add(0.5, "Sterownik wysterowuje turbo na maksimum, a ciśnienia i tak brakuje");
            turbo.add(1, "Sterownik wysterowuje turbo na maksimum, a ciśnienia i tak brakuje");
          }
        }
      } else if (cmd != null) {
        correlated[cmdKey] = "zadane ${_f(cmd, 0)}%";
      }
    }

    // EGR pod pełnym gazem powinien być zamknięty
    final egrAct = _mean(deficitPts, "EGR_ACT");
    final egrCmd = _mean(deficitPts, "EGR_CMD");
    if (egrAct != null) {
      correlated["EGR_ACT"] = "${_f(egrAct, 0)}% otwarcia${egrCmd != null ? ' (zadane ${_f(egrCmd, 0)}%)' : ''}";
      if (egrAct >= 10 && (egrCmd == null || egrAct - egrCmd >= 8)) {
        egr.add(4, "EGR jest otwarty na ${_f(egrAct, 0)}% pod pełnym gazem${egrCmd != null ? ', choć sterownik żąda ${_f(egrCmd, 0)}%' : ''} — spaliny wypierają świeże powietrze");
      } else {
        egr.add(-3, "Zawór EGR zamknięty pod pełnym gazem — działa prawidłowo");
      }
    } else if (egrCmd != null && egrCmd >= 15) {
      egr.add(1, "Sterownik otwiera EGR pod pełnym gazem (${_f(egrCmd, 0)}%) — nietypowe");
    }

    // Moment: skutek braku powietrza (sterownik ogranicza dawkę)
    final tqD = _mean(deficitPts, "TQ_DEMAND");
    final tqA = _mean(deficitPts, "TQ_ACT");
    if (tqD != null && tqA != null) {
      correlated["TQ_ACT"] = "${_f(tqA, 0)}% momentu przy żądanych ${_f(tqD, 0)}%";
    }

    // Charakter spadku: nieszczelność pogłębia się z ciśnieniem/obrotami
    if (badBins.length >= 2) {
      double deficitOf(RpmBin b) => (hasTarget ? (b.mean("TARGET_BOOST") ?? 0) : 0.9) - (b.mean("BOOST") ?? 0);
      if (deficitOf(badBins.last) > deficitOf(badBins.first) + 0.15) {
        leak.add(1, "Brak ciśnienia narasta z obrotami — typowe dla nieszczelności");
      }
    }
    if (!(_has(deficitPts, "DPF_DP") || _has(deficitPts, "EXH_P")) && isDiesel) {
      dpf.add(0.5, "Diesel bez odczytu DPF — nie można wykluczyć zapchanego filtra");
    }
    turbo.add(0.5, "Możliwe zawsze, gdy inne przyczyny zostaną wykluczone");

    final causes = [dpf, leak, vgt, egr, intake, turbo]..sort((a, b) => b.score.compareTo(a.score));
    final top = causes.first;
    final confident = top.score >= 2.5 && top.score - causes[1].score >= 1;

    final rangeTxt = "${rangeLo.toInt()}–${rangeHi.toInt()} obr/min";
    final symptom = hasTarget
        ? "W zakresie $rangeTxt turbo dawało średnio ${_f(actualAvg)} bar zamiast zadanych ${_f(expectedAvg)} bar (brakuje ${lossPct.toStringAsFixed(0)}%)."
        : "W zakresie $rangeTxt turbo dawało tylko ${_f(actualAvg)} bar (dla sprawnego silnika typowo ≥ ${_f(expectedAvg)} bar).";

    final idPrefix = confident
        ? {"dpf": "dpf_underboost", "leak": "boost_leak_diag", "vgt": "vgt_underboost", "egr": "egr_underboost", "intake": "intake_restriction", "turbo": "turbo_worn"}[top.id]!
        : "underboost";

    final plain = confident
        ? "Turbo nie daje pełnego ciśnienia ($rangeTxt). Najbardziej prawdopodobna przyczyna: ${top.name.toLowerCase()}. ${_advice(top.id)}"
        : "Turbo nie daje pełnego ciśnienia ($rangeTxt). Dane nie wskazują jednoznacznie przyczyny — najbardziej prawdopodobne: ${causes.take(2).map((c) => c.name.toLowerCase()).join(' albo ')}.";

    return Anomaly(
      id: "${idPrefix}_${deficitPts.first.timeMs.toInt()}",
      title: confident ? "Brak doładowania — ${top.name}" : "Brak doładowania (niedoładowanie)",
      severity: lossPct >= 25 || !hasTarget ? AnomalySeverity.critical : AnomalySeverity.warning,
      paramKey: "BOOST",
      startMs: deficitPts.first.timeMs,
      endMs: deficitPts.last.timeMs,
      startRpm: rangeLo,
      endRpm: rangeHi,
      observedValueText: symptom,
      primarySymptom: symptom,
      correlatedSignals: correlated,
      plainSummary: plain,
      falseLeadWarning: top.id == "turbo"
          ? null
          : "Nie wymieniaj turbosprężarki w ciemno — kod P0299 (niedoładowanie) to tylko skutek. Dane wskazują, że sama turbina może być sprawna.",
      ruledOutCauses: [
        for (final c in causes)
          for (final e in c.evidenceAgainst) "${c.name}: $e",
      ],
      rootCauseConclusion: [
        "${top.name} (pewność: ${_confidence(top, causes)}).",
        ...top.evidenceFor.map((e) => "• $e"),
      ].join("\n"),
      description: "$symptom Aplikacja porównała doładowanie z przepływem powietrza, różnicą ciśnień na DPF, "
          "pozycją turbiny i zaworu EGR w tym samym zakresie obrotów, żeby odróżnić przyczynę od skutku.",
      hypotheses: [
        for (final c in causes.where((c) => c.score > 0)) "${c.name} — ${_confidence(c, causes)}",
      ],
      recommendations: _recommendations(top.id, isDiesel: isDiesel),
    );
  }

  static double? _k(LogPoint p, double baroKpa) {
    final maf = p.values["MAF"];
    final rpm = p.values["RPM"];
    final boost = p.values["BOOST"];
    if (maf == null || rpm == null || boost == null || rpm < 1000 || maf < 5) return null;
    final pAbs = boost * 100 + baroKpa;
    if (pAbs <= 20) return null;
    return maf / (rpm * pAbs);
  }

  /// Stosunek napełnienia w chwilach braku doładowania do napełnienia tego samego silnika,
  /// gdy doładowanie było prawidłowe (punkt odniesienia z tej samej jazdy).
  static double? _airflowRatio(List<LogPoint> pts, Set<LogPoint> deficit, double baroKpa, bool hasTarget) {
    final ref = <double>[];
    final bad = <double>[];
    for (final p in pts) {
      final k = _k(p, baroKpa);
      if (k == null) continue;
      if (deficit.contains(p)) {
        bad.add(k);
        continue;
      }
      if ((p.values["RPM"] ?? 0) < 1200) continue;
      final target = p.values["TARGET_BOOST"];
      if (hasTarget && target != null && target > 0.3 && (p.values["BOOST"]! - target).abs() > 0.1) continue;
      ref.add(k);
    }
    if (ref.length < 5 || bad.length < 5) return null;
    ref.sort();
    final refMedian = ref[ref.length ~/ 2];
    final badMean = bad.reduce((a, b) => a + b) / bad.length;
    return refMedian > 0 ? badMean / refMedian : null;
  }

  /// Zmiana „napełnienia” (MAF na jednostkę obrotów i ciśnienia) między niskimi a wysokimi obrotami przyspieszenia.
  static double? _airflowTrend(List<LogPoint> evalPts, double baroKpa) {
    final samples = <(double, double)>[]; // (rpm, k)
    for (final p in evalPts) {
      final maf = p.values["MAF"];
      final rpm = p.values["RPM"];
      final boost = p.values["BOOST"];
      if (maf == null || rpm == null || boost == null || rpm < 1000 || maf < 5) continue;
      final pAbs = boost * 100 + baroKpa;
      if (pAbs <= 20) continue;
      samples.add((rpm, maf / (rpm * pAbs)));
    }
    if (samples.length < 6) return null;
    samples.sort((a, b) => a.$1.compareTo(b.$1));
    final third = samples.length ~/ 3;
    final low = samples.take(third).map((s) => s.$2).reduce((a, b) => a + b) / third;
    final high = samples.skip(samples.length - third).map((s) => s.$2).reduce((a, b) => a + b) / third;
    if (samples.last.$1 - samples.first.$1 < 800 || low <= 0) return null;
    return high / low;
  }

  static String _confidence(_Cause c, List<_Cause> all) {
    final positive = all.where((x) => x.score > 0).fold<double>(0, (a, b) => a + b.score);
    if (positive <= 0 || c.score <= 0) return "mało prawdopodobne";
    final share = c.score / positive;
    if (share >= 0.6 && c.score >= 3) return "wysoka";
    if (share >= 0.35) return "średnia";
    return "niska";
  }

  static String _advice(String id) {
    switch (id) {
      case "dpf":
        return "Zacznij od sprawdzenia i regeneracji/czyszczenia DPF — nie od wymiany turbiny.";
      case "leak":
        return "Zrób test szczelności dolotu (dymem lub sprężonym powietrzem) — sprawdź węże i intercooler.";
      case "vgt":
        return "Sprawdź sterowanie turbiną (siłownik, wężyki podciśnienia, zawór N75) i drożność kierownic.";
      case "egr":
        return "Sprawdź zawór EGR — prawdopodobnie jest zanieczyszczony nagarem i nie domyka się.";
      case "intake":
        return "Sprawdź filtr powietrza i przewód dolotowy przed turbiną.";
      default:
        return "Zleć sprawdzenie luzów i stanu wirnika turbosprężarki.";
    }
  }

  static List<String> _recommendations(String id, {required bool isDiesel}) {
    switch (id) {
      case "dpf":
        return [
          "Odczytaj kody błędów (szukaj P2002, P2463, P244A/P244B).",
          "Sprawdź przewody czujnika różnicy ciśnień DPF (pęknięte/zatkane rurki dają fałszywe odczyty).",
          "Wykonaj regenerację serwisową lub czyszczenie filtra; po regeneracji powtórz pomiar.",
          "Jeśli filtr zapycha się szybko — sprawdź termostat, wtryskiwacze i zużycie oleju.",
        ];
      case "leak":
        return [
          "Test szczelności dolotu (dym / sprężone powietrze ok. 1,5 bar).",
          "Obejrzyj węże między turbiną a kolektorem, opaski i intercooler (ślady oleju = miejsce wycieku).",
          "Sprawdź zawór upustowy (DV / blow-off) w benzynie.",
        ];
      case "vgt":
        return [
          "Sprawdź siłownik turbiny (elektryczny lub podciśnieniowy) i jego ruch pełnym zakresem.",
          "Sprawdź wężyki podciśnienia i zawór sterujący (N75) — szczelność i wysterowanie.",
          "Zanieczyszczone nagarem kierownice VGT można wyczyścić bez wymiany turbiny.",
        ];
      case "egr":
        return [
          "Sprawdź zawór EGR (nagar, zacinanie), wykonaj test ruchu zaworu w diagnostyce producenta.",
          "Oczyść zawór i kanały EGR.",
        ];
      case "intake":
        return [
          "Wymień/sprawdź filtr powietrza.",
          "Sprawdź przewód między filtrem a turbiną (zgniecenie, zassanie).",
          if (isDiesel) "Jeśli filtr jest czysty — sprawdź DPF (jego zapchanie daje podobny obraz).",
        ];
      default:
        return [
          "Sprawdź luz osiowy i promieniowy wirnika turbiny oraz ślady oleju w dolocie.",
          "Przed wymianą turbiny wyklucz nieszczelność dolotu i zapchany DPF.",
        ];
    }
  }

  static Anomaly _limpMode(List<LogPoint> pts, double maxTarget) {
    return Anomaly(
      id: "limp_mode_${pts.first.timeMs.toInt()}",
      title: "Sterownik sam ogranicza doładowanie (tryb awaryjny)",
      severity: AnomalySeverity.critical,
      paramKey: "TARGET_BOOST",
      startMs: pts.first.timeMs,
      endMs: pts.last.timeMs,
      startRpm: 2000,
      endRpm: 3500,
      observedValueText: "Zadane doładowanie pod pełnym gazem to tylko ${_f(maxTarget)} bar",
      primarySymptom: "Pod pełnym gazem sterownik żąda tylko ${_f(maxTarget)} bar doładowania — turbo wykonuje polecenie, ale polecenie jest „awaryjne”.",
      plainSummary: "Silnik jest w trybie awaryjnym: komputer celowo nie pozwala turbo dmuchać. Turbo prawdopodobnie jest sprawne — trzeba odczytać kody błędów i usunąć ich przyczynę.",
      falseLeadWarning: "Nie wymieniaj turbiny — to sterownik ogranicza doładowanie, a nie turbo „nie daje rady”.",
      description: "Zadane doładowanie jest bardzo niskie w całym zakresie obrotów. Sterownik przechodzi w taki tryb po wykryciu usterki (np. czujnika ciśnienia, przepływomierza, DPF, przegrzania).",
      hypotheses: [
        "Tryb awaryjny po zapisaniu kodu błędu",
        "Ochrona silnika (przegrzanie, za wysoka temperatura spalin)",
        "Oprogramowanie ograniczające moc",
      ],
      recommendations: [
        "Odczytaj kody błędów w zakładce Połączenie i zacznij od nich.",
        "Po usunięciu usterki skasuj kody i powtórz pomiar przyspieszenia.",
      ],
    );
  }

  static Anomaly _overboost(List<LogPoint> pts, List<LogPoint> overPts) {
    final worst = overPts.reduce((a, b) =>
        (a.values["BOOST"]! - a.values["TARGET_BOOST"]!) > (b.values["BOOST"]! - b.values["TARGET_BOOST"]!) ? a : b);
    final diff = worst.values["BOOST"]! - worst.values["TARGET_BOOST"]!;
    final vgtCmd = _mean(overPts, "VGT_CMD");
    final vgtAct = _mean(overPts, "VGT_ACT");
    final stuck = vgtCmd != null && vgtAct != null && (vgtCmd - vgtAct).abs() >= 15;
    return Anomaly(
      id: "overboost_${worst.timeMs.toInt()}",
      title: "Przeładowanie turbo (overboost)",
      severity: AnomalySeverity.critical,
      paramKey: "BOOST",
      startMs: overPts.first.timeMs,
      endMs: overPts.last.timeMs,
      startRpm: overPts.map((p) => p.values["RPM"] ?? 0).reduce(min),
      endRpm: overPts.map((p) => p.values["RPM"] ?? 0).reduce(max),
      observedValueText: "Rzeczywiste ${_f(worst.values["BOOST"]!)} bar przy zadanych ${_f(worst.values["TARGET_BOOST"]!)} bar (+${_f(diff)} bar)",
      primarySymptom: "Turbo pompuje o ${_f(diff)} bar więcej, niż żąda sterownik.",
      correlatedSignals: {
        if (vgtCmd != null) "VGT_CMD": "zadane ${_f(vgtCmd, 0)}%${vgtAct != null ? ', rzeczywiste ${_f(vgtAct, 0)}%' : ''}",
      },
      plainSummary: "Turbo dmucha mocniej, niż powinno — zwykle przez zacinające się sterowanie turbiną. Nie jeździj na pełnym gazie do czasu naprawy (ryzyko uszkodzenia silnika i tryb awaryjny).",
      rootCauseConclusion: stuck
          ? "Geometria turbiny nie wykonuje poleceń sterownika (zadane ${_f(vgtCmd, 0)}%, rzeczywiste ${_f(vgtAct, 0)}%) — kierownice zacinają się w pozycji zamkniętej."
          : "Najczęściej zacinające się kierownice VGT (nagar) lub usterka sterowania turbiną.",
      description: "Rzeczywiste doładowanie przekracza zadane o ponad 0,25 bar. Sterownik zwykle reaguje trybem awaryjnym (kod P0234).",
      hypotheses: [
        "Zacięte kierownice VGT w pozycji zamkniętej (nagar)",
        "Uszkodzony zawór sterujący N75 / wężyki podciśnienia",
        "Wastegate nie otwiera się (benzyna)",
      ],
      recommendations: [
        "Nie jeździj na pełnym gazie do czasu naprawy.",
        "Sprawdź ruch siłownika turbiny i zawór sterujący.",
        "Czyszczenie kierownic VGT często rozwiązuje problem bez wymiany turbiny.",
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Ciśnienie paliwa: zadane vs rzeczywiste
  // ---------------------------------------------------------------------------

  static Anomaly? _diagnoseRail(List<LogPoint> pts, List<LogPoint> pullPts, {required bool isDiesel}) {
    final running = pts.where((p) => (p.values["RPM"] ?? 0) >= 600 && p.values.containsKey("F_RAIL") && p.values.containsKey("RAIL_TGT")).toList();
    if (running.length < 8) return null;
    final minAbs = isDiesel ? 80.0 : 8.0;

    bool low(LogPoint p) {
      final t = p.values["RAIL_TGT"]!;
      final a = p.values["F_RAIL"]!;
      return t - a > max(minAbs, 0.1 * t);
    }

    bool high(LogPoint p) {
      final t = p.values["RAIL_TGT"]!;
      final a = p.values["F_RAIL"]!;
      return a - t > max(minAbs, 0.1 * t);
    }

    final lowPts = running.where(low).toList();
    final highPts = running.where(high).toList();
    if (lowPts.length < 6 && highPts.length < 6) return null;

    final isLow = lowPts.length >= highPts.length;
    final bad = isLow ? lowPts : highPts;
    final t = _mean(bad, "RAIL_TGT")!;
    final a = _mean(bad, "F_RAIL")!;
    final underLoad = bad.where((p) => DriveState.isFullThrottle(p.values, isDiesel: isDiesel)).length;
    final atIdle = bad.where((p) => DriveState.isIdle(p.values, isDiesel: isDiesel)).length;
    final loadRelated = underLoad >= bad.length * 0.5;

    final String cause;
    final List<String> hyp;
    if (!isLow) {
      cause = "Regulator ciśnienia nie upuszcza paliwa (zawór regulacyjny / zawór dozujący)";
      hyp = ["Zacięty zawór regulacji ciśnienia na szynie lub pompie", "Uszkodzony czujnik ciśnienia na szynie"];
    } else if (loadRelated) {
      cause = "Za mała wydajność zasilania paliwem pod obciążeniem";
      hyp = [
        "Zapchany filtr paliwa (najczęstsza i najtańsza przyczyna)",
        "Słaba pompa wstępna (w baku) lub zapowietrzenie układu",
        "Zużyta pompa wysokiego ciśnienia",
      ];
    } else {
      cause = "Ubytek ciśnienia także przy małym obciążeniu (nieszczelność / przelewy)";
      hyp = [
        "Duże przelewy wtryskiwaczy (zużyty wtryskiwacz)",
        "Nieszczelny zawór regulacyjny ciśnienia",
        "Zużyta pompa wysokiego ciśnienia",
      ];
    }

    return Anomaly(
      id: "${isLow ? 'rail_deficit' : 'rail_over'}_${bad.first.timeMs.toInt()}",
      title: isLow ? "Ciśnienie paliwa niższe od zadanego" : "Ciśnienie paliwa wyższe od zadanego",
      severity: AnomalySeverity.critical,
      paramKey: "F_RAIL",
      startMs: bad.first.timeMs,
      endMs: bad.last.timeMs,
      startRpm: bad.map((p) => p.values["RPM"]!).reduce(min),
      endRpm: bad.map((p) => p.values["RPM"]!).reduce(max),
      observedValueText: "Średnio ${_f(a, 0)} bar przy zadanych ${_f(t, 0)} bar",
      primarySymptom: "Sterownik żąda ${_f(t, 0)} bar na szynie, a pompa daje ${_f(a, 0)} bar${loadRelated ? ' — głównie pod pełnym obciążeniem' : ''}.",
      correlatedSignals: {
        "RAIL_TGT": "${_f(t, 0)} bar zadane",
        "F_RAIL": "${_f(a, 0)} bar rzeczywiste",
        "Kiedy": loadRelated ? "pod pełnym gazem ($underLoad z ${bad.length} próbek)" : "także przy małym obciążeniu (jałowy: $atIdle próbek)",
      },
      plainSummary: isLow
          ? "Do silnika dociera za mało paliwa pod ciśnieniem${loadRelated ? ' przy mocnym przyspieszaniu' : ''}. ${loadRelated ? 'Zacznij od wymiany filtra paliwa — to najtańsza i najczęstsza przyczyna.' : 'Sprawdź przelewy wtryskiwaczy i zawór regulacyjny.'}"
          : "Ciśnienie paliwa jest wyższe niż powinno — regulator nie upuszcza paliwa.",
      rootCauseConclusion: cause,
      description: "Porównanie ciśnienia zadanego przez sterownik z rzeczywistym na szynie wtryskowej.",
      hypotheses: hyp,
      recommendations: isLow
          ? [
              if (loadRelated) "Wymień filtr paliwa i odpowietrz układ.",
              "Zmierz ciśnienie pompy wstępnej.",
              if (isDiesel) "Wykonaj test przelewów wtryskiwaczy.",
              "Powtórz pomiar przyspieszenia po naprawie.",
            ]
          : ["Sprawdź zawór regulacyjny ciśnienia i czujnik ciśnienia na szynie."],
    );
  }

  // ---------------------------------------------------------------------------
  // Siłowniki: zadane vs rzeczywiste (VGT, wastegate)
  // ---------------------------------------------------------------------------

  static Anomaly? _diagnoseActuatorTracking(List<LogPoint> pts, String cmdKey, String actKey, String id,
      String title, String what, {required bool boostAnomalyPresent}) {
    final both = pts.where((p) => p.values.containsKey(cmdKey) && p.values.containsKey(actKey) && (p.values["RPM"] ?? 0) > 600).toList();
    if (both.length < 20) return null;
    final errors = both.map((p) => (p.values[cmdKey]! - p.values[actKey]!).abs()).toList();
    final meanErr = errors.reduce((a, b) => a + b) / errors.length;
    final bigShare = errors.where((e) => e >= 15).length / errors.length;
    if (meanErr < 10 && bigShare < 0.2) return null;
    return Anomaly(
      id: "${id}_${both.first.timeMs.toInt()}",
      title: title,
      severity: boostAnomalyPresent ? AnomalySeverity.critical : AnomalySeverity.warning,
      paramKey: actKey,
      startMs: both.first.timeMs,
      endMs: both.last.timeMs,
      startRpm: 0,
      endRpm: 0,
      observedValueText: "Średnia odchyłka pozycji: ${_f(meanErr, 0)}% (duża odchyłka w ${(bigShare * 100).toStringAsFixed(0)}% czasu)",
      primarySymptom: "Rzeczywista pozycja $what odbiega od zadanej średnio o ${_f(meanErr, 0)}%.",
      plainSummary: "Mechanizm $what nie ustawia się tak, jak każe sterownik — najczęściej przez nagar lub usterkę siłownika. ${boostAnomalyPresent ? 'To prawdopodobnie przyczyna problemów z doładowaniem.' : 'Na razie bez wyraźnego spadku doładowania — warto zareagować zanim się pogorszy.'}",
      description: "Porównanie pozycji zadanej przez sterownik z rzeczywistą pozycją mechanizmu przez cały log.",
      hypotheses: ["Nagar na mechanizmie (zacinanie)", "Zużyty siłownik lub jego czujnik położenia", "Nieszczelne wężyki podciśnienia (siłownik podciśnieniowy)"],
      recommendations: ["Sprawdź ruch mechanizmu w pełnym zakresie (test siłownika w diagnostyce producenta).", "Oczyść mechanizm z nagaru przed ewentualną wymianą."],
    );
  }

  static Anomaly? _diagnoseEgrTracking(List<LogPoint> pts) {
    final both = pts.where((p) => p.values.containsKey("EGR_CMD") && p.values.containsKey("EGR_ACT") && (p.values["RPM"] ?? 0) > 600).toList();
    if (both.length >= 20) {
      final errors = both.map((p) => p.values["EGR_ACT"]! - p.values["EGR_CMD"]!).toList();
      final meanAbs = errors.map((e) => e.abs()).reduce((a, b) => a + b) / errors.length;
      if (meanAbs >= 12) {
        final meanSigned = errors.reduce((a, b) => a + b) / errors.length;
        final stuckOpen = meanSigned > 0;
        return Anomaly(
          id: "egr_tracking_${both.first.timeMs.toInt()}",
          title: stuckOpen ? "Zawór EGR nie domyka się" : "Zawór EGR nie otwiera się zgodnie z poleceniem",
          severity: AnomalySeverity.warning,
          paramKey: "EGR_ACT",
          startMs: both.first.timeMs,
          endMs: both.last.timeMs,
          startRpm: 0,
          endRpm: 0,
          observedValueText: "Średnia odchyłka EGR: ${_f(meanAbs, 0)}%",
          primarySymptom: "Rzeczywiste otwarcie EGR odbiega od zadanego średnio o ${_f(meanAbs, 0)}%.",
          plainSummary: stuckOpen
              ? "Zawór EGR jest bardziej otwarty, niż powinien — silnik dostaje za mało świeżego powietrza (dymienie, brak mocy). Zwykle wystarczy czyszczenie zaworu z nagaru."
              : "Zawór EGR otwiera się słabiej, niż żąda sterownik — zwykle przez nagar. Może to podnosić emisję NOx i temperaturę spalania.",
          description: "Porównanie otwarcia EGR zadanego z rzeczywistym przez cały log.",
          hypotheses: ["Nagar na zaworze EGR", "Usterka siłownika lub czujnika położenia EGR"],
          recommendations: ["Oczyść zawór i kanały EGR.", "Wykonaj test ruchu zaworu w diagnostyce producenta."],
        );
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // DPF: różnica ciśnień względem przepływu (cała jazda)
  // ---------------------------------------------------------------------------

  static Anomaly? _diagnoseDpfLoad(List<LogPoint> pts, List<LogPoint> pullPts, {required bool boostAnomalyPresent}) {
    if (boostAnomalyPresent) return null; // już opisane w diagnozie doładowania
    final samples = pts.where((p) => (p.values["MAF"] ?? 0) >= 20 && p.values.containsKey("DPF_DP")).toList();
    if (samples.length < 20) return null;
    // Nachylenie prostej przez zero: ΔP = s × MAF
    double sxy = 0, sxx = 0;
    for (final p in samples) {
      final x = p.values["MAF"]!;
      sxy += x * p.values["DPF_DP"]!;
      sxx += x * x;
    }
    final slope = sxy / sxx;
    final maxDp = samples.map((p) => p.values["DPF_DP"]!).reduce(max);
    if (slope < 0.2 && maxDp < 30) return null;
    final critical = slope >= 0.35 || maxDp >= 40;
    return Anomaly(
      id: "dpf_load_${samples.first.timeMs.toInt()}",
      title: critical ? "Filtr DPF mocno zapchany" : "Filtr DPF zapełniony powyżej normy",
      severity: critical ? AnomalySeverity.critical : AnomalySeverity.warning,
      paramKey: "DPF_DP",
      startMs: samples.first.timeMs,
      endMs: samples.last.timeMs,
      startRpm: 0,
      endRpm: 0,
      observedValueText: "Różnica ciśnień rośnie o ${_f(slope, 2)} kPa na każdy g/s przepływu (maks. ${_f(maxDp, 1)} kPa)",
      primarySymptom: "Przy danym przepływie spalin filtr stawia większy opór niż czysty filtr.",
      plainSummary: critical
          ? "Filtr cząstek stałych (DPF) jest mocno zapchany. Wkrótce silnik straci moc i przejdzie w tryb awaryjny — potrzebna regeneracja serwisowa lub czyszczenie filtra."
          : "Filtr cząstek stałych (DPF) jest zapełniony bardziej niż zwykle. Przejedź 20-30 min trasą (stałe obroty powyżej 2000/min), żeby auto mogło go wypalić.",
      description: "Analiza różnicy ciśnień na DPF w funkcji przepływu powietrza z całej jazdy (progi orientacyjne dla typowych filtrów osobowych).",
      hypotheses: ["Filtr zapełniony sadzą (brak regeneracji — krótkie trasy)", "Popiół olejowy (duży przebieg filtra)", "Uszkodzone przewody czujnika różnicy ciśnień"],
      recommendations: [
        "Jazda trasą umożliwiająca regenerację lub regeneracja serwisowa.",
        "Sprawdź termostat (niedogrzany silnik blokuje regenerację).",
        "Jeśli po regeneracji wynik się nie poprawia — czyszczenie/wymiana filtra.",
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Moment obrotowy: żądany vs rzeczywisty
  // ---------------------------------------------------------------------------

  static Anomaly? _diagnoseTorqueLimit(List<LogPoint> pullPts, {required bool boostAnomalyPresent}) {
    final both = pullPts.where((p) => p.values.containsKey("TQ_DEMAND") && p.values.containsKey("TQ_ACT")).toList();
    if (both.length < 6) return null;
    final limited = both.where((p) => p.values["TQ_DEMAND"]! - p.values["TQ_ACT"]! >= 15).toList();
    if (limited.length < both.length * 0.4 || boostAnomalyPresent) return null;
    final d = _mean(limited, "TQ_DEMAND")!;
    final a = _mean(limited, "TQ_ACT")!;
    return Anomaly(
      id: "torque_limit_${limited.first.timeMs.toInt()}",
      title: "Sterownik ogranicza moment obrotowy",
      severity: AnomalySeverity.warning,
      paramKey: "TQ_ACT",
      startMs: limited.first.timeMs,
      endMs: limited.last.timeMs,
      startRpm: 0,
      endRpm: 0,
      observedValueText: "Moment ${_f(a, 0)}% przy żądanych ${_f(d, 0)}%",
      primarySymptom: "Pod pełnym gazem silnik oddaje ${_f(a, 0)}% momentu, choć kierowca żąda ${_f(d, 0)}%.",
      plainSummary: "Komputer silnika celowo ogranicza moc, choć turbo działa poprawnie. Przyczyną bywa ochrona silnika (temperatura), tryb awaryjny lub ograniczenie dymienia — sprawdź kody błędów.",
      description: "Porównanie momentu żądanego z rzeczywistym podczas przyspieszeń.",
      hypotheses: ["Tryb awaryjny / zapisany kod błędu", "Ochrona termiczna silnika lub skrzyni", "Ogranicznik dymienia (za mało powietrza względem dawki)"],
      recommendations: ["Odczytaj kody błędów.", "Sprawdź temperatury silnika, oleju i skrzyni w logu."],
    );
  }
}
