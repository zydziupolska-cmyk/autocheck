import 'dart:math';
import '../../models/anomaly.dart';
import '../../models/dtc_code.dart';
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

  static List<Anomaly> analyze(List<LogPoint> rawPoints, {required bool isDiesel, List<String> dtcCodes = const []}) {
    if (rawPoints.length < 5) return const [];
    final dtcs = dtcCodes.map((c) => c.toUpperCase().trim()).toSet();
    final pts = DriveState.forwardFill(rawPoints);
    final pulls = findPulls(pts, isDiesel: isDiesel);
    final pullPts = _settledPullPoints(pts, pulls);

    final anomalies = <Anomaly>[];
    final boost = _diagnoseBoost(pts, pulls, pullPts, isDiesel: isDiesel, dtcs: dtcs);
    if (boost != null) anomalies.add(boost);
    final rail = _diagnoseFuelPressure(pts, isDiesel: isDiesel, dtcs: dtcs);
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
    anomalies.addAll(_unconfirmedDtcs(pts, dtcs, anomalies));
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
      {required bool isDiesel, Set<String> dtcs = const {}}) {
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

    // Zapieczona geometria turbiny bez czujnika jej pozycji: na niskich obrotach turbo
    // przeładowuje (kierownice zamknięte), a na wysokich nie nadąża (nie mogą się otworzyć/ustawić)
    final lowOver = overPts.where((p) => (p.values["RPM"] ?? 0) < 2500).length;
    final highDeficit = deficitPts.where((p) => (p.values["RPM"] ?? 0) >= 2500).length;
    final stickyPattern = lowOver >= 3 && highDeficit >= 5;
    if (!stickyPattern && overPts.length >= 4) return _overboost(pts, overPts);

    // Sterownik sam zapisał niedoładowanie (P0299), choć nie udostępnia zadanego ciśnienia —
    // oceniamy wtedy cały zakres pełnego gazu
    final ecuUnderboost = dtcs.contains("P0299");
    if (deficitPts.length < 5 && ecuUnderboost && !hasTarget) {
      deficitPts
        ..clear()
        ..addAll(evalPts.where((p) => (p.values["RPM"] ?? 0) >= 2000));
    }
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

    if (stickyPattern) {
      vgt.add(4, "Na niskich obrotach turbo przeładowuje ($lowOver próbek powyżej zadanego), a na wysokich nie nadąża — typowy objaw zapieczonych (zanieczyszczonych nagarem) kierownic turbiny");
      leak.add(-1, "Przeładowanie na niskich obrotach wyklucza nieszczelność jako główną przyczynę");
      correlated["Wzorzec"] = "przeładowanie poniżej 2500 obr/min, niedoładowanie powyżej";
    }

    // Kody błędów ze sterownika jako dodatkowe dowody
    if (ecuUnderboost) correlated["DTC"] = "P0299 — sterownik sam potwierdził niedoładowanie";
    if (dtcs.contains("P2002") || dtcs.contains("P2463") || dtcs.contains("P244A") || dtcs.contains("P244B")) {
      dpf.add(2, "Sterownik zapisał kod dotyczący DPF (${dtcs.where((c) => ["P2002", "P2463", "P244A", "P244B"].contains(c)).join(', ')})");
    }
    if (dtcs.any((c) => ["P2562", "P2563", "P0045", "P0046", "P0047", "P0048", "P0049", "P2261"].contains(c))) {
      vgt.add(2, "Sterownik zapisał kod sterowania turbiną (${dtcs.where((c) => ["P2562", "P2563", "P0045", "P0046", "P0047", "P0048", "P0049", "P2261"].contains(c)).join(', ')})");
    }
    if (dtcs.any((c) => ["P0400", "P0401", "P0402", "P0403", "P0404", "P0405", "P0406", "P0409"].contains(c))) {
      egr.add(1.5, "Sterownik zapisał kod układu EGR (${dtcs.where((c) => c.startsWith("P040")).join(', ')})");
    }
    if (dtcs.any((c) => ["P0101", "P0102", "P0103"].contains(c))) {
      correlated["Uwaga"] = "kod przepływomierza (${dtcs.where((c) => c.startsWith("P010")).join(', ')}) — odczyty MAF mogą być niewiarygodne";
    }

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
  // Ciśnienie paliwa — wzorzec: jałowy vs obciążenie, korekty paliwa, cylinder
  // ---------------------------------------------------------------------------

  /// Który cylinder wypada z zapłonu — tylko z danych: przyrost liczników Mode 06
  /// (lub wyraźnie najwyższy licznik) albo kod P030x. Zwraca (cylinder, źródło).
  static (int, String)? _misfireCylinder(List<LogPoint> pts, Set<String> dtcs) {
    final score = <int, double>{};
    for (int cyl = 1; cyl <= 8; cyl++) {
      final v = [for (final p in pts) if (p.values.containsKey("MIS_$cyl")) p.values["MIS_$cyl"]!];
      if (v.isEmpty) continue;
      final increase = v.last - v.first;
      score[cyl] = increase > 0 ? increase : v.reduce(max);
    }
    if (score.isNotEmpty) {
      final sorted = score.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      final best = sorted.first;
      final second = sorted.length > 1 ? sorted[1].value : 0.0;
      if (best.value >= 3 && best.value >= 2 * second) {
        return (best.key, "licznik wypadania zapłonów cylindra ${best.key}: ${best.value.toStringAsFixed(0)} (Mode 06)");
      }
    }
    final cylCodes = dtcs.where((c) => RegExp(r'^P030[1-8]$').hasMatch(c)).toList();
    if (cylCodes.length == 1) {
      final cyl = int.parse(cylCodes.single.substring(4));
      return (cyl, "kod błędu ${cylCodes.single} (wypadanie zapłonu cylindra $cyl)");
    }
    return null;
  }

  static Anomaly? _diagnoseFuelPressure(List<LogPoint> pts, {required bool isDiesel, Set<String> dtcs = const {}}) {
    final running = pts.where((p) => (p.values["RPM"] ?? 0) >= 500 && p.values.containsKey("F_RAIL")).toList();
    if (running.length < 8) return null;
    final hasTarget = running.any((p) => p.values.containsKey("RAIL_TGT"));
    final maxRail = running.map((p) => p.values["F_RAIL"]!).reduce(max);
    // Wtrysk pośredni (ok. 3-5 bar) — progi dla wtrysku bezpośredniego nie mają zastosowania
    if (!isDiesel && !hasTarget && maxRail < 15) return null;

    bool isIdle(LogPoint p) => DriveState.isIdle(p.values, isDiesel: isDiesel);
    bool isLoad(LogPoint p) =>
        DriveState.isFullThrottle(p.values, isDiesel: isDiesel) || (p.values["LOAD"] ?? 0) >= 70;

    bool isLow(LogPoint p) {
      final a = p.values["F_RAIL"]!;
      final t = p.values["RAIL_TGT"];
      if (t != null) return t - a > max(isDiesel ? 80.0 : 8.0, 0.1 * t);
      // Bez wartości zadanej: orientacyjne minimum dla wtrysku bezpośredniego
      if (isIdle(p)) return isDiesel ? a < 180 : a < 25;
      if (isLoad(p) && (p.values["RPM"] ?? 0) >= 2000) return isDiesel ? a < 700 : a < 50;
      return false;
    }

    bool isHigh(LogPoint p) {
      final t = p.values["RAIL_TGT"];
      if (t == null) return false;
      return p.values["F_RAIL"]! - t > max(isDiesel ? 80.0 : 8.0, 0.1 * t);
    }

    final idle = running.where(isIdle).toList();
    final load = running.where(isLoad).toList();
    double frac(List<LogPoint> l, bool Function(LogPoint) f) => l.isEmpty ? 0 : l.where(f).length / l.length;
    final idleLow = idle.length >= 5 && frac(idle, isLow) >= 0.5;
    final loadLow = load.length >= 3 && frac(load, isLow) >= 0.5;
    final loadOk = load.length >= 3 && frac(load, isLow) < 0.3;
    final highPts = running.where(isHigh).toList();
    final ecuConfirms = dtcs.contains("P0087") || dtcs.contains("P0093") || dtcs.contains("P2293");

    String pattern;
    if (idleLow && !loadLow) {
      pattern = "idle";
    } else if (loadLow) {
      pattern = "load";
    } else if (highPts.length >= 6) {
      pattern = "over";
    } else if (ecuConfirms && frac(running, isLow) >= 0.15) {
      pattern = "intermittent";
    } else {
      return null;
    }

    final bad = pattern == "over"
        ? highPts
        : running.where(isLow).toList();
    if (bad.isEmpty) return null;
    final idleMean = _mean(idle, "F_RAIL");
    final idleTarget = _mean(idle, "RAIL_TGT");
    final loadMean = _mean(load.where((p) => (p.values["RPM"] ?? 0) >= 2000), "F_RAIL");
    final loadTarget = _mean(load.where((p) => (p.values["RPM"] ?? 0) >= 2000), "RAIL_TGT");

    // Korekty paliwa na jałowym: ujemne = do cylindrów dostaje się paliwo poza kontrolą sterownika
    final stft = _mean(idle, "STFT");
    final ltft = _mean(idle, "LTFT");
    final trim = (stft ?? 0) + (ltft ?? 0);
    final hasTrim = stft != null || ltft != null;
    final cylinder = _misfireCylinder(pts, dtcs);
    final idleRpm = [for (final p in idle) p.values["RPM"]!];
    double rpmStd = 0;
    if (idleRpm.length >= 5) {
      final m = idleRpm.reduce((a, b) => a + b) / idleRpm.length;
      rpmStd = sqrt(idleRpm.map((r) => (r - m) * (r - m)).reduce((a, b) => a + b) / idleRpm.length);
    }

    final correlated = <String, String>{
      if (idleMean != null) "Jałowy": "${_f(idleMean, 0)} bar${idleTarget != null ? ' (zadane ${_f(idleTarget, 0)} bar)' : ''}",
      if (loadMean != null) "Obciążenie": "${_f(loadMean, 0)} bar${loadTarget != null ? ' (zadane ${_f(loadTarget, 0)} bar)' : ''}",
      if (hasTrim) "Korekty na jałowym": "${trim >= 0 ? '+' : ''}${_f(trim, 1)}% (${trim <= -8 ? 'mieszanka za bogata' : trim >= 8 ? 'mieszanka za uboga' : 'w normie'})",
      if (cylinder != null) "Cylinder": cylinder.$2,
      if (rpmStd >= 25) "Bieg jałowy": "nierówny (wahania ±${_f(rpmStd, 0)} obr/min)",
      if (dtcs.isNotEmpty) "Kody": dtcs.where((c) => c.startsWith("P0") || c.startsWith("P2")).join(", "),
    };

    final causes = <_Cause>[];
    final cylTxt = cylinder != null ? " cylindra ${cylinder.$1}" : "";
    if (pattern == "idle" || pattern == "intermittent") {
      if (!isDiesel) {
        final injector = _Cause("injector", "Lejący wtryskiwacz$cylTxt")..add(2, "Ciśnienie spada, gdy pompa podaje mało paliwa (jałowy), a pod obciążeniem jest w normie — paliwo ucieka z szyny");
        final regulator = _Cause("regulator", "Nieszczelny zawór regulacji ciśnienia na pompie wysokiego ciśnienia")..add(1.5, "Spadek ciśnienia przy małym wydatku pasuje też do wewnętrznego przecieku zaworu regulacyjnego");
        final pump = _Cause("pump", "Zużyta pompa wysokiego ciśnienia / popychacz na wałku rozrządu")..add(0.5, "Możliwe, choć zużycie pompy zwykle bardziej widać pod obciążeniem");
        final sensor = _Cause("sensor", "Błędny odczyt czujnika ciśnienia paliwa");
        if (hasTrim && trim <= -8) {
          injector.add(3, "Sterownik ujmuje paliwa (korekty ${_f(trim, 1)}%) — do cylindrów dostaje się paliwo, którego nie wtrysnął");
          regulator.add(-1, "Przeciek w pompie nie wzbogacałby mieszanki — a mieszanka jest za bogata");
        } else if (hasTrim && trim >= 8) {
          injector.add(-2, "Mieszanka jest za uboga (korekty +${_f(trim, 1)}%) — lejący wtrysk wzbogacałby ją");
          regulator.add(1, "Za uboga mieszanka przy niskim ciśnieniu pasuje do problemu z podawaniem paliwa");
          pump.add(1, "Za uboga mieszanka przy niskim ciśnieniu pasuje do słabego podawania paliwa");
        }
        if (cylinder != null) injector.add(2, "Wypada zapłon jednego cylindra (${cylinder.$2}) — zalewany cylinder nie odpala");
        if (dtcs.contains("P0172") || dtcs.contains("P0175")) injector.add(1, "Sterownik zapisał kod „mieszanka za bogata”");
        if (dtcs.contains("P0171") || dtcs.contains("P0174")) regulator.add(1, "Sterownik zapisał kod „mieszanka za uboga”");
        if (rpmStd >= 25) injector.add(0.5, "Nierówny bieg jałowy");
        if (dtcs.any((c) => ["P0190", "P0191", "P0192", "P0193"].contains(c))) sensor.add(3.5, "Sterownik zapisał kod czujnika ciśnienia paliwa");
        if (loadOk) pump.add(-0.5, "Pod obciążeniem pompa utrzymuje ciśnienie");
        causes.addAll([injector, regulator, pump, sensor]);
      } else {
        final leakoff = _Cause("leakoff", "Za duże przelewy wtryskiwaczy (zużyty wtryskiwacz$cylTxt)")..add(2.5, "Ciśnienie spada przy małym wydatku pompy — paliwo ucieka przelewami");
        final regulator = _Cause("regulator", "Nieszczelny zawór regulacji ciśnienia na szynie / pompie")..add(1.5, "Przeciek zaworu regulacyjnego daje ten sam objaw");
        final supply = _Cause("supply", "Zapowietrzenie lub słabe zasilanie wstępne (filtr, pompa w baku)")..add(1, "Możliwe przy małych obrotach pompy");
        if (dtcs.contains("P0093")) leakoff.add(2, "Sterownik zapisał kod P0093 (wykryto wyciek paliwa)");
        if (cylinder != null) leakoff.add(1, "Problem z jednym cylindrem (${cylinder.$2})");
        causes.addAll([leakoff, regulator, supply]);
      }
    } else if (pattern == "load") {
      final filter = _Cause("filter", "Zapchany filtr paliwa / słaba pompa wstępna (w baku)")..add(2.5, "Ciśnienie spada, gdy silnik potrzebuje najwięcej paliwa — brakuje dopływu do pompy wysokiego ciśnienia");
      final hpPump = _Cause("pump", "Zużyta pompa wysokiego ciśnienia${isDiesel ? '' : ' / popychacz na wałku rozrządu'}")..add(1.5, "Pompa może nie nadążać przy dużym wydatku");
      if (!isDiesel && hasTrim && trim >= 8) filter.add(1, "Mieszanka za uboga — brakuje paliwa");
      if (idle.length >= 5 && frac(idle, isLow) < 0.3) hpPump.add(0.5, "Na jałowym ciśnienie w normie — przy małym wydatku pompa daje radę");
      causes.addAll([filter, hpPump]);
    } else {
      causes.add(_Cause("over", "Zawór regulacji ciśnienia nie upuszcza paliwa")..add(3, "Ciśnienie wyższe od zadanego"));
      causes.add(_Cause("sensor", "Błędny odczyt czujnika ciśnienia paliwa")..add(1.5, "Możliwe przy braku innych objawów"));
    }

    causes.sort((a, b) => b.score.compareTo(a.score));
    final top = causes.first;
    final confident = top.score >= 3 && (causes.length < 2 || top.score - causes[1].score >= 1);

    final String symptom;
    switch (pattern) {
      case "idle":
        symptom = "Ciśnienie paliwa spada na wolnych obrotach (średnio ${_f(idleMean ?? 0, 0)} bar${idleTarget != null ? ' zamiast zadanych ${_f(idleTarget, 0)} bar' : isDiesel ? ', typowo ok. 250-350 bar' : ', typowo ok. 35-50 bar'})${loadOk ? ', a pod obciążeniem jest w normie' : ''}.";
      case "load":
        symptom = "Ciśnienie paliwa jest za niskie pod obciążeniem (średnio ${_f(loadMean ?? _mean(bad, "F_RAIL")!, 0)} bar${loadTarget != null ? ' zamiast zadanych ${_f(loadTarget, 0)} bar' : ''}).";
      case "over":
        symptom = "Ciśnienie paliwa jest wyższe od zadanego (średnio ${_f(_mean(bad, "F_RAIL")!, 0)} bar przy zadanych ${_f(_mean(bad, "RAIL_TGT")!, 0)} bar).";
      default:
        symptom = "Ciśnienie paliwa okresowo spada poniżej normy (${bad.length} z ${running.length} próbek), a sterownik zapisał kod ciśnienia paliwa.";
    }

    final extra = <String>[];
    if (!isDiesel && hasTrim && trim <= -8) extra.add("Sterownik ujmuje paliwa (korekty ${_f(trim, 1)}%), bo mieszanka jest za bogata.");
    if (cylinder != null) extra.add("Wypada zapłon cylindra ${cylinder.$1}.");
    final String plain;
    if (top.id == "injector" && confident) {
      plain = "$symptom ${extra.join(' ')} To typowy obraz lejącego wtryskiwacza${cylTxt.isEmpty ? '' : cylTxt}: paliwo przecieka z szyny prosto do cylindra. "
          "${cylinder == null ? 'Którego cylindra — z tych danych nie wynika; sprawdź korekty poszczególnych cylindrów w diagnostyce producenta albo świece. ' : ''}"
          "Nie wymieniaj pompy wysokiego ciśnienia w ciemno — najpierw sprawdź wtryskiwacz.";
    } else if (confident) {
      plain = "$symptom ${extra.join(' ')} Najbardziej prawdopodobna przyczyna: ${top.name.toLowerCase()}.";
    } else {
      plain = "$symptom ${extra.join(' ')} Możliwe przyczyny: ${causes.where((c) => c.score > 0).take(3).map((c) => c.name.toLowerCase()).join('; ')}.";
    }

    final id = switch (pattern) {
      "idle" => "rail_low_idle_${cylinder != null ? 'cyl${cylinder.$1}_' : ''}${bad.first.timeMs.toInt()}",
      "load" => "rail_low_load_${bad.first.timeMs.toInt()}",
      "over" => "rail_over_${bad.first.timeMs.toInt()}",
      _ => "rail_low_${bad.first.timeMs.toInt()}",
    };

    return Anomaly(
      id: id,
      title: pattern == "over"
          ? "Ciśnienie paliwa wyższe od zadanego"
          : confident
              ? "Za niskie ciśnienie paliwa — ${top.name}"
              : "Za niskie ciśnienie paliwa",
      severity: AnomalySeverity.critical,
      paramKey: "F_RAIL",
      startMs: bad.first.timeMs,
      endMs: bad.last.timeMs,
      startRpm: bad.map((p) => p.values["RPM"]!).reduce(min),
      endRpm: bad.map((p) => p.values["RPM"]!).reduce(max),
      observedValueText: symptom,
      primarySymptom: symptom,
      correlatedSignals: correlated,
      plainSummary: plain,
      falseLeadWarning: pattern == "idle"
          ? "Kod P0087 często kończy się wymianą pompy wysokiego ciśnienia. Gdy ciśnienie spada tylko na jałowym, a pod obciążeniem jest dobre, pompa zwykle jest sprawna — paliwo ucieka inną drogą."
          : null,
      ruledOutCauses: [
        for (final c in causes)
          for (final e in c.evidenceAgainst) "${c.name}: $e",
      ],
      rootCauseConclusion: [
        "${top.name} (pewność: ${_confidence(top, causes)}).",
        ...top.evidenceFor.map((e) => "• $e"),
      ].join("\n"),
      description: "$symptom Aplikacja porównała ciśnienie na wolnych obrotach i pod obciążeniem, korekty paliwa, "
          "liczniki wypadania zapłonów poszczególnych cylindrów i zapisane kody błędów.",
      hypotheses: [
        for (final c in causes.where((c) => c.score > 0)) "${c.name} — ${_confidence(c, causes)}",
      ],
      recommendations: _fuelRecommendations(top.id, cylinder?.$1, isDiesel: isDiesel),
    );
  }

  static List<String> _fuelRecommendations(String id, int? cyl, {required bool isDiesel}) {
    final c = cyl != null ? " $cyl" : "";
    switch (id) {
      case "injector":
        return [
          "Wykręć świecę cylindra${cyl != null ? ' $cyl' : ' podejrzanego cylindra'} po postoju: mokra, czarna i pachnąca benzyną = lejący wtryskiwacz.",
          "W diagnostyce producenta (np. VCDS/ODIS) porównaj korekty poszczególnych cylindrów — cylinder z lejącym wtryskiem ma wyraźnie inną korektę.",
          "Próba szczelności: po zgaszeniu ciepłego silnika ciśnienie na szynie nie powinno szybko spadać do zera.",
          "Sprawdź olej — jeśli pachnie benzyną lub przybywa go, wymień olej po naprawie (paliwo rozcieńcza film olejowy).",
          "Wymień wtryskiwacz$c (z nowymi uszczelkami/pierścieniem teflonowym); pompy nie ruszaj, jeśli pod obciążeniem ciśnienie jest dobre.",
        ];
      case "leakoff":
        return [
          "Wykonaj test przelewów wtryskiwaczy (porównanie ilości paliwa z przelewów każdego wtryskiwacza).",
          "Sprawdź zawór regulacji ciśnienia i szczelność przewodów wysokiego ciśnienia.",
        ];
      case "regulator":
        return [
          "Sprawdź zawór regulacji ciśnienia (${isDiesel ? 'na szynie/pompie' : 'N276 lub odpowiednik na pompie'}) — test w diagnostyce producenta.",
          "Wyklucz lejący wtryskiwacz: świece, korekty poszczególnych cylindrów.",
        ];
      case "filter":
        return [
          "Wymień filtr paliwa (najtańsza i najczęstsza przyczyna).",
          "Zmierz ciśnienie pompy wstępnej w baku.",
          if (isDiesel) "Sprawdź, czy układ nie zasysa powietrza (przezroczysty przewód przed filtrem).",
          "Jeśli po wymianie filtra problem zostaje — sprawdź pompę wysokiego ciśnienia.",
        ];
      case "pump":
        return [
          "Zmierz ciśnienie zasilania wstępnego, żeby wykluczyć filtr i pompę w baku.",
          if (!isDiesel) "Sprawdź popychacz (szklankę) pompy wysokiego ciśnienia na wałku rozrządu.",
          "Dopiero po wykluczeniu powyższych — pompa wysokiego ciśnienia.",
        ];
      case "sensor":
        return ["Sprawdź czujnik ciśnienia paliwa i jego wtyczkę/przewody."];
      default:
        return ["Sprawdź zawór regulacji ciśnienia i czujnik ciśnienia na szynie."];
    }
  }

  // ---------------------------------------------------------------------------
  // Kody błędów bez potwierdzenia w logu
  // ---------------------------------------------------------------------------

  /// Grupy kodów: jakie kanały/wnioski je potwierdzają i co nagrać, żeby Asystent mógł je ocenić.
  static const List<(List<String>, List<String>, String)> _dtcGroups = [
    (["P0087", "P0088", "P0093", "P0190", "P0191", "P0192", "P0193", "P2293"], ["F_RAIL"],
        "ciśnienie paliwa na wolnych obrotach i podczas mocnego przyspieszenia (profil „Paliwo, mieszanka i zapłon”)"),
    (["P0299", "P0234", "P0235", "P0236", "P0237", "P0238", "P2562", "P2563", "P0045", "P0046", "P0047", "P0048", "P0049"], ["BOOST", "TARGET_BOOST", "VGT_ACT", "WG_ACT"],
        "przyspieszenie na pełnym gazie od ok. 1500 obr/min (tryb „Przyspieszenie”)"),
    (["P2002", "P2463", "P244A", "P244B", "P2452", "P2453", "P2454", "P2455"], ["DPF_DP"],
        "10-15 minut jazdy z jednym mocnym przyspieszeniem (profil „Turbo, DPF i przepływ spalin”)"),
    (["P0400", "P0401", "P0402", "P0403", "P0404", "P0405", "P0406", "P0409"], ["EGR_ACT", "EGR_CMD"],
        "spokojną jazdę i wolne obroty (profil „Diagnostyka automatyczna”)"),
    (["P0300", "P0301", "P0302", "P0303", "P0304", "P0305", "P0306", "P0307", "P0308"], ["MIS_1", "MIS_2", "MIS_3", "MIS_4", "F_RAIL"],
        "wolne obroty przez 1-2 minuty oraz jedno przyspieszenie (liczniki wypadania zapłonów i korekty paliwa)"),
    (["P0171", "P0172", "P0174", "P0175"], ["STFT", "LTFT", "F_RAIL", "MAF"],
        "wolne obroty i spokojną jazdę (korekty paliwa, przepływ powietrza)"),
    (["P0100", "P0101", "P0102", "P0103"], ["MAF", "BOOST"],
        "przyspieszenie na pełnym gazie (przepływ powietrza względem doładowania)"),
  ];

  static List<Anomaly> _unconfirmedDtcs(List<LogPoint> pts, Set<String> dtcs, List<Anomaly> found) {
    final out = <Anomaly>[];
    final foundKeys = found.map((a) => a.paramKey).toSet();
    for (final code in dtcs) {
      final group = _dtcGroups.where((g) => g.$1.contains(code)).firstOrNull;
      if (group == null) continue;
      final (_, keys, whatToLog) = group;
      // Kod już wyjaśniony przez analizę logu (np. P0087 przez diagnozę ciśnienia paliwa)
      if (keys.any(foundKeys.contains)) continue;
      if (code.startsWith("P030") && found.any((a) => a.id.startsWith("rail_low_idle_"))) continue;
      final hasData = keys.any((k) => _has(pts, k));
      final info = DtcCode.getByCode(code);
      out.add(Anomaly(
        id: "dtc_$code",
        title: "Kod $code: ${info.title}",
        severity: AnomalySeverity.warning,
        paramKey: "DTC",
        startMs: pts.first.timeMs,
        endMs: pts.last.timeMs,
        startRpm: 0,
        endRpm: 0,
        observedValueText: hasData
            ? "W tym logu parametry były w normie — usterka może występować okresowo"
            : "Ten log nie zawiera danych potrzebnych do oceny kodu",
        plainSummary: hasData
            ? "Sterownik zapisał kod $code, ale w tym logu objawu nie było widać. Usterka może pojawiać się tylko w określonych warunkach — nagraj $whatToLog, najlepiej wtedy, gdy problem występuje."
            : "Sterownik zapisał kod $code. Żeby Asystent mógł wskazać przyczynę, nagraj $whatToLog.",
        description: info.description,
        hypotheses: info.commonCauses,
        recommendations: ["Nagraj: $whatToLog.", ...info.diagnosticsSteps],
      ));
    }
    return out;
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
