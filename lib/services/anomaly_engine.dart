import 'dart:math';
import '../models/anomaly.dart';
import '../models/log_point.dart';
import '../models/trip_report.dart';
import 'analysis/drive_analyzer.dart';
import 'analysis/drive_state.dart';
import 'analysis/signal_stats.dart';
import 'analysis/evap_test.dart';
import '../models/engine_profiles.dart';

class AnomalyEngine {
  /// Analizuje zebraną sesję logowania i zwraca listę wykrytych nieprawidłowości
  ///
  /// [isDiesel] wyłącza reguły, które mają sens tylko w silnikach benzynowych
  /// (skład mieszanki AFR/lambda, sonda wąskopasmowa, kąt zapłonu, podciśnienie
  /// w kolektorze na biegu jałowym — diesel nie ma przepustnicy dławiącej).
  static List<Anomaly> analyzeSession(List<LogPoint> rawPoints, {bool isDiesel = false, List<String> dtcCodes = const [], String engineInfo = "", String engineCode = ""}) {
    if (rawPoints.length < 5) return [];
    // Wolne kanały są odpytywane rzadziej — uzupełnij je ostatnią znaną wartością
    // Przy wolnym odczycie (K-line) parametry przychodzą co kilka sekund — uzupełniamy
    // dłużej; przepustnicę przeliczamy na otwarcie 0–100% (położenie zamknięte bywa 8–20%).
    final fillAge = max(3000.0, SignalStats.medianDtMs(rawPoints) * 2.5);
    final points = DriveState.normalizeThrottle(DriveState.forwardFill(rawPoints, maxAgeMs: fillAge), isDiesel: isDiesel);

    final List<Anomaly> anomalies = [];

    // Log z prowadzonego testu EVAP: rozstrzyga sam test (ogólne reguły biegu jałowego
    // dałyby tu mylące, sprzeczne podpowiedzi)
    if (points.any((p) => p.has(evapTestPhaseKey))) {
      return [EvapTestVerdict.evaluate(points).toAnomaly(points)];
    }

    // 1. Wykryj próby przyspieszenia (WOT - Wide Open Throttle)
    final wotWindows = _detectWotWindows(points, isDiesel: isDiesel);

    // Jeśli nie wykryto idealnego WOT, analizujemy całą sesję jeśli jest dynamiczna
    final windowsToAnalyze = wotWindows.isNotEmpty
        ? wotWindows
        : [points];

    final knockEvents = <_KnockEvent>[];
    for (final window in windowsToAnalyze) {
      if (window.length < 3) continue;

      // 1. Analiza cofania zapłonu (Knock / Timing Retard) — zdarzenia scalane niżej w jeden wynik
      if (!isDiesel) _collectKnockEvents(window, knockEvents);

      // 2. Analiza spadków ciśnienia doładowania (Boost Leaks)
      _checkBoostLeaks(window, anomalies, isDiesel: isDiesel);

      // 4. Analiza składu mieszanki (Lean AFR under load)
      if (!isDiesel) _checkLeanAfr(window, anomalies);

      // 5. Analiza przepływomierza powietrza (MAF drop)
      _checkMafDegradation(window, anomalies);

      // 6. Analiza przegrzewania dolotu (IAT Heat Soak)
      _checkIatHeatSoak(window, anomalies);


    }

    if (knockEvents.isNotEmpty) anomalies.add(_knockAnomaly(knockEvents));

    // 7. Korekty paliwa — na całej sesji (w oknach pełnego gazu sterownik jest w pętli otwartej)
    _checkFuelTrims(points, anomalies);

    // 10. Badanie Leniwej Sondy Lambda (Wąskopasmowa) - na pełnej sesji
    if (!isDiesel) _checkNarrowbandO2Health(points, anomalies);

    // 11. Badanie Odcięcia Paliwa AFR (Szerokopasmowa) - na pełnej sesji
    if (!isDiesel) _checkWidebandAfrResponse(points, anomalies);

    // 12. Krzyżowa Analiza Wypadania Zapłonów (Misfire Profiler) - na pełnej sesji
    _checkMisfireRootCause(points, anomalies);


    // 8. Analiza falowania obrotów i drgań na biegu jałowym (benzyna: EVAP / MAP / cewki).
    //    W dieslu bieg jałowy naturalnie faluje z obciążeniem, a przyczyny są inne —
    //    ta reguła (korekty STFT, EVAP) dotyczy tylko silników benzynowych.
    if (!isDiesel) _checkIdleHunting(points, anomalies);

    // 9. Analiza zacięcia zmiennych faz rozrządu VVT / utraty podciśnienia w kolektorze (P0011)
    if (!isDiesel) _checkVvtJamming(points, anomalies);

    // Wykrywanie wyłączonej ekologii (DPF/EGR) — na całej sesji, bo EGR ocenia się
    // przy częściowym obciążeniu, a nie tylko w oknach pełnego gazu
    _checkEcologyTampering(points, anomalies, isDiesel: isDiesel);

    // 13. Diagnoza różnicowa całej jazdy: doładowanie (DPF / nieszczelność / VGT / EGR / tryb
    //     awaryjny), ciśnienie paliwa zadane vs rzeczywiste, siłowniki, zapełnienie DPF, moment
    final drive = DriveAnalyzer.analyze(points, isDiesel: isDiesel, dtcCodes: dtcCodes);
    // Gdy analiza ciśnienia paliwa wskazała lejący wtrysk konkretnego cylindra, reguła
    // „wypadanie zapłonu = brak iskry” dla tego cylindra byłaby mylącym tropem
    for (final leak in drive.where((a) => a.id.startsWith("rail_low_idle_"))) {
      final cyl = RegExp(r"_cyl(\d)").firstMatch(leak.id)?.group(1);
      anomalies.removeWhere((a) =>
          (a.id.startsWith("misfire_spark_") || a.id.startsWith("misfire_rich_")) &&
          (cyl == null || a.id.startsWith("misfire_spark_${cyl}_") || a.id.startsWith("misfire_rich_${cyl}_")));
    }
    // Reguła „nagły spadek doładowania” patrzy tylko na samo ciśnienie; gdy diagnoza
    // różnicowa objęła ten sam odcinek (z przepływem, DPF, VGT), jej wniosek jest pełniejszy
    for (final d in drive.where((a) => a.paramKey == "BOOST")) {
      anomalies.removeWhere((a) => a.id.startsWith("boost_") && a.startMs <= d.endMs && a.endMs >= d.startMs);
    }
    anomalies.addAll(drive);

    // Dopełnienie wiedzą o silniku: gdy anomalia pasuje do typowej wady wykrytej
    // jednostki, dokładamy krótką notatkę „typowe dla tego silnika…”.
    return _annotateWithEngine(anomalies, engineInfo, engineCode);
  }

  /// Mapuje anomalię na obszar usterki (do dopasowania profilu silnika).
  static FaultArea? _areaOf(Anomaly a) {
    final id = a.id.toLowerCase();
    if (id.startsWith("rail_low_idle") || id.contains("injector") || id.startsWith("misfire_rich")) return FaultArea.injectors;
    if (id.startsWith("rail_")) return FaultArea.railPressure;
    if (id.startsWith("misfire")) return FaultArea.misfire;
    if (id.startsWith("dpf") || id.contains("dpf")) return FaultArea.dpf;
    if (id.startsWith("egr") || id.contains("egr")) return FaultArea.egr;
    if (id.contains("leak") || id.contains("intake")) return FaultArea.intake;
    if (id.startsWith("vgt") || id.startsWith("underboost") || id.startsWith("boost") || a.paramKey == "BOOST") return FaultArea.turbo;
    if (id.contains("vvt") || id.contains("timing")) return FaultArea.timing;
    if (id.contains("knock") || id.contains("ignition")) return FaultArea.ignition;
    if (id.contains("lean") || id.contains("afr") || id.contains("idle_hunting")) return FaultArea.mixture;
    return null;
  }

  static List<Anomaly> _annotateWithEngine(List<Anomaly> anomalies, String engineInfo, String engineCode) {
    final engine = engineCode.isNotEmpty
        ? EngineProfiles.byCode(engineCode)
        : (engineInfo.trim().isEmpty ? null : EngineProfiles.detect(engineInfo));
    if (engine == null) return anomalies;
    return [
      for (final a in anomalies)
        () {
          final area = _areaOf(a);
          final fault = area == null ? null : engine.faultFor(area);
          if (fault == null) return a;
          return a.withEngineNote("Typowe dla ${engine.name}: ${fault.title}. ${fault.note}");
        }(),
    ];
  }

  /// Wykrywa okna czasowe, w których kierowca wcisnął gaz do dechy (WOT)
  static List<List<LogPoint>> _detectWotWindows(List<LogPoint> points, {bool isDiesel = false}) {
    final List<List<LogPoint>> windows = [];
    List<LogPoint> currentWindow = [];

    for (final p in points) {
      // Pedał gazu jest najlepszym źródłem; TPS tylko w benzynie (w dieslu to
      // klapa dławiąca); bez obu — obciążenie silnika.
      final bool isWot;
      if (p.has("PEDAL")) {
        isWot = p.tps >= 80.0;
      } else if (p.has("TPS") && !isDiesel) {
        isWot = p.tps >= 80.0;
      } else {
        isWot = p.load >= 75.0;
      }
      if (isWot) {
        currentWindow.add(p);
      } else {
        if (currentWindow.length >= 3) {
          final durationMs = currentWindow.last.timeMs - currentWindow.first.timeMs;
          final rpmGain = currentWindow.last.rpm - currentWindow.first.rpm;
          if (durationMs >= 1200 && rpmGain >= 1000) {
            windows.add(List.from(currentWindow));
          }
        }
        currentWindow.clear();
      }
    }

    if (currentWindow.length >= 3) {
      final durationMs = currentWindow.last.timeMs - currentWindow.first.timeMs;
      final rpmGain = currentWindow.last.rpm - currentWindow.first.rpm;
      if (durationMs >= 1200 && rpmGain >= 1000) {
        windows.add(List.from(currentWindow));
      }
    }

    return windows;
  }

  /// Mediana odstępu między próbkami (ms). Adaptery i protokoły różnią się ogromnie:
  /// szybki CAN daje kilkanaście próbek/s, stare auta na K-line nawet poniżej 1/s.
  /// Reguły muszą liczyć czas, a nie liczbę próbek.
  static double _medianDtMs(List<LogPoint> pts) => SignalStats.medianDtMs(pts);

  /// Łączny czas trwania wybranych próbek (sumuje odstępy nie dłuższe niż [maxGapMs]).
  static double _durationMs(List<LogPoint> pts, double maxGapMs) => SignalStats.durationMs(pts, maxGapMs);

  /// Suma prawidłowych korekt (STFT + LTFT) albo null, gdy żadnej nie ma.
  static double? _totalTrim(LogPoint p) => SignalStats.totalTrim(p);

  static double _pct(List<double> v, double q) => SignalStats.pct(v, q);

  /// Czy próbka jest pod wyraźnym obciążeniem (tylko wtedy cofnięcie zapłonu może oznaczać stuk).
  static bool _underLoad(LogPoint p) {
    if (p.has("PEDAL") || p.has("TPS")) return p.tps >= 55;
    if (p.has("LOAD")) return p.load >= 70;
    return false;
  }

  /// Zbiera zdarzenia cofnięcia zapłonu pod obciążeniem (spalanie stukowe).
  ///
  /// Kąt zapłonu w normalnej jeździe skacze o dziesiątki stopni (lekkie obciążenie → duże
  /// wyprzedzenie, odpuszczenie gazu, zmiana biegu, redukcja momentu, bieg jałowy). Dlatego
  /// spadek liczymy wyłącznie w ciągłym odcinku pod obciążeniem, względem kąta z ostatnich
  /// ~1,5 s tego samego odcinka — nie względem maksimum z całej jazdy. Pomijamy początek
  /// wciśnięcia gazu (sterownik łagodzi szarpnięcie), spadek obrotów (zmiana biegu) i
  /// naturalne zmniejszanie kąta przy rosnącym doładowaniu/obciążeniu.
  static void _collectKnockEvents(List<LogPoint> pts, List<_KnockEvent> out) {
    if (!pts.any((p) => p.has("IGN"))) return;
    // Bez informacji o obciążeniu nie da się odróżnić stuku od sterowania momentem
    if (!pts.any((p) => p.has("PEDAL") || p.has("TPS") || p.has("LOAD"))) return;

    double? loadedSince;
    int? dipStart;
    LogPoint? dipBase;
    double dipBaseline = 0;
    LogPoint? dipMin;
    int dipSamples = 0;

    void closeDip() {
      if (dipStart != null && dipMin != null && dipBase != null && dipSamples >= 2) {
        out.add(_KnockEvent(pts[dipStart!], dipMin!, dipBaseline, dipMin!.ign));
      }
      dipStart = null;
      dipBase = null;
      dipMin = null;
      dipSamples = 0;
    }

    for (int i = 1; i < pts.length; i++) {
      final p = pts[i];
      final prev = pts[i - 1];
      final loaded = p.has("IGN") && _underLoad(p) && p.rpm >= 1800;
      if (!loaded) {
        loadedSince = null;
        closeDip();
        continue;
      }
      loadedSince ??= p.timeMs;
      // Zmiana biegu / spadek obrotów — sterownik celowo cofa zapłon
      if (p.rpm < prev.rpm - 250) {
        closeDip();
        continue;
      }
      // Pierwsze ~0,8 s po wciśnięciu gazu to łagodzenie szarpnięcia, nie stuk
      if (p.timeMs - loadedSince < 800) continue;

      // Kąt bazowy: maksimum z ostatnich 1,5 s ciągłego obciążenia (sprzed spadku)
      LogPoint? base;
      for (int j = i - 1; j >= 0 && p.timeMs - pts[j].timeMs <= 1500; j--) {
        final q = pts[j];
        if (!q.has("IGN") || !_underLoad(q)) break;
        if (dipStart != null && j >= dipStart!) continue;
        if (base == null || q.ign > base.ign) base = q;
      }
      if (base == null) continue;

      // Rosnące doładowanie / obciążenie naturalnie zmniejsza kąt — to nie stuk
      final boostRise = (p.has("BOOST") && base.has("BOOST")) ? p.boost - base.boost : 0.0;
      final loadRise = (p.has("LOAD") && base.has("LOAD")) ? p.load - base.load : 0.0;
      final retard = base.ign - p.ign;
      final inDip = retard >= 4.0 && boostRise <= 0.2 && loadRise <= 15;

      if (inDip) {
        if (dipStart == null) {
          dipStart = i;
          dipBase = base;
          dipBaseline = base.ign;
        }
        dipSamples++;
        if (dipMin == null || p.ign < dipMin!.ign) dipMin = p;
      } else {
        closeDip();
      }
    }
    closeDip();
  }

  /// Jeden wynik dla wszystkich zdarzeń cofnięcia zapłonu (zamiast listy powtórzeń).
  static Anomaly _knockAnomaly(List<_KnockEvent> events) {
    final worst = events.reduce((a, b) => a.retard >= b.retard ? a : b);
    final p = worst.minPoint;
    final n = events.length;
    final isCritical = worst.retard >= 8.0 || (n >= 3 && worst.retard >= 6.0);
    final rpmFrom = events.map((e) => e.start.rpm).reduce(min).toInt();
    final rpmTo = events.map((e) => e.minPoint.rpm).reduce(max).toInt();
    final count = n == 1 ? "1 zdarzenie" : (n < 5 ? "$n zdarzenia" : "$n zdarzeń");
    return Anomaly(
      id: "ign_${worst.start.timeMs.toInt()}",
      title: "Cofanie zapłonu pod obciążeniem (spalanie stukowe)",
      severity: isCritical ? AnomalySeverity.critical : AnomalySeverity.warning,
      paramKey: "IGN",
      startMs: worst.start.timeMs,
      endMs: p.timeMs,
      startRpm: worst.start.rpm,
      endRpm: p.rpm,
      observedValueText: "$count; największe cofnięcie o ${worst.retard.toStringAsFixed(1)}° "
          "(z ${worst.baseline.toStringAsFixed(1)}° do ${worst.minIgn.toStringAsFixed(1)}°) przy ${p.rpm.toInt()} obr/min",
      primarySymptom: "Pod mocnym gazem sterownik cofa kąt wyprzedzenia zapłonu ($rpmFrom–$rpmTo obr/min)",
      plainSummary: "Przy mocnym przyspieszaniu sterownik ${n == 1 ? 'raz' : '$n razy'} wyraźnie cofnął zapłon — tak reaguje na "
          "stukanie w cylindrach. Najczęstsze przyczyny to słabe paliwo, zużyte świece albo nagar. "
          "Zatankuj dobre paliwo i powtórz pomiar; jeśli się powtarza — sprawdź świece i zapłon.",
      correlatedSignals: {
        "IGN": "cofnięcie o ${worst.retard.toStringAsFixed(1)}° (z ${worst.baseline.toStringAsFixed(1)}°)",
        if (p.has("IAT")) "IAT": "${p.iat.toStringAsFixed(0)} °C ${p.iat > 52 ? '(przegrzany dolot)' : '(w normie)'}",
        if (p.has("AFR")) "AFR": "${p.afr.toStringAsFixed(1)}:1",
        if (p.has("BOOST")) "BOOST": "${p.boost.toStringAsFixed(2)} bar",
        "Gaz": "${p.tps.toInt()}%",
      },
      falseLeadWarning: "Kod czujnika spalania stukowego nie oznacza, że czujnik jest uszkodzony — on właśnie wykrywa stuk. "
          "Wymiana czujnika nie usunie przyczyny.",
      ruledOutCauses: [
        "Pominięto spadki kąta przy odpuszczaniu gazu, zmianie biegu i na wolnych obrotach (to normalne sterowanie, nie stuk)",
        if (p.has("IAT") && p.iat < 45) "Wykluczono przegrzanie dolotu (IAT = ${p.iat.toStringAsFixed(0)}°C)",
      ],
      rootCauseConclusion: p.has("IAT") && p.iat > 52
          ? "Najbardziej prawdopodobna przyczyna: za wysoka temperatura powietrza w dolocie (IAT = ${p.iat.toStringAsFixed(0)}°C) sprzyja samozapłonom."
          : "Najbardziej prawdopodobna przyczyna: zbyt niska liczba oktanowa paliwa, nagar w komorach spalania lub zużyte świece zapłonowe.",
      description: "Sterownik silnika cofał kąt wyprzedzenia zapłonu w trakcie jazdy pod obciążeniem. "
          "Tak zachowuje się, gdy czujnik stukowy wykrywa niekontrolowane spalanie w cylindrach.",
      hypotheses: const [
        "Zbyt niska liczba oktanowa paliwa lub paliwo słabej jakości",
        "Zużyte świece zapłonowe (wypalone elektrody, zła przerwa, zły typ)",
        "Niesprawna cewka zapłonowa",
        "Nagar w komorach spalania (samozapłony)",
        "Za wysoka temperatura powietrza w dolocie lub silnika",
      ],
      recommendations: const [
        "Zatankuj świeże paliwo 98 lub 100 oktanów na sprawdzonej stacji i powtórz log.",
        "Wykręć świece i skontroluj ich stan oraz przerwę na elektrodach.",
        "Sprawdź temperaturę w dolocie (IAT) oraz układ chłodzenia.",
        "Jeśli auto jest po chiptuningu, poinformuj tunera o cofaniu zapłonu.",
      ],
    );
  }

  /// Sprawdza nieszczelności doładowania (nagły spadek ciśnienia)
  static void _checkBoostLeaks(List<LogPoint> points, List<Anomaly> anomalies, {bool isDiesel = false}) {
    if (!points.any((p) => p.values.containsKey("BOOST"))) return;

    // Nagły spadek = w ciągu ok. 1,5 s przy pełnym gazie ciśnienie spada o ≥ 0,35 bar
    // bardziej niż wartość zadana. Zwykłe opadanie doładowania na wysokich obrotach
    // (ECU samo zmniejsza zadane) nie jest nieszczelnością.
    const window = 1500.0;
    double peakBoost = 0;
    LogPoint? leakStart;
    double lowestBoostAfterPeak = 999;

    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      final boost = p.boost;
      final wot = DriveState.isFullThrottle(p.values, isDiesel: isDiesel);

      double? drop;
      double? windowPeak;
      if (wot && p.values.containsKey("BOOST")) {
        for (int j = i - 1; j >= 0 && p.timeMs - points[j].timeMs <= window; j--) {
          final q = points[j];
          if (!q.values.containsKey("BOOST") || !DriveState.isFullThrottle(q.values, isDiesel: isDiesel)) continue;
          final targetDrop = (q.values["TARGET_BOOST"] != null && p.values["TARGET_BOOST"] != null)
              ? max(0.0, q.values["TARGET_BOOST"]! - p.values["TARGET_BOOST"]!)
              : 0.0;
          final d = (q.boost - boost) - targetDrop;
          if (drop == null || d > drop) {
            drop = d;
            windowPeak = q.boost;
          }
        }
      }

      final collapsing = drop != null && drop >= 0.35 && windowPeak! >= 0.8 && p.rpm >= 2000 && p.rpm <= 6200;
      if (collapsing) {
        leakStart ??= points[max(0, i - 1)];
        if (windowPeak > peakBoost) peakBoost = windowPeak;
        if (boost < lowestBoostAfterPeak) lowestBoostAfterPeak = boost;
      } else if (leakStart != null) {
        anomalies.add(Anomaly(
          id: "boost_${leakStart.timeMs.toInt()}",
          title: "Nagły spadek doładowania (Nieszczelność Turbo / Boost Leak)",
          severity: AnomalySeverity.critical,
          paramKey: "BOOST",
          startMs: leakStart.timeMs,
          endMs: p.timeMs,
          startRpm: leakStart.rpm,
          endRpm: p.rpm,
          observedValueText: "Spadek z ${peakBoost.toStringAsFixed(2)} bar do ${lowestBoostAfterPeak.toStringAsFixed(2)} bar",
          primarySymptom: "Nagła utrata ciśnienia doładowania z ${peakBoost.toStringAsFixed(2)} bar do ${lowestBoostAfterPeak.toStringAsFixed(2)} bar przy wciśniętym gazie",
          correlatedSignals: {
            "BOOST": "Gwałtowny spadek do ${lowestBoostAfterPeak.toStringAsFixed(2)} bar",
            "MAF": "${p.maf.toStringAsFixed(1)} g/s",
            "TPS": "${p.tps.toInt()}%",
            "RPM": "${p.rpm.toInt()} obr/min",
          },
          falseLeadWarning: "UWAGA NA FAŁSZYWY TROP: Kod P0299 lub P0101 często prowadzi do wymiany przepływomierza lub turbiny. Przepływomierz widzi duży przepływ powietrza, bo ucieka ono przez rozszczelniony wąż dolotowy!",
          ruledOutCauses: [
            "Wykluczono uszkodzenie czujnika MAF – czujnik rejestruje rzeczywiste uciekające powietrze",
            "Wykluczono awarię pompy paliwa – ciśnienie doładowania spada mechanicznie",
          ],
          rootCauseConclusion: "Mechaniczne rozszczelnienie układu dolotowego pod wysokim ciśnieniem (spadła opaska, pęknięte kolanko silikonowe lub rozszczelniona boczna puszka intercoolera).",
          description: "Ciśnienie doładowania gwałtownie spadło mimo wciśniętego pedału gazu w zakresie ${leakStart.rpm.toInt()} - ${p.rpm.toInt()} RPM. Silnik stracił zadaną kompresję w układzie dolotowym.",
          hypotheses: [
            "Pęknięty wąż ciśnieniowy lub zsunięta opaska zaciskowa (złączka silikonowa)",
            "Pęknięty lub rozszczelniony intercooler (chłodnica powietrza)",
            "Uszkodzony zawór upustowy (DV - Diverter Valve / Blow-Off)",
            "Nieszczelny wężyk podciśnienia sterowania turbiną (zawór N75 / gruszka wastegate)",
            "Sterownik wszedł w tryb awaryjny (Limp Mode) z powodu błędu",
          ],
          recommendations: [
            "Wykonaj próbę szczelności dolotu dymem lub sprężonym powietrzem (tzw. test szczelności dolotu).",
            "Obejrzyj wszystkie rury dolotowe i opaski między turbiną a kolektorem ssącym.",
            "Sprawdź membranę w zaworze DV.",
            "Odczytaj kody błędów DTC w sterowniku silnika.",
          ],
        ));
        leakStart = null;
        peakBoost = 0;
        lowestBoostAfterPeak = 999;
      }
    }
  }

  /// Moduł "Ecology Tamper Check": Wykrywa usunięcie fizyczne lub programowe DPF / EGR
  static void _checkEcologyTampering(List<LogPoint> points, List<Anomaly> anomalies, {bool isDiesel = false}) {
    if (points.length < 20) return;

    // 1. Sprawdzenie zamrożonego DPF (Wyprogramowanie w ECU lub emulator)
    if (points.any((p) => p.values.containsKey("DPF_DP"))) {
      final dpfPoints = points.where((p) => p.values.containsKey("DPF_DP")).toList();
      final gap = max(1500.0, _medianDtMs(points) * 3);
      if (dpfPoints.length >= 10 && _durationMs(dpfPoints, gap) >= 20000) {
        final rpmMin = dpfPoints.map((p) => p.rpm).reduce(min);
        final rpmMax = dpfPoints.map((p) => p.rpm).reduce(max);
        
        // Wymagamy rosnących obrotów (przegazówka lub jazda), żeby opór spalin musiał fizycznie wzrosnąć
        if (rpmMax - rpmMin > 1500) {
          final dpMin = dpfPoints.map((p) => p.values["DPF_DP"]!).reduce(min);
          final dpMax = dpfPoints.map((p) => p.values["DPF_DP"]!).reduce(max);
          final variance = dpMax - dpMin;

          if (variance < 0.2) { // Różnica poniżej 0.2 kPa to fizycznie niemożliwe dla DPF
            anomalies.add(Anomaly(
              id: "dpf_delete_${dpfPoints.first.timeMs.toInt()}",
              title: "Wykryto Usunięcie DPF (Ecology Tamper)",
              severity: AnomalySeverity.tampering,
              paramKey: "DPF_DP",
              startMs: dpfPoints.first.timeMs,
              endMs: dpfPoints.last.timeMs,
              startRpm: rpmMin,
              endRpm: rpmMax,
              observedValueText: "Wariancja ciśnienia różnicowego: $variance kPa (Odczyt zamrożony na $dpMax kPa)",
              description: "Mimo znacznego wzrostu obrotów silnika, czujnik ciśnienia spalin DPF wskazuje idealnie płaską, niezmienną wartość. Prawa fizyki wymagają, by strumień spalin stawiał rosnący opór. To oznacza, że DPF został fizycznie usunięty z wydechu i 'wyprogramowany' w ECU, albo użyto emulatora.",
              hypotheses: [
                "Filtr DPF jest pusty (wycięty wkład ceramiczny), a mapa silnika została zmodyfikowana (DPF Off).",
                "Pod czujnik ciśnienia różnicowego podpięto oszust (Emulator DPF), który symuluje idealne ciśnienie.",
                "Czujnik ciśnienia DPF zawiesił się sprzętowo i 'zamarzł' na stałej wartości (rzadsze bez wyrzucenia błędu DTC)."
              ],
              recommendations: [
                "Zweryfikuj fizyczną obecność puszki filtra cząstek stałych na kanale.",
                "Zwróć uwagę na ewidentny brak legalności takiego rozwiązania (auto nie powinno przejść przeglądu).",
              ],
            ));
          }
        }
      }
    }

    // 2. Sprawdzenie wyprogramowania lub zaślepienia EGR
    // Oskarżenie o wycięcie EGR jest poważne — tylko diesel (w benzynie zawór EGR bywa stale
    // zamknięty albo zastąpiony wewnętrzną recyrkulacją przez fazy rozrządu), tylko rozgrzany
    // silnik (na zimnym sterownik celowo zamyka EGR) i co najmniej minuta takiej jazdy.
    if (isDiesel && points.any((p) => p.values.containsKey("EGR_CMD"))) {
      // Tylko częściowe obciążenie i jałowy — pod pełnym gazem każdy sprawny silnik zamyka EGR
      final egrPoints = points
          .where((p) =>
              p.values.containsKey("EGR_CMD") &&
              p.rpm >= 600 &&
              p.rpm <= 3000 &&
              (!p.has("ECT") || p.ect >= 70) &&
              !DriveState.isFullThrottle(p.values, isDiesel: isDiesel))
          .toList();
      final egrGap = max(1500.0, _medianDtMs(points) * 3);
      
      // Detekcja Software Delete (Zawsze 0%)
      bool isSoftwareDeleted = true;
      for (final p in egrPoints) {
        if (p.values["EGR_CMD"]! > 0.0) {
          isSoftwareDeleted = false;
          break;
        }
      }

      if (isSoftwareDeleted && egrPoints.length >= 10 && _durationMs(egrPoints, egrGap) >= 60000) {
        anomalies.add(Anomaly(
          id: "egr_software_delete_${egrPoints.first.timeMs.toInt()}",
          title: "Wykryto Programowe Wyłączenie EGR",
          severity: AnomalySeverity.tampering,
          paramKey: "EGR_CMD",
          startMs: egrPoints.first.timeMs,
          endMs: egrPoints.last.timeMs,
          startRpm: egrPoints.first.rpm,
          endRpm: egrPoints.last.rpm,
          observedValueText: "Zadane otwarcie EGR (EGR_CMD) przy częściowym obciążeniu i na jałowym przez cały log wynosi 0.0%.",
          description: "Nawet na biegu jałowym i przy spokojnej jeździe (kiedy EGR powinien być najbardziej aktywny by obniżać NOx), sterownik silnika kategorycznie żąda 0% otwarcia. Oznacza to, że mapa silnika została zmieniona w celu trwałego wyłączenia (EGR Off).",
          hypotheses: [
            "Wyprogramowanie EGR (EGR Delete) w mapie sterownika ECU."
          ],
          recommendations: [
            "Zjawisko częste po wycięciu ekologii. Skutkuje podwyższoną temperaturą spalania na wolnych obrotach."
          ],
        ));
      }
    }
  }

  /// Sprawdza, czy sonda wąskopasmowa nie jest „leniwa”.
  ///
  /// Liczymy tylko ciągłe odcinki ustalonej, rozgrzanej jazdy (realny czas, a nie odstęp
  /// między pierwszą i ostatnią próbką całego logu). Zdrowa sonda przełącza się ~1–3 razy
  /// na sekundę, więc liczenie przełączeń ma sens tylko przy gęstym odpytywaniu. Przy rzadszym
  /// oceniamy zakres napięć: zdrowa sonda w pętli zamkniętej schodzi poniżej ~0,25 V
  /// i wchodzi powyżej ~0,65 V.
  static void _checkNarrowbandO2Health(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("O2_V"))) return;

    bool steady(LogPoint p) {
      if (!p.has("O2_V")) return false;
      if (p.has("ECT") && p.ect < 70) return false;
      final hasThrottle = p.has("PEDAL") || p.has("TPS");
      if (hasThrottle && (p.tps <= 5 || p.tps >= 40)) return false;
      if (p.rpm < 1300 || p.rpm > 3200) return false;
      // korekty-wartowniki = pętla otwarta
      if (p.has("STFT") && _validTrim(p, "STFT") == null) return false;
      return true;
    }

    double steadySec = 0;
    int crossings = 0;
    final volts = <double>[];
    final dts = <double>[];
    LogPoint? first;
    LogPoint? lastP;
    LogPoint? prev;
    for (final p in points) {
      if (!steady(p)) {
        prev = null;
        continue;
      }
      first ??= p;
      lastP = p;
      final v = p.values["O2_V"]!;
      volts.add(v);
      if (prev != null) {
        final dt = (p.timeMs - prev.timeMs) / 1000.0;
        if (dt > 0 && dt < 1.5) {
          steadySec += dt;
          dts.add(dt);
          final a = prev.values["O2_V"]! > 0.45;
          final b = v > 0.45;
          if (a != b) crossings++;
        }
      }
      prev = p;
    }
    if (first == null || lastP == null || steadySec < 20 || volts.length < 40) return;

    final medDt = _median(dts);
    final sorted = [...volts]..sort();
    final p10 = sorted[(sorted.length * 0.1).floor()];
    final p90 = sorted[(sorted.length * 0.9).floor().clamp(0, sorted.length - 1)];

    final fastSampling = medDt <= 0.25; // co najmniej ~4 próbki/s
    final crossRate = crossings / steadySec;
    final slow = fastSampling && crossRate < 0.3;
    final compressed = p90 - p10 < 0.35 && (p10 > 0.3 || p90 < 0.6);
    if (!slow && !compressed) return;

    anomalies.add(Anomaly(
      id: "lazy_o2_${first.timeMs.toInt()}",
      title: "Leniwa sonda lambda (O2)",
      severity: AnomalySeverity.warning,
      paramKey: "O2_V",
      startMs: first.timeMs,
      endMs: lastP.timeMs,
      startRpm: first.rpm,
      endRpm: lastP.rpm,
      observedValueText: slow
          ? "$crossings przełączeń w ${steadySec.toStringAsFixed(0)} s ustalonej jazdy (zdrowa: ok. 1/s)"
          : "Napięcie sondy tylko ${p10.toStringAsFixed(2)}–${p90.toStringAsFixed(2)} V (zdrowa: ok. 0,1–0,8 V)",
      plainSummary: "Sonda lambda przed katalizatorem reaguje za wolno albo za słabo. Sterownik gorzej dobiera mieszankę, "
          "co podnosi spalanie i może zapalać kontrolkę. Zwykle pomaga wymiana sondy.",
      description: "W ustalonej jeździe na rozgrzanym silniku sonda wąskopasmowa nie przełącza się sprawnie między "
          "mieszanką bogatą i ubogą.",
      hypotheses: const [
        "Naturalne zużycie sondy (starzenie)",
        "Zanieczyszczenie sondy (olej, płyn chłodniczy, dodatki do paliwa)",
        "Nieszczelność wydechu przed sondą",
      ],
      recommendations: const [
        "Sprawdź szczelność wydechu przed sondą.",
        "Wymień przednią sondę lambda przed ewentualną naprawą katalizatora.",
      ],
    ));
  }

  /// Sprawdza opóźnienie sondy szerokopasmowej po odcięciu paliwa przy hamowaniu silnikiem
  static void _checkWidebandAfrResponse(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("AFR"))) return;

    // Szukamy momentu hamowania silnikiem: puszczony gaz przy sporych obrotach
    for (int i = 0; i < points.length - 10; i++) {
      final p1 = points[i];
      if (!p1.values.containsKey("TPS") || !p1.values.containsKey("AFR")) continue;
      
      // Moment odpuszczenia gazu: Wcześniej był wciśnięty, teraz puszczony, wysokie RPM
      if (p1.rpm > 2000 && p1.values["TPS"]! < 2.0 && points[max(0, i - 5)].values["TPS"]! > 10.0) {
        
        // Zliczamy ile zajmuje sondzie przejście w skrajnie ubogą mieszankę (AFR > 18.0)
        double delayMs = 0;
        bool reacted = false;
        
        for (int j = i; j < points.length; j++) {
          final p2 = points[j];
          if (p2.values["TPS"]! > 5.0) break; // Kierowca znowu wcisnął gaz
          
          if (p2.values["AFR"]! > 18.0) {
            delayMs = p2.timeMs - p1.timeMs;
            reacted = true;
            break;
          }
        }
        
        if (reacted && delayMs > 1200) { // Powyżej 1.2 sekundy to bardzo powolna reakcja
          anomalies.add(Anomaly(
            id: "lazy_afr_${p1.timeMs.toInt()}",
            title: "Opóźniony Odczyt AFR (Szerokopasmowa)",
            severity: AnomalySeverity.warning,
            paramKey: "AFR",
            startMs: p1.timeMs,
            endMs: p1.timeMs + delayMs,
            startRpm: p1.rpm,
            endRpm: p1.rpm,
            observedValueText: "Czas reakcji po odcięciu paliwa: ${(delayMs / 1000).toStringAsFixed(2)}s (Oczekiwano < 0.5s)",
            description: "Sonda szerokopasmowa AFR reaguje z ogromnym opóźnieniem. Po całkowitym zamknięciu przepustnicy (odcięcie paliwa wtryskiwaczy), sonda potrzebowała ponad sekundy, by zarejestrować czyste powietrze. Sonda fałszuje wskazania pod obciążeniem.",
            hypotheses: [
              "Mikroskopijne pory ceramiczne na czubku sondy są zapchane nagarem.",
              "Zużycie chemiczne elementu pomiarowego sondy LSU 4.9.",
            ],
            recommendations: [
              "Rozważ wymianę szerokopasmowej sondy przed katalizatorem.",
            ],
          ));
          // Przeskakujemy by nie rzucić wielu błędów na raz
          i += (delayMs / 50).toInt(); 
        }
      }
    }
  }

  /// Sprawdza niebezpiecznie ubogą mieszankę pod obciążeniem (Lean AFR)
  static void _checkLeanAfr(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("AFR"))) return;

    LogPoint? leanStart;
    double maxAfrSeen = 0;

    for (final p in points) {
      final afr = p.afr;
      final boost = p.boost;

      // Pod obciążeniem (boost > 0.3 bar lub obroty > 3500 i pełny gaz) AFR powyżej 13.0 jest niebezpieczny
      final isDangerousLean = (boost >= 0.3 || p.rpm >= 3500) && afr >= 13.2;

      if (isDangerousLean) {
        leanStart ??= p;
        if (afr > maxAfrSeen) maxAfrSeen = afr;
      } else if (leanStart != null) {
        final durationMs = p.timeMs - leanStart.timeMs;
        if (durationMs >= 300) {
          anomalies.add(Anomaly(
            id: "afr_${leanStart.timeMs.toInt()}",
            title: "Niebezpiecznie uboga mieszanka (Zbyt wysoki AFR w doładowaniu)",
            severity: AnomalySeverity.critical,
            paramKey: "AFR",
            startMs: leanStart.timeMs,
            endMs: p.timeMs,
            startRpm: leanStart.rpm,
            endRpm: p.rpm,
            observedValueText: "AFR osiągnął aż ${maxAfrSeen.toStringAsFixed(1)}:1 (Norma: 11.2 - 12.2:1)",
            description: "Wykryto skrajnie ubogą mieszankę pod pełnym doładowaniem przy obrotach ${leanStart.rpm.toInt()} - ${p.rpm.toInt()} RPM. Taki stan grozi stopieniem denka tłoka lub wypaleniem zaworów wydechowych!",
            hypotheses: [
              "Niewydajna, zużyta lub przegrzewająca się pompa paliwa w zbiorniku",
              "Zapchany filtr paliwa ograniczający przepływ przy wysokim zapotrzebowaniu",
              "Zablokowany lub zanieczyszczony wtryskiwacz paliwa",
              "Uszkodzony regulator ciśnienia na listwie wtryskowej",
              "Przekłamania przepływomierza MAF zaniżającego ilość wpadającego powietrza",
            ],
            recommendations: [
              "NATYCHMIAST zaprzestań gwałtownego przyspieszania pod pełnym gazem do czasu usunięcia usterki!",
              "Zmierz ciśnienie paliwa manometrem na listwie pod obciążeniem.",
              "Wymień filtr paliwa.",
              "Sprawdź wydajność pompy paliwa i stan wtryskiwaczy.",
            ],
          ));
        }
        leanStart = null;
        maxAfrSeen = 0;
      }
    }

    if (leanStart != null && points.isNotEmpty) {
      final p = points.last;
      anomalies.add(Anomaly(
        id: "afr_${leanStart.timeMs.toInt()}",
        title: "Niebezpiecznie uboga mieszanka (Zbyt wysoki AFR w doładowaniu)",
        severity: AnomalySeverity.critical,
        paramKey: "AFR",
        startMs: leanStart.timeMs,
        endMs: p.timeMs,
        startRpm: leanStart.rpm,
        endRpm: p.rpm,
        observedValueText: "AFR osiągnął aż ${maxAfrSeen.toStringAsFixed(1)}:1 (Norma: 11.2 - 12.2:1)",
        description: "Wykryto skrajnie ubogą mieszankę pod pełnym doładowaniem przy obrotach ${leanStart.rpm.toInt()} - ${p.rpm.toInt()} RPM. Taki stan grozi stopieniem denka tłoka lub wypaleniem zaworów wydechowych!",
        hypotheses: [
          "Niewydajna, zużyta lub przegrzewająca się pompa paliwa w zbiorniku",
          "Zapchany filtr paliwa ograniczający przepływ przy wysokim zapotrzebowaniu",
          "Zablokowany lub zanieczyszczony wtryskiwacz paliwa",
          "Uszkodzony regulator ciśnienia na listwie wtryskowej",
          "Przekłamania przepływomierza MAF zaniżającego ilość wpadającego powietrza",
        ],
        recommendations: [
          "NATYCHMIAST zaprzestań gwałtownego przyspieszania pod pełnym gazem do czasu usunięcia usterki!",
          "Zmierz ciśnienie paliwa manometrem na listwie pod obciążeniem.",
          "Wymień filtr paliwa.",
          "Sprawdź wydajność pompy paliwa i stan wtryskiwaczy.",
        ],
      ));
    }
  }

  /// Sprawdza nieprawidłowości przepływomierza MAF
  static void _checkMafDegradation(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("MAF"))) return;

    double maxMaf = 0;
    LogPoint? peakPoint;

    for (final p in points) {
      if (p.maf > maxMaf) {
        maxMaf = p.maf;
        peakPoint = p;
      }
    }

    // Jeśli pod koniec obrotów (> 5200 RPM) MAF nagle drastycznie spada mimo rosnących obrotów
    if (peakPoint != null && peakPoint.rpm < 4500 && maxMaf > 50) {
      final latePoints = points.where((p) => p.rpm > 5200 && p.timeMs > peakPoint!.timeMs);
      if (latePoints.isNotEmpty) {
        final avgLateMaf = latePoints.map((p) => p.maf).reduce((a, b) => a + b) / latePoints.length;
        if (avgLateMaf < maxMaf * 0.75) {
          anomalies.add(Anomaly(
            id: "maf_${peakPoint.timeMs.toInt()}",
            title: "Zaniżanie wskazań przepływomierza (Spadek MAF przy wysokich RPM)",
            severity: AnomalySeverity.warning,
            paramKey: "MAF",
            startMs: peakPoint.timeMs,
            endMs: latePoints.last.timeMs,
            startRpm: peakPoint.rpm,
            endRpm: latePoints.last.rpm,
            observedValueText: "Spadek z ${maxMaf.toStringAsFixed(0)} g/s do ${avgLateMaf.toStringAsFixed(0)} g/s",
            description: "Ilość mierzonego powietrza spada wraz ze wzrostem obrotów silnika. Przepływomierz ogranicza dawkę paliwa i dławi silnik na wyższych obrotach.",
            hypotheses: [
              "Zabrudzony element pomiarowy przepływomierza (olej z filtra, nagar)",
              "Zużycie sensora MAF i utrata kalibracji",
              "Nieszczelność w dolocie między przepływomierzem a turbosprężarką (lewe powietrze)",
            ],
            recommendations: [
              "Wyczyść przepływomierz dedykowanym preparatem do czyszczenia sensorów MAF.",
              "Sprawdź szczelność rury dolotowej (tzw. TIP - Turbo Inlet Pipe).",
              "Jeśli czyszczenie nie pomoże, zamontuj oryginalny nowy wkład MAF.",
            ],
          ));
        }
      }
    }
  }

  /// Sprawdza przegrzewanie powietrza w dolocie (IAT Heat Soak)
  static void _checkIatHeatSoak(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("IAT"))) return;

    final iatPoints = points.where((p) => p.has("IAT")).toList();
    final iatStart = iatPoints.first.iat;
    final iatEnd = iatPoints.last.iat;
    final iatMax = iatPoints.map((p) => p.iat).reduce(max);

    if (iatMax >= 55.0 || (iatEnd - iatStart) >= 18.0) {
      anomalies.add(Anomaly(
        id: "iat_${points.first.timeMs.toInt()}",
        title: "Przegrzewanie powietrza w dolocie (IAT Heat Soak)",
        severity: iatMax >= 65.0 ? AnomalySeverity.critical : AnomalySeverity.warning,
        paramKey: "IAT",
        startMs: points.first.timeMs,
        endMs: points.last.timeMs,
        startRpm: points.first.rpm,
        endRpm: points.last.rpm,
        observedValueText: "Temperatura dolotu wzrosła do ${iatMax.toStringAsFixed(1)}°C",
        description: "Temperatura powietrza wpadającego do cylindrów przekroczyła bezpieczny próg. Gorące powietrze ma mniejszą gęstość (spadek mocy) oraz drastycznie zwiększa ryzyko spalania stukowego.",
        hypotheses: [
          "Niewydajny seryjny intercooler (za mała pojemność cieplna)",
          "Zabrudzone lub pozaginane lamele chłodnicy intercoolera",
          "Bardzo wysoka temperatura otoczenia lub długa jazda w korku przed pomiarem",
        ],
        recommendations: [
          "Daj autu ochłonąć na spokojnej trasie przed kolejnym pomiarem.",
          "Wyczyść intercooler z zewnątrz z owadów i błota.",
          "Rozważ montaż większego, wydajniejszego intercoolera (FMIC).",
        ],
      ));
    }
  }

  /// Prawidłowa korekta paliwa. Sterowniki ograniczają korektę do ok. ±25–35%, więc wartości
  /// powyżej ±50% to „brak danych” (np. 0xFF = +99,2% w pętli otwartej) albo śmieci odczytu.
  static double? _validTrim(LogPoint p, String key) => SignalStats.validTrim(p, key);

  static double _median(List<double> v) => SignalStats.median(v);

  /// Sprawdza korekty paliwowe (STFT + LTFT) w ustalonej, rozgrzanej jeździe w pętli zamkniętej.
  /// Ocena na medianie, a nie na pojedynczej próbce — chwilowe skoki przy zmianie obciążenia
  /// są normalne. Rozróżnia „ubogo tylko na wolnych obrotach” (lewe powietrze) od „ubogo wszędzie”.
  static void _checkFuelTrims(List<LogPoint> points, List<Anomaly> anomalies) {
    final idle = <double>[];
    final cruise = <double>[];
    final samples = <LogPoint>[];
    for (final p in points) {
      final st = _validTrim(p, "STFT");
      final lt = _validTrim(p, "LTFT");
      if (st == null && lt == null) continue;
      if (p.has("ECT") && p.ect < 70) continue; // zimny silnik — pętla otwarta
      if (p.rpm < 500) continue;
      final hasThrottle = p.has("PEDAL") || p.has("TPS");
      if (hasThrottle && p.tps > 80) continue; // pełny gaz — wzbogacenie w pętli otwartej
      if (hasThrottle && p.tps < 3 && p.rpm > 1300) continue; // hamowanie silnikiem — odcięcie paliwa
      final total = (st ?? 0) + (lt ?? 0);
      samples.add(p);
      if (p.rpm < 1100 && (!hasThrottle || p.tps < 5)) {
        idle.add(total);
      } else {
        cruise.add(total);
      }
    }
    final all = [...idle, ...cruise];
    if (all.length < 20) return; // za mało danych z pętli zamkniętej

    final med = _median(all);
    final idleMed = idle.length >= 10 ? _median(idle) : null;
    final cruiseMed = cruise.length >= 10 ? _median(cruise) : null;
    final first = samples.first;
    final last = samples.last;
    String part(double? v) => v == null ? "—" : "${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%";

    // Ubogo głównie na wolnych obrotach, w jeździe w normie → lewe powietrze
    final vacuumLeak = idleMed != null && idleMed > 12 && (cruiseMed == null || cruiseMed < idleMed - 8);
    if (med > 15 || vacuumLeak) {
      anomalies.add(Anomaly(
        id: "trim_pos_${first.timeMs.toInt()}",
        title: vacuumLeak
            ? "Uboga mieszanka na wolnych obrotach (lewe powietrze)"
            : "Wysokie dodatnie korekty paliwa (uboga mieszanka)",
        severity: AnomalySeverity.warning,
        paramKey: "STFT",
        startMs: first.timeMs,
        endMs: last.timeMs,
        startRpm: first.rpm,
        endRpm: last.rpm,
        observedValueText: "Korekty łączne (mediana): ${part(med)}; wolne obroty ${part(idleMed)}, jazda ${part(cruiseMed)}",
        plainSummary: vacuumLeak
            ? "Na wolnych obrotach sterownik musi mocno dolewać paliwa, a w jeździe już nie — to typowy objaw zasysania "
                "powietrza przez nieszczelność (wąż podciśnienia, odma, uszczelka kolektora)."
            : "Sterownik stale dolewa paliwa, bo w spalinach jest za dużo tlenu. Przyczyną bywa nieszczelność dolotu, "
                "za niskie ciśnienie paliwa, przepływomierz lub brudne wtryskiwacze.",
        description: "W ustalonej jeździe na rozgrzanym silniku sterownik utrzymuje dodatnie korekty paliwa "
            "(mediana ${part(med)}), czyli kompensuje zbyt ubogą mieszankę.",
        hypotheses: [
          if (vacuumLeak) "Nieszczelność podciśnienia (wąż, kolektor, serwo hamulca, odma/PCV)",
          if (!vacuumLeak) "Nieszczelność dolotu za przepływomierzem",
          "Zaniżający przepływomierz powietrza (MAF)",
          "Za niskie ciśnienie paliwa (pompa, filtr, regulator)",
          "Przytkane wtryskiwacze",
        ],
        recommendations: [
          if (vacuumLeak) "Wykonaj próbę dymową podciśnień, sprawdź odmę (PCV) i węże serwa.",
          if (!vacuumLeak) "Sprawdź szczelność dolotu i porównaj odczyt MAF z wartością wzorcową.",
          "Zmierz ciśnienie paliwa pod obciążeniem.",
        ],
      ));
    } else if (med < -15) {
      anomalies.add(Anomaly(
        id: "trim_neg_${first.timeMs.toInt()}",
        title: "Wysokie ujemne korekty paliwa (bogata mieszanka)",
        severity: AnomalySeverity.warning,
        paramKey: "STFT",
        startMs: first.timeMs,
        endMs: last.timeMs,
        startRpm: first.rpm,
        endRpm: last.rpm,
        observedValueText: "Korekty łączne (mediana): ${part(med)}; wolne obroty ${part(idleMed)}, jazda ${part(cruiseMed)}",
        plainSummary: "Sterownik stale odejmuje paliwo, bo mieszanka jest za bogata. Często winny jest lejący wtryskiwacz, "
            "zawór odpowietrzania zbiornika (EVAP) albo za wysokie ciśnienie paliwa.",
        description: "W ustalonej jeździe na rozgrzanym silniku sterownik utrzymuje ujemne korekty paliwa (mediana ${part(med)}).",
        hypotheses: const [
          "Nieszczelny, lejący wtryskiwacz paliwa",
          "Stale otwarty zawór odpowietrzania oparów paliwa (EVAP)",
          "Zbyt wysokie ciśnienie paliwa (regulator)",
          "Zawyżający przepływomierz / czujnik MAP",
        ],
        recommendations: const [
          "Odłącz zawór EVAP i sprawdź, czy korekty wracają do normy.",
          "Sprawdź szczelność wtryskiwaczy i ciśnienie paliwa.",
        ],
      ));
    }
  }

  /// Liczba zmian kierunku obrotów (szczyt ↔ dołek) z histerezą — odróżnia falowanie
  /// od jednostajnego spadku obrotów po rozgrzaniu silnika.
  static int _rpmReversals(List<LogPoint> w) => SignalStats.rpmReversals(w);

  /// Sprawdza falowanie obrotów na biegu jałowym i wskazuje przyczynę (EVAP / lewe powietrze / VVT).
  ///
  /// Działa przy każdej szybkości odpytywania: okno analizy i odstęp, który jeszcze nie
  /// przerywa odcinka postoju, zależą od faktycznej częstotliwości próbek (szybki CAN
  /// ~10–20/s, stare auta na K-line nawet <1/s). Korekty oceniane odpornie (mediana,
  /// percentyle, tylko prawidłowe wartości) — nie jedną skrajną próbką.
  static void _checkIdleHunting(List<LogPoint> points, List<Anomaly> anomalies) {
    final hasThrottle = points.any((p) => p.has("PEDAL") || p.has("TPS"));
    bool isIdle(LogPoint p) =>
        (!hasThrottle || p.tps <= 10) && p.rpm > 400 && p.rpm < 1400 && (!p.has("SPEED") || p.speed <= 3);

    final dt = _medianDtMs(points);
    final maxGap = max(1500.0, dt * 2.5);
    final winMs = (dt * 8).clamp(4000.0, 15000.0);

    // Ciągłe odcinki biegu jałowego
    final segments = <List<LogPoint>>[];
    var seg = <LogPoint>[];
    for (final p in points) {
      if (isIdle(p) && (seg.isEmpty || p.timeMs - seg.last.timeMs <= maxGap)) {
        seg.add(p);
      } else {
        if (seg.isNotEmpty) segments.add(seg);
        seg = isIdle(p) ? [p] : [];
      }
    }
    if (seg.isNotEmpty) segments.add(seg);

    // Najsilniejsze falowanie: rozrzut ≥ 220 obr/min i co najmniej dwie zmiany kierunku w oknie
    List<LogPoint>? huntSeg;
    double rpmDelta = 0, minRpm = 0, maxRpm = 0;
    for (final sg in segments) {
      if (sg.length < 5 || sg.last.timeMs - sg.first.timeMs < max(1500.0, dt * 4)) continue;
      int a = 0;
      for (int b = 0; b < sg.length; b++) {
        while (sg[b].timeMs - sg[a].timeMs > winMs) {
          a++;
        }
        final w = sg.sublist(a, b + 1);
        if (w.length < 5) continue;
        final lo = w.map((p) => p.rpm).reduce(min);
        final hi = w.map((p) => p.rpm).reduce(max);
        if (hi - lo >= 220 && hi - lo > rpmDelta && _rpmReversals(w) >= 2) {
          rpmDelta = hi - lo;
          minRpm = lo;
          maxRpm = hi;
          huntSeg = sg;
        }
      }
    }
    final idlePoints = huntSeg;
    if (idlePoints == null) return;

    // Korekty (tylko prawidłowe) i podciśnienie na tym odcinku
    final trims = [for (final p in idlePoints) ?_totalTrim(p)];
    final hasTrims = trims.length >= 3;
    final trimMed = hasTrims ? _median(trims) : 0.0;
    final trimLo = hasTrims ? _pct(trims, 0.1) : 0.0;
    final trimHi = hasTrims ? _pct(trims, 0.9) : 0.0;
    final hasMap = idlePoints.any((p) => p.has("BOOST"));
    final worstBoost = hasMap ? idlePoints.where((p) => p.has("BOOST")).map((p) => p.boost).reduce(max) : 0.0;
    final worstPoint = idlePoints.firstWhere((p) => p.rpm == minRpm);

    // Wysterowanie zaworu EVAP (PID 2E), jeśli było odczytywane
    final evapVals = [for (final p in idlePoints) if (p.has("EVAP_VP")) p.evapVp];
    final evapMax = evapVals.isEmpty ? null : evapVals.reduce(max);

    final rich = hasTrims && (trimMed <= -10 || trimLo <= -15);
    final lean = hasTrims && (trimMed >= 10 || trimHi >= 15);
    final isEvapSuspect = rich;
    final isVacuumLeakSuspect = lean;
    final isVvtSuspect = !rich && !lean && hasMap && worstBoost >= -0.42;

    String trimText() => hasTrims
        ? "mediana ${trimMed >= 0 ? '+' : ''}${trimMed.toStringAsFixed(1)}% (od ${trimLo.toStringAsFixed(1)}% do ${trimHi.toStringAsFixed(1)}%)"
        : "brak wiarygodnych korekt w logu";

    String title = "Silne falowanie obrotów na biegu jałowym";
    String conclusion = "Niestabilny bieg jałowy — przyczyny nie da się rozstrzygnąć z samych danych jazdy.";
    String plain = "Na wolnych obrotach silnik faluje. Najczęstsze przyczyny to zawór EVAP (opary paliwa z baku), "
        "nieszczelność podciśnienia, zabrudzona przepustnica albo cewki. Uruchom w aplikacji „Test zaworu EVAP” — "
        "w 2 minuty rozstrzyga, czy winny jest zawór.";
    String falseLead = "Wymiana silniczka krokowego lub przepustnicy w ciemno nie usuwa przyczyny, jeśli problem tkwi w podciśnieniu lub mieszance.";
    List<String> ruledOut = [];

    if (isEvapSuspect) {
      title = "Falowanie obrotów — podejrzenie zaciętego zaworu EVAP (opary paliwa)";
      conclusion = "Na wolnych obrotach sterownik mocno ujmuje paliwa (${trimText()}) — do silnika dostaje się dodatkowe, "
          "niesterowane paliwo. Najczęściej to opary z baku przez otwarty zawór EVAP.";
      plain = "Silnik faluje, bo na wolnych obrotach dostaje za dużo paliwa — najpewniej opary z baku przez zacięty zawór EVAP. "
          "Potwierdź „Testem zaworu EVAP” w aplikacji (zaciśnięcie węża). Wymiana zaworu to zwykle tania naprawa.";
      falseLead = "Kod P0172 (za bogato) nie oznacza uszkodzonej sondy lambda — sonda prawidłowo widzi nadmiar paliwa.";
      ruledOut = [
        "Wykluczono lewe powietrze — przy nieszczelności korekty byłyby dodatnie, a są ujemne",
        if (evapMax != null && evapMax < 5) "Sterownik nie otwierał zaworu EVAP (maks. ${evapMax.toStringAsFixed(0)}%) — opary przechodzą mimo zamkniętego zaworu, czyli zawór nie domyka",
      ];
    } else if (isVacuumLeakSuspect) {
      title = "Falowanie obrotów — podejrzenie lewego powietrza (nieszczelność podciśnienia)";
      conclusion = "Na wolnych obrotach sterownik mocno dolewa paliwa (${trimText()}) — silnik zasysa niemierzone powietrze.";
      plain = "Silnik faluje, bo na wolnych obrotach zasysa powietrze bokiem (pęknięty wąż, uszczelka kolektora, odma). "
          "Najszybciej znajdzie to próba dymowa.";
      falseLead = "Kod P0171 (za ubogo) często prowadzi do wymiany sondy lub pompy paliwa — a winna jest nieszczelność.";
      ruledOut = ["Wykluczono zawór EVAP — zacięty EVAP powoduje przelanie (korekty ujemne), a nie zubożenie"];
    } else if (isVvtSuspect) {
      title = "Falowanie obrotów przy słabym podciśnieniu — podejrzenie zmiennych faz (VVT) lub przepustnicy";
      conclusion = "Podciśnienie na wolnych jest słabe (${worstBoost.toStringAsFixed(2)} bar), a korekty neutralne (${trimText()}) — "
          "mieszanka jest w porządku, problem jest mechaniczny (fazy rozrządu, przepustnica, zawory).";
      ruledOut = ["Wykluczono zawór EVAP i lewe powietrze — korekty paliwa są neutralne"];
    }

    anomalies.add(Anomaly(
      id: "idle_hunting_${idlePoints.first.timeMs.toInt()}",
      title: title,
      severity: AnomalySeverity.warning,
      paramKey: "RPM",
      startMs: idlePoints.first.timeMs,
      endMs: idlePoints.last.timeMs,
      startRpm: minRpm,
      endRpm: maxRpm,
      observedValueText: "Falowanie ${minRpm.toInt()}–${maxRpm.toInt()} obr/min (skok o ${rpmDelta.toInt()}); korekty: ${trimText()}",
      primarySymptom: "Silnik faluje i drży na biegu jałowym (${minRpm.toInt()}–${maxRpm.toInt()} obr/min)",
      plainSummary: plain,
      correlatedSignals: {
        "RPM": "skoki o ${rpmDelta.toInt()} obr/min",
        "Korekty": trimText(),
        if (hasMap) "Podciśnienie": "${worstBoost.toStringAsFixed(2)} bar ${worstBoost >= -0.45 ? '(słabe)' : '(w normie)'}",
        if (evapMax != null) "Zawór EVAP": "wysterowanie do ${evapMax.toStringAsFixed(0)}%",
        if (hasThrottle) "Gaz": "${worstPoint.tps.toInt()}% (puszczony)",
      },
      falseLeadWarning: falseLead,
      ruledOutCauses: ruledOut,
      rootCauseConclusion: conclusion,
      description: "Na biegu jałowym zarejestrowano niestabilną pracę — obroty rosną i spadają o ${rpmDelta.toInt()} obr/min.",
      hypotheses: const [
        "Zawieszony / nieszczelny zawór EVAP — silnik zaciąga opary paliwa z baku i się dusi",
        "Nieszczelność podciśnienia (wąż, kolektor, serwo, odma)",
        "Zabrudzona przepustnica lub czujnik ciśnienia w kolektorze (MAP)",
        "Przebicie na listwie cewek zapłonowych (typowe m.in. dla EW10/TU5)",
        "Przycinający się zawór zmiennych faz rozrządu (VVT)",
      ],
      recommendations: const [
        "Wykonaj w aplikacji „Test zaworu EVAP” — zaciśnij wąż od zaworu do kolektora i porównaj pracę silnika.",
        "Wyczyść przepustnicę i czujnik MAP, wykonaj adaptację przepustnicy.",
        "Obejrzyj listwę cewek pod kątem pęknięć i śladów przebicia.",
        "Przy braku efektu — próba dymowa podciśnień.",
      ],
    ));
  }

  /// Sprawdza objawy zacięcia zmiennych faz rozrządu VVT (zanik podciśnienia na wolnych, P0011).
  /// Liczy czas trwania objawu (nie liczbę próbek) i nie twierdzi „korekty neutralne”,
  /// gdy korekt w logu nie ma.
  static void _checkVvtJamming(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("BOOST"))) return;
    final hasThrottle = points.any((p) => p.has("PEDAL") || p.has("TPS"));
    final idlePoints = points
        .where((p) => (!hasThrottle || p.tps <= 8) && p.rpm >= 550 && p.rpm <= 1300 && (!p.has("SPEED") || p.speed <= 3))
        .toList();
    if (idlePoints.length < 3) return;
    final gap = max(1500.0, _medianDtMs(points) * 2.5);

    // Zanik podciśnienia przy neutralnych korektach (lewe powietrze dałoby mocno dodatnie)
    final jammed = idlePoints.where((p) {
      if (!p.has("BOOST") || p.boost < -0.42) return false;
      final t = _totalTrim(p);
      return t == null || t.abs() <= 12;
    }).toList();
    if (jammed.length < 3 || _durationMs(jammed, gap) < 3000) return;

    final trims = [for (final p in jammed) ?_totalTrim(p)];
    final hasTrims = trims.length >= 3;
    final worstPoint = jammed.reduce((a, b) => a.boost > b.boost ? a : b);
    final trimNote = hasTrims ? "korekty neutralne (mediana ${_median(trims).toStringAsFixed(1)}%)" : "brak korekt w logu";
    anomalies.add(Anomaly(
      id: "vvt_jammed_${jammed.first.timeMs.toInt()}",
      title: "Podejrzenie zacięcia zmiennych faz rozrządu VVT (Błąd P0011 / Zanik podciśnienia)",
      severity: AnomalySeverity.critical,
      paramKey: "BOOST",
      startMs: jammed.first.timeMs,
      endMs: jammed.last.timeMs,
      startRpm: jammed.first.rpm,
      endRpm: jammed.last.rpm,
      observedValueText: "Podciśnienie spadło do ${worstPoint.boost.toStringAsFixed(2)} bar (Norma: -0.65 do -0.75 bar)",
      primarySymptom: "Gwałtowny zanik podciśnienia w kolektorze ssącym (${worstPoint.boost.toStringAsFixed(2)} bar) przy zamkniętej przepustnicy (0%)",
      correlatedSignals: {
        "BOOST": "${worstPoint.boost.toStringAsFixed(2)} bar (spadek podciśnienia, MAP > 620 mbar)",
        if (hasThrottle) "Gaz": "${worstPoint.tps.toInt()}% (przepustnica zamknięta)",
        "Korekty": trimNote,
        "RPM": "${worstPoint.rpm.toInt()} obr/min (drżenie i falowanie silnika)",
      },
      falseLeadWarning: "UWAGA NA FAŁSZYWY TROP: Kod błędu P0106 (Sygnał MAP nielogiczny) lub P0300 (Wypadanie zapłonów). Wielu mechaników niepotrzebnie wymienia czujnik MAP lub cewki zapłonowe. Czujnik MAP mierzy prawdę – podciśnienie zniknęło, bo zacięty wariator VVT cofa spaliny w kolektor dolotowy!",
      ruledOutCauses: [
        "Wykluczono uszkodzenie czujnika MAP – mierzy rzeczywisty napływ spalin z zaworów",
        if (hasTrims) "Wykluczono nieszczelność podciśnienia (lewe powietrze) – przy lewym powietrzu korekty byłyby mocno dodatnie, a są $trimNote",
        "Wykluczono lejący wtryskiwacz paliwa",
      ],
      rootCauseConclusion: "Zacięcie elektrozaworu lub wariatora zmiennych faz rozrządu w pozycji wyprzedzenia na biegu jałowym. Otwarcie zaworów ssących pokrywa się z wydechowymi (współotwarcie faz), przez co spaliny wtłaczane są do kolektora dolotowego. Silnik kuleje i dławi się spalinami. Gwałtowne 'przepalenie' (skok ciśnienia oleju do 4.5 bar) odblokowuje zawór VVT i silnik wraca do normy.",
      description: "Na biegu jałowym przy całkowicie zamkniętej przepustnicy (${worstPoint.tps.toInt()}%) nastąpił gwałtowny zanik podciśnienia w kolektorze ssącym (ciśnienie MAP wzrosło powyżej 580-650 mbar). W silnikach ze zmiennymi fazami rozrządu (np. VVT, VANOS, VTC) oznacza to zawieszenie się wałka rozrządu w pozycji wyprzedzenia (otwarte zawory ssące nakładają się na wydechowe). Silnik dusi się spalinami, potężnie wibruje i faluje. Po gwałtownej przegazówce ('przepaleniu') skok ciśnienia oleju odblokowuje koło zmiennych faz lub elektrozawór i silnik wraca do równej pracy.",
      hypotheses: [
        "Zacięty elektrozawór sterowania zmiennymi fazami VVT – zanieczyszczenia/nagar w mikro-sitku filtrującym zaworu",
        "Wyrobiony rygiel (locking pin) w kole zmiennych faz rozrządu – nie rygluje wariatora w pozycji spoczynkowej (0°) na wolnych obrotach",
        "Niskie ciśnienie oleju silnikowego na rozgrzanym silniku na biegu jałowym (rozrzedzony olej nie cofa wariatora)",
        "Poważna nieszczelność podciśnienia w kolektorze ssącym (np. pęknięty wężyk serwa hamulcowego lub uszczelka kolektora)",
      ],
      recommendations: [
        "Wykręć elektrozawór sterujący VVT (z boku głowicy silnika) i dokładnie przemyj zmywaczem sitko oraz sprawdź ruch iglicy pod napięciem 12V.",
        "Wymień olej silnikowy wraz z filtrem na wysokiej jakości syntetyk o właściwej lepkości (wariatory faz są bardzo czułe na lepkość i czystość oleju).",
        "Odczytaj kody błędów w sterowniku silnika – szukaj kodu P0011 (Camshaft Over-Advanced) lub P0012.",
        "Zmierz ciśnienie oleju manometrem na gorącym silniku na wolnych obrotach (powinno wynosić min. 1.2 - 1.5 bar).",
      ],
    ));
  }

  /// Krzyżowa analiza wypadania zapłonów: odróżnia problem z cewką/świecą od wtryskiwacza
  static void _checkMisfireRootCause(List<LogPoint> points, List<Anomaly> anomalies) {
    // Sprawdzamy cylindry 1-4 (liczniki Mode 06, monitory $A2-$A5)
    for (int cyl = 1; cyl <= 4; cyl++) {
      final misKey = "MIS_$cyl";
      if (!points.any((p) => p.values.containsKey(misKey))) continue;

      // Licznik Mode 06 jest narastający w cyklu jazdy — wypadnięcie zapłonu
      // to PRZYROST licznika między kolejnymi odczytami.
      double? previous;
      for (int i = 0; i < points.length; i++) {
        final p = points[i];
        final counter = p.values[misKey];
        if (counter == null) continue;
        final misfires = previous == null ? 0.0 : counter - previous;
        previous = counter;
        if (misfires <= 0.0) continue;

        // Znaleźliśmy wypadanie zapłonu. Patrzymy na korekty w tym czasie.
        final trimOrNull = (_validTrim(p, "STFT") != null && _validTrim(p, "LTFT") != null) ? _totalTrim(p) : null;
        if (trimOrNull != null) {
          final totalTrim = trimOrNull;

          // Czekamy 1-2 sekundy (około 20 punktów) aby nie generować tysiąca anomalii na raz
          final endTime = p.timeMs + 1500;
          
          if (totalTrim > 15.0) {
            // Wypadanie zapłonu + Korekta na mocny PLUS (brak paliwa)
            anomalies.add(Anomaly(
              id: "misfire_fuel_${cyl}_${p.timeMs.toInt()}",
              title: "Wypadanie Zapłonu (Brak Paliwa) - Cyl $cyl",
              severity: AnomalySeverity.critical,
              paramKey: misKey,
              startMs: p.timeMs,
              endMs: endTime,
              startRpm: p.rpm,
              endRpm: p.rpm,
              observedValueText: "Misfire: ${misfires.toInt()}x | Całk. korekta paliwa: +${totalTrim.toStringAsFixed(1)}%",
              description: "Wykryto wypadanie zapłonu na cylindrze $cyl przy skrajnie DOKŁADANEJ dawce paliwa (korekta > 15%). Oznacza to, że silnik wypadł z zapłonu z powodu zbyt ubogiej mieszanki (brakło paliwa). Problemem NIE jest świeca ani cewka.",
              hypotheses: [
                "Zatkany / niedomagający wtryskiwacz na cylindrze $cyl.",
                "Uszkodzona uszczelka kolektora (lewe powietrze) obok cylindra $cyl.",
              ],
              recommendations: [
                "Podmień wtryskiwacz cylindra $cyl z innym (np. $cyl <-> 1) i sprawdź czy błąd przejdzie za wtryskiwaczem.",
              ],
            ));
          } else if (totalTrim < -10.0) {
            // Wypadanie zapłonu + mieszanka mocno BOGATA: cylinder może być zalewany
            anomalies.add(Anomaly(
              id: "misfire_rich_${cyl}_${p.timeMs.toInt()}",
              title: "Wypadanie zapłonu przy bogatej mieszance - Cyl $cyl",
              severity: AnomalySeverity.critical,
              paramKey: misKey,
              startMs: p.timeMs,
              endMs: endTime,
              startRpm: p.rpm,
              endRpm: p.rpm,
              observedValueText: "Misfire: ${misfires.toInt()}x | Całk. korekta paliwa: ${totalTrim.toStringAsFixed(1)}%",
              plainSummary: "Cylinder $cyl wypada z zapłonu, a sterownik mocno ujmuje paliwa (mieszanka za bogata). To pasuje do lejącego wtryskiwacza, który zalewa cylinder $cyl, ale też do braku iskry. Sprawdź świecę cylindra $cyl: mokra i czarna = wtrysk, sucha = cewka/świeca.",
              description: "Wypadanie zapłonu na cylindrze $cyl przy korekcie paliwa ${totalTrim.toStringAsFixed(1)}%. Ujemna korekta oznacza nadmiar paliwa: albo wtryskiwacz leje i zalewa cylinder, albo niespalone paliwo z cylindra bez iskry wzbogaca spaliny.",
              hypotheses: [
                "Lejący / nieszczelny wtryskiwacz cylindra $cyl (zalewanie)",
                "Uszkodzona cewka lub świeca cylindra $cyl",
              ],
              recommendations: [
                "Wykręć świecę cylindra $cyl: mokra, czarna i pachnąca paliwem = wtryskiwacz; sucha = układ zapłonowy.",
                "Zamień cewkę z sąsiednim cylindrem — jeśli wypadanie przejdzie za cewką, winna jest cewka.",
                "Sprawdź, czy olej nie pachnie paliwem (lejący wtrysk rozcieńcza olej).",
              ],
            ));
          } else {
            // Wypadanie zapłonu + Korekta OK lub lekko UJEMNA (brak iskry, paliwo leje się w wydech)
            anomalies.add(Anomaly(
              id: "misfire_spark_${cyl}_${p.timeMs.toInt()}",
              title: "Wypadanie Zapłonu (Brak Iskry) - Cyl $cyl",
              severity: AnomalySeverity.critical,
              paramKey: misKey,
              startMs: p.timeMs,
              endMs: endTime,
              startRpm: p.rpm,
              endRpm: p.rpm,
              observedValueText: "Misfire: ${misfires.toInt()}x | Całk. korekta paliwa: ${totalTrim.toStringAsFixed(1)}%",
              description: "Wykryto wypadanie zapłonu na cylindrze $cyl przy normalnej lub ujemnej korekcie paliwowej. Oznacza to, że paliwo zostało podane, ale nie zostało spalone. Niespalone paliwo trafia do wydechu, fałszując sondę lambda na bogato.",
              hypotheses: [
                "Uszkodzona cewka zapłonowa na cylindrze $cyl.",
                "Przebicie na świecy zapłonowej lub kablu wysokiego napięcia.",
                "Brak kompresji na cylindrze (rzadsze).",
              ],
              recommendations: [
                "Zamień cewkę zapłonową z cylindra $cyl na cylinder sąsiedni i sprawdź czy misfire podąża za cewką.",
              ],
            ));
          }

          // Przeskakujemy 30 punktów do przodu (1.5s) żeby nie zasypywać anomaliami
          i += 30;
        }
      }
    }
  }

  /// Tryb Długodystansowy - Analizuje CAŁĄ trasę i generuje zwięzły raport
  static TripReport generateTripReport(List<LogPoint> points, {bool isDiesel = false, List<String> dtcCodes = const []}) {
    if (points.isEmpty) {
      return const TripReport(
        duration: Duration.zero, distanceKm: 0, totalPoints: 0,
        maxRpm: 0, maxBoostBar: 0, maxEctC: 0, maxIatC: 0, avgLtft: 0,
        aggregatedAnomalies: [], healthScore: 100,
      );
    }

    double maxRpm = 0;
    double maxBoost = 0;
    double maxEct = 0;
    double maxIat = 0;
    double sumLtft = 0;
    int countLtft = 0;
    double avgSpeed = 0;

    for (final p in points) {
      if (p.rpm > maxRpm) maxRpm = p.rpm;
      if (p.values.containsKey("BOOST") && p.values["BOOST"]! > maxBoost) maxBoost = p.values["BOOST"]!;
      if (p.values.containsKey("ECT") && p.values["ECT"]! > maxEct) maxEct = p.values["ECT"]!;
      if (p.values.containsKey("IAT") && p.values["IAT"]! > maxIat) maxIat = p.values["IAT"]!;
      if (p.values.containsKey("LTFT")) {
        sumLtft += p.values["LTFT"]!;
        countLtft++;
      }
      if (p.values.containsKey("SPEED")) {
        avgSpeed += p.values["SPEED"]!;
      }
    }

    avgSpeed = points.isNotEmpty && points.any((p) => p.values.containsKey("SPEED")) 
        ? (avgSpeed / points.where((p) => p.values.containsKey("SPEED")).length) 
        : 0.0; // Bez prędkości nie szacujemy dystansu
        
    final avgLtft = countLtft > 0 ? sumLtft / countLtft : 0.0;
    final durationMs = points.last.timeMs - points.first.timeMs;
    final durationHours = durationMs / 1000.0 / 3600.0;
    final distanceKm = avgSpeed * durationHours;

    // 1. Zdobądź zwykłe anomalie z całej trasy
    final List<Anomaly> rawAnomalies = analyzeSession(points, isDiesel: isDiesel, dtcCodes: dtcCodes);

    // 2. Dodaj anomalie długodystansowe (Termostat, Ujemne/Dodatnie LTFT)
    // Termostat: ECT powinno być > 85C jeśli trasa trwa > 10 minut
    if (durationMs > 10 * 60 * 1000) {
      if (maxEct > 0 && maxEct < 80.0) {
        rawAnomalies.add(Anomaly(
          id: "thermostat_open",
          title: "Niedogrzany Silnik (Termostat)",
          severity: AnomalySeverity.warning,
          paramKey: "ECT",
          startMs: points.first.timeMs,
          endMs: points.last.timeMs,
          startRpm: 0, endRpm: 0,
          observedValueText: "Maksymalna temperatura ECT wyniosła zaledwie ${maxEct.toStringAsFixed(1)}°C w trakcie długiej jazdy.",
          description: "Mimo długiej jazdy, silnik nie osiągnął temperatury roboczej (min. 85-90°C). Oznacza to, że termostat zaciął się w pozycji otwartej. Jazda niedogrzanym autem drastycznie przyspiesza zużycie silnika i zwiększa spalanie.",
          hypotheses: ["Zacięty / Otwarty termostat głównego obiegu."],
          recommendations: ["Wymień termostat jak najszybciej, by przywrócić optymalne spalanie."],
        ));
      }
    }

    if (avgLtft > 15.0) {
      rawAnomalies.add(Anomaly(
        id: "long_term_lean",
        title: "Długoterminowa Uboga Mieszanka",
        severity: AnomalySeverity.critical,
        paramKey: "LTFT",
        startMs: points.first.timeMs, endMs: points.last.timeMs,
        startRpm: 0, endRpm: 0,
        observedValueText: "Średnia z trasy: +${avgLtft.toStringAsFixed(1)}%",
        description: "Sterownik w trakcie całej jazdy musiał dolewać bardzo dużo paliwa (średnio ponad +15%). Auto jeździ na skrajnie ubogiej mieszance lub ciągnie ogromne ilości lewego powietrza.",
        hypotheses: ["Poważna nieszczelność w dolocie za przepływomierzem", "Kończąca się pompa paliwa", "Zatkane wtryskiwacze"],
        recommendations: ["Zrób test szczelności dymem", "Sprawdź ciśnienie paliwa manometrem"],
      ));
    } else if (avgLtft < -15.0) {
      rawAnomalies.add(Anomaly(
        id: "long_term_rich",
        title: "Długoterminowa Bogata Mieszanka",
        severity: AnomalySeverity.critical,
        paramKey: "LTFT",
        startMs: points.first.timeMs, endMs: points.last.timeMs,
        startRpm: 0, endRpm: 0,
        observedValueText: "Średnia z trasy: ${avgLtft.toStringAsFixed(1)}%",
        description: "Sterownik koryguje mapę drastycznie obcinając dawkę paliwa. Auto jeździ na mocno przelanej mieszance.",
        hypotheses: ["Lejące wtryskiwacze", "Zaniżający MAF", "Awaria czujnika ciśnienia paliwa"],
        recommendations: ["Sprawdź korekty wtryskiwaczy i świece na obecność czarnego nalotu."],
      ));
    }

    // 3. Agregacja (Grupowanie tych samych awarii)
    final Map<String, List<Anomaly>> grouped = {};
    for (final a in rawAnomalies) {
      // Grupujemy po 'title', ignorując timestamp w 'id'
      final baseTitle = a.title;
      grouped.putIfAbsent(baseTitle, () => []).add(a);
    }

    final List<AggregatedAnomaly> aggregated = [];
    int deduction = 0;

    for (final group in grouped.values) {
      final sample = group.first;
      final count = group.length;
      aggregated.add(AggregatedAnomaly(sample: sample, occurrenceCount: count));
      
      if (sample.severity == AnomalySeverity.critical) deduction += 30;
      else if (sample.severity == AnomalySeverity.warning) deduction += 15;
      else if (sample.severity == AnomalySeverity.tampering) deduction += 50;
    }

    // Wylicz punkty zdrowia
    int score = 100 - deduction;
    if (score < 0) score = 0;

    // Posortuj od najgroźniejszych
    aggregated.sort((a, b) {
      final sevA = a.sample.severity.index; // 0=info, 1=warning, 2=critical, 3=tampering
      final sevB = b.sample.severity.index;
      if (sevB != sevA) return sevB.compareTo(sevA);
      return b.occurrenceCount.compareTo(a.occurrenceCount);
    });

    return TripReport(
      duration: Duration(milliseconds: durationMs.toInt()),
      distanceKm: distanceKm,
      totalPoints: points.length,
      maxRpm: maxRpm,
      maxBoostBar: maxBoost,
      maxEctC: maxEct,
      maxIatC: maxIat,
      avgLtft: avgLtft,
      aggregatedAnomalies: aggregated,
      healthScore: score,
    );
  }
}

/// Pojedyncze cofnięcie zapłonu pod obciążeniem.
class _KnockEvent {
  final LogPoint start;
  final LogPoint minPoint;
  final double baseline;
  final double minIgn;
  const _KnockEvent(this.start, this.minPoint, this.baseline, this.minIgn);
  double get retard => baseline - minIgn;
}
