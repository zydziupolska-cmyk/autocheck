import 'dart:math';
import '../models/anomaly.dart';
import '../models/log_point.dart';
import '../models/trip_report.dart';

class AnomalyEngine {
  /// Analizuje zebraną sesję logowania i zwraca listę wykrytych nieprawidłowości
  static List<Anomaly> analyzeSession(List<LogPoint> points) {
    if (points.length < 5) return [];

    final List<Anomaly> anomalies = [];

    // 1. Wykryj próby przyspieszenia (WOT - Wide Open Throttle)
    final wotWindows = _detectWotWindows(points);

    // Jeśli nie wykryto idealnego WOT, analizujemy całą sesję jeśli jest dynamiczna
    final windowsToAnalyze = wotWindows.isNotEmpty
        ? wotWindows
        : [points];

    for (final window in windowsToAnalyze) {
      if (window.length < 5) continue;

      // 1. Analiza cofania zapłonu (Knock / Timing Retard)
      _checkTimingRetard(window, anomalies);

      // 2. Analiza spadków ciśnienia doładowania (Boost Leaks)
      _checkBoostLeaks(window, anomalies);

      // 3. Analiza braku doładowania i korelacji z DPF / GPF (Przeciwciśnienie wydechu)
      _checkUnderboostAndDpfCorrelation(window, anomalies);

      // 4. Analiza składu mieszanki (Lean AFR under load)
      _checkLeanAfr(window, anomalies);

      // 5. Analiza przepływomierza powietrza (MAF drop)
      _checkMafDegradation(window, anomalies);

      // 6. Analiza przegrzewania dolotu (IAT Heat Soak)
      _checkIatHeatSoak(window, anomalies);

      // 7. Analiza korekt paliwowych (STFT / LTFT)
      _checkFuelTrims(window, anomalies);

      // 8. Porównanie ciśnienia zadanego z rzeczywistym (Target Boost vs Actual)
      _checkBoostDeviation(window, anomalies);

      // 9. Ecology Tamper Check (Wykrywanie wyprogramowanego DPF / EGR)
      _checkEcologyTampering(window, anomalies);
    }

    // 10. Badanie Leniwej Sondy Lambda (Wąskopasmowa) - na pełnej sesji
    _checkNarrowbandO2Health(points, anomalies);

    // 11. Badanie Odcięcia Paliwa AFR (Szerokopasmowa) - na pełnej sesji
    _checkWidebandAfrResponse(points, anomalies);

    // 12. Krzyżowa Analiza Wypadania Zapłonów (Misfire Profiler) - na pełnej sesji
    _checkMisfireRootCause(points, anomalies);

    // 7. Analiza ciśnienia na listwie wysokiego ciśnienia (TSI / HPFP / Błąd P0087)
    _checkFuelRailPressure(points, anomalies);

    // 8. Analiza falowania obrotów i drgań na biegu jałowym (np. Peugeot 2.0 / EVAP / MAP)
    _checkIdleHunting(points, anomalies);

    // 9. Analiza zacięcia zmiennych faz rozrządu VVT / utraty podciśnienia w kolektorze (P0011)
    _checkVvtJamming(points, anomalies);

    return anomalies;
  }

  /// Wykrywa okna czasowe, w których kierowca wcisnął gaz do dechy (WOT)
  static List<List<LogPoint>> _detectWotWindows(List<LogPoint> points) {
    final List<List<LogPoint>> windows = [];
    List<LogPoint> currentWindow = [];

    for (final p in points) {
      final isWot = p.tps >= 80.0 || (p.tps == 0 && p.load >= 75.0);
      if (isWot) {
        currentWindow.add(p);
      } else {
        if (currentWindow.length >= 6) {
          final durationMs = currentWindow.last.timeMs - currentWindow.first.timeMs;
          final rpmGain = currentWindow.last.rpm - currentWindow.first.rpm;
          if (durationMs >= 1200 && rpmGain >= 1000) {
            windows.add(List.from(currentWindow));
          }
        }
        currentWindow.clear();
      }
    }

    if (currentWindow.length >= 6) {
      final durationMs = currentWindow.last.timeMs - currentWindow.first.timeMs;
      final rpmGain = currentWindow.last.rpm - currentWindow.first.rpm;
      if (durationMs >= 1200 && rpmGain >= 1000) {
        windows.add(List.from(currentWindow));
      }
    }

    return windows;
  }

  /// Sprawdza nagłe cofnięcia kąta wyprzedzenia zapłonu (Knock retard)
  static void _checkTimingRetard(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("IGN"))) return;

    double maxTimingSeen = -999;
    LogPoint? dipStart;
    double minDipVal = 999;

    for (int i = 1; i < points.length; i++) {
      final p = points[i];
      final prev = points[i - 1];
      final ign = p.ign;

      if (ign > maxTimingSeen) {
        maxTimingSeen = ign;
      }

      // Nagły spadek kąta wyprzedzenia zapłonu przy rosnących obrotach (> 3.0° drop)
      final dropFromPeak = maxTimingSeen - ign;
      final stepDrop = prev.ign - ign;

      if ((dropFromPeak >= 3.5 || stepDrop >= 2.5) && p.rpm >= 2500) {
        dipStart ??= prev;
        if (ign < minDipVal) minDipVal = ign;
      } else if (dipStart != null) {
        // Koniec spadku
        final durationMs = p.timeMs - dipStart.timeMs;
        if (durationMs >= 200) {
          final isCritical = (maxTimingSeen - minDipVal) >= 5.5 || minDipVal < 2.0;
          anomalies.add(Anomaly(
            id: "ign_${dipStart.timeMs.toInt()}",
            title: "Cofanie zapłonu (Spalanie stukowe / Knock)",
            severity: isCritical ? AnomalySeverity.critical : AnomalySeverity.warning,
            paramKey: "IGN",
            startMs: dipStart.timeMs,
            endMs: p.timeMs,
            startRpm: dipStart.rpm,
            endRpm: p.rpm,
            observedValueText: "Spadek z ${maxTimingSeen.toStringAsFixed(1)}° do ${minDipVal.toStringAsFixed(1)}° (Cofnięcie o -${(maxTimingSeen - minDipVal).toStringAsFixed(1)}°)",
            primarySymptom: "ECU gwałtownie cofa kąt wyprzedzenia zapłonu pod pełnym obciążeniem (${dipStart.rpm.toInt()} - ${p.rpm.toInt()} RPM)",
            correlatedSignals: {
              "IGN": "Cofnięcie o -${(maxTimingSeen - minDipVal).toStringAsFixed(1)}°",
              "IAT": "${p.iat.toStringAsFixed(0)} °C ${p.iat > 52 ? '(PRZEGRZANY DOLOT - ryzyko samozapłonu!)' : '(temperatura w normie)'}",
              "AFR": "${p.afr.toStringAsFixed(1)}:1 ${p.afr > 12.8 ? '(za ubogo pod doładowaniem)' : '(mieszanka prawidłowa)'}",
              "BOOST": "${p.boost.toStringAsFixed(2)} bar",
              "TPS": "${p.tps.toInt()}%",
            },
            falseLeadWarning: "UWAGA NA FAŁSZYWY TROP: Kod błędu czujnika spalania stukowego (Knock Sensor) NIE oznacza, że czujnik jest uszkodzony! Czujnik stuku działa prawidłowo i ratuje tłoki przed stopieniem. Wymiana czujnika stuku nie usunie przyczyny stukania!",
            ruledOutCauses: [
              "Wykluczono awarię czujnika stuku – czujnik dynamicznie reaguje na przeciążenie silnika",
              if (p.iat < 45) "Wykluczono przegrzanie dolotu (IAT = ${p.iat.toStringAsFixed(0)}°C w normie)",
              if (p.afr < 12.2) "Wykluczono zubożenie mieszanki (AFR = ${p.afr.toStringAsFixed(1)}:1 w bezpiecznym zakresie)",
            ],
            rootCauseConclusion: p.iat > 52
                ? "Główną przyczyną cofania zapłonu jest zbyt wysoka temperatura w dolocie (IAT = ${p.iat.toStringAsFixed(0)}°C). Gorące powietrze sprzyja samozapłonom stukowym."
                : "Spalanie stukowe wynika najprawdopodobniej ze zbyt niskiej liczby oktanowej paliwa, przegrzania komory spalania przez nagar lub zużycia świec zapłonowych.",
            description: "Sterownik silnika gwałtownie cofnął kąt wyprzedzenia zapłonu w zakresie ${dipStart.rpm.toInt()} - ${p.rpm.toInt()} RPM. Oznacza to, że czujnik spalania stukowego zarejestrował stukanie w cylindrach.",
            hypotheses: [
              "Zbyt niska liczba oktanowa paliwa (np. wlane PB95 zamiast wymaganej PB98/100)",
              "Zużyte świece zapłonowe (wypalone elektrody, niewłaściwa przerwa)",
              "Niesprawna cewka zapłonowa lub kable wysokiego napięcia",
              "Za wysoka temperatura powietrza w dolocie (niewydajny intercooler)",
              "Nagromadzony nagar w komorach spalania powodujący samozapłon",
            ],
            recommendations: [
              "Zatankuj świeże paliwo 98 lub 100 oktanów na sprawdzonej stacji i powtórz log.",
              "Wykręć świece i skontroluj ich stan oraz przerwę na elektrodach.",
              "Sprawdź temperaturę w dolocie (IAT) oraz układ chłodzenia.",
              "Jeśli auto jest po chiptuningu, poinformuj tunera o cofaniu zapłonu.",
            ],
          ));
        }
        dipStart = null;
        maxTimingSeen = ign;
        minDipVal = 999;
      }
    }
  }

  /// Sprawdza nieszczelności doładowania (nagły spadek ciśnienia)
  static void _checkBoostLeaks(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("BOOST"))) return;

    double peakBoost = 0;
    LogPoint? leakStart;
    double lowestBoostAfterPeak = 999;

    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      final boost = p.boost;

      if (boost > peakBoost) {
        peakBoost = boost;
      }

      // Jeśli mieliśmy już doładowanie > 0.8 bar, a nagle spada o > 0.35 bar przy pełnym gazie
      if (peakBoost >= 0.8 && (peakBoost - boost) >= 0.35 && p.rpm >= 2800 && p.rpm <= 6200) {
        leakStart ??= points[max(0, i - 1)];
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
      }
    }
  }

  /// Porównuje zadane ciśnienie doładowania (Target Boost) z rzeczywistym (Actual Boost)
  static void _checkBoostDeviation(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("BOOST")) || !points.any((p) => p.values.containsKey("TARGET_BOOST"))) {
      return;
    }

    // Szukamy momentów pełnego obciążenia
    final wotPoints = points.where((p) => p.tps >= 80 || p.load >= 80).toList();
    if (wotPoints.length < 10) return;

    double maxDeviation = 0;
    LogPoint? worstDeviationPoint;
    bool isOverboost = false;

    for (final p in wotPoints) {
      final actual = p.boost;
      final target = p.values["TARGET_BOOST"]!;
      
      // Sprawdzamy tylko gdy sterownik oczekuje przynajmniej 0.4 bar doładowania
      if (target > 0.4) {
        final deviation = actual - target;
        if (deviation.abs() > maxDeviation.abs()) {
          maxDeviation = deviation;
          worstDeviationPoint = p;
        }
      }
    }

    if (worstDeviationPoint != null && maxDeviation.abs() >= 0.35) { // Odchyłka co najmniej 0.35 bar
      isOverboost = maxDeviation > 0;
      final targetStr = worstDeviationPoint.values["TARGET_BOOST"]!.toStringAsFixed(2);
      final actualStr = worstDeviationPoint.boost.toStringAsFixed(2);
      final diffStr = maxDeviation.abs().toStringAsFixed(2);

      anomalies.add(Anomaly(
        id: "boost_dev_${worstDeviationPoint.timeMs.toInt()}",
        title: isOverboost 
            ? "Przeładowanie (Overboost) - Przekroczenie ciśnienia zadanego"
            : "Niedoładowanie (Underboost) - Znaczny brak zadanego ciśnienia",
        severity: AnomalySeverity.critical,
        paramKey: "BOOST",
        startMs: wotPoints.first.timeMs,
        endMs: wotPoints.last.timeMs,
        startRpm: wotPoints.first.rpm,
        endRpm: wotPoints.last.rpm,
        observedValueText: "Oczekiwane: $targetStr bar | Rzeczywiste: $actualStr bar (Różnica: $diffStr bar)",
        description: isOverboost 
            ? "Turbosprężarka pompuje o $diffStr bar WIĘCEJ niż żąda tego sterownik silnika. Może to doprowadzić do wybuchu rozerwania węży (boost leak) lub w ostateczności uszkodzenia silnika (np. urwanie korbowodu). Sterownik wejdzie w tryb awaryjny."
            : "Silnik żąda $targetStr bar ciśnienia, ale układ jest w stanie wygenerować jedynie $actualStr bar. Brakuje aż $diffStr bar do zadanej mocy.",
        hypotheses: isOverboost 
            ? [
                "Zacięta geometria VNT w turbosprężarce (zapiekła się w pozycji zamkniętej)",
                "Uszkodzony lub źle wpięty zawór N75 sterujący podciśnieniem turbiny",
                "Pęknięty wężyk idący do gruszki wastegate (turbina ładuje na maksa, brak upustu)",
              ]
            : [
                "Nieszczelność układu dolotowego (dziura w wężu lub intercoolerze)",
                "Zacięta geometria VNT w pozycji otwartej (brak zdolności do spoolu)",
                "Brak wysterowania z zaworu N75 lub dziurawy wężyk podciśnienia sterującego gruszką",
                "Znaczne ograniczenie przepływu spalin (np. zapchany DPF/Katalizator)",
              ],
        recommendations: [
          "Sprawdź wężyki podciśnienia sterujące zmienną geometrią (VNT) lub zaworem wastegate.",
          "Wykonaj log statyczny zaworu N75 (wysterowanie w % vs ciśnienie).",
          if (!isOverboost) "Zrób próbę szczelności dolotu, pompując w niego sprężone powietrze.",
        ],
      ));
    }
  }

  /// Moduł "Ecology Tamper Check": Wykrywa usunięcie fizyczne lub programowe DPF / EGR
  static void _checkEcologyTampering(List<LogPoint> points, List<Anomaly> anomalies) {
    if (points.length < 20) return;

    // 1. Sprawdzenie zamrożonego DPF (Wyprogramowanie w ECU lub emulator)
    if (points.any((p) => p.values.containsKey("DPF_DP"))) {
      final dpfPoints = points.where((p) => p.values.containsKey("DPF_DP")).toList();
      if (dpfPoints.length > 20) {
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
    if (points.any((p) => p.values.containsKey("EGR_CMD"))) {
      final egrPoints = points.where((p) => p.values.containsKey("EGR_CMD")).toList();
      
      // Detekcja Software Delete (Zawsze 0%)
      bool isSoftwareDeleted = true;
      for (final p in egrPoints) {
        if (p.values["EGR_CMD"]! > 0.0) {
          isSoftwareDeleted = false;
          break;
        }
      }

      if (isSoftwareDeleted && egrPoints.length > 50) {
        anomalies.add(Anomaly(
          id: "egr_software_delete_${egrPoints.first.timeMs.toInt()}",
          title: "Wykryto Programowe Wyłączenie EGR",
          severity: AnomalySeverity.tampering,
          paramKey: "EGR_CMD",
          startMs: egrPoints.first.timeMs,
          endMs: egrPoints.last.timeMs,
          startRpm: egrPoints.first.rpm,
          endRpm: egrPoints.last.rpm,
          observedValueText: "Zadane otwarcie EGR (EGR_CMD) przez 100% czasu trwania logu wynosi 0.0%.",
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

  /// Sprawdza czy sonda wąskopasmowa nie jest "leniwa" na podstawie liczby skoków napięcia (Cross-Counts)
  static void _checkNarrowbandO2Health(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("O2_V"))) return;

    // Badamy tylko przy stałym, lekkim obciążeniu (TPS między 5 a 25), RPM > 1500
    final steadyPoints = points.where((p) => 
      p.values.containsKey("O2_V") &&
      p.values.containsKey("TPS") &&
      p.values["TPS"]! > 5 && p.values["TPS"]! < 25 &&
      p.rpm > 1500 && p.rpm < 3000
    ).toList();

    if (steadyPoints.length < 50) return; // Za mało danych ze stałej jazdy

    int crossCounts = 0;
    bool? wasRich;

    for (final p in steadyPoints) {
      final v = p.values["O2_V"]!;
      final isRich = v > 0.45;

      if (wasRich != null && wasRich != isRich) {
        crossCounts++;
      }
      wasRich = isRich;
    }

    final durationSec = (steadyPoints.last.timeMs - steadyPoints.first.timeMs) / 1000.0;
    final crossRate = crossCounts / durationSec;

    // Zdrowa sonda powinna przecinać 0.45V co najmniej 1 raz na sekundę podczas stałej jazdy
    if (durationSec > 5.0 && crossRate < 0.5) {
      anomalies.add(Anomaly(
        id: "lazy_o2_${steadyPoints.first.timeMs.toInt()}",
        title: "Leniwa Sonda Lambda (O2)",
        severity: AnomalySeverity.warning,
        paramKey: "O2_V",
        startMs: steadyPoints.first.timeMs,
        endMs: steadyPoints.last.timeMs,
        startRpm: steadyPoints.first.rpm,
        endRpm: steadyPoints.last.rpm,
        observedValueText: "Zaledwie $crossCounts skoków w ciągu ${durationSec.toStringAsFixed(1)}s (Oczekiwano > ${(durationSec * 1.0).toInt()})",
        description: "Sonda tlenu (wąskopasmowa) oscyluje zbyt wolno. Zamiast płynnie i szybko przeskakiwać między mieszanką bogatą a ubogą, napięcie zawiesza się. Może to prowadzić do zwiększonego spalania i złych korekt paliwowych.",
        hypotheses: [
          "Sonda uległa naturalnemu zużyciu (starzenie chemiczne).",
          "Zabrudzenie sondy nagarem / sadzą lub olejem.",
        ],
        recommendations: [
          "Zalecana wymiana przedniej sondy lambda przed podjęciem naprawy katalizatora.",
        ],
      ));
    }
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

  /// Analizuje brak budowania doładowania i koreluje go z układem wydechowym (DPF / GPF / Przeciwciśnienie)
  static void _checkUnderboostAndDpfCorrelation(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("BOOST"))) return;

    // Szukamy okien pełnego buta (WOT) w średnim/wyższym zakresie obrotów
    final wotPoints = points.where((p) => (p.tps >= 75 || p.load >= 75) && p.rpm >= 2200 && p.rpm <= 5200).toList();
    if (wotPoints.length < 10) return;

    final maxBoost = wotPoints.map((p) => p.boost).reduce(max);

    // Jeśli pod pełnym butem turbo ledwo dmucha (< 0.55 bar)
    if (maxBoost < 0.55) {
      final worstPoint = wotPoints.firstWhere((p) => p.boost == maxBoost);
      final hasDpf = points.any((p) => p.values.containsKey("DPF_DP"));
      final maxDpfDp = hasDpf ? wotPoints.map((p) => p.dpfDp).reduce(max) : 0.0;
      final maxSoot = points.any((p) => p.values.containsKey("DPF_SOOT"))
          ? wotPoints.map((p) => p.dpfSoot).reduce(max)
          : 0.0;
      final maxEgt = points.any((p) => p.values.containsKey("EGT"))
          ? wotPoints.map((p) => p.egt).reduce(max)
          : 0.0;

      if (maxDpfDp >= 25.0 || maxSoot >= 75.0) {
        // Scenariusz: Dławienie wirnika turbiny przez zapchany DPF/GPF
        anomalies.add(Anomaly(
          id: "dpf_underboost_${worstPoint.timeMs.toInt()}",
          title: "Brak doładowania z powodu zapchanego DPF/GPF (Dławienie wirnika spalinami)",
          severity: AnomalySeverity.critical,
          paramKey: "DPF_DP",
          startMs: wotPoints.first.timeMs,
          endMs: wotPoints.last.timeMs,
          startRpm: wotPoints.first.rpm,
          endRpm: wotPoints.last.rpm,
          observedValueText: "Różnica ciśnień DPF: ${maxDpfDp.toStringAsFixed(1)} kPa (Norma: < 15 kPa) | Doładowanie: ${maxBoost.toStringAsFixed(2)} bar (Wymagane: 1.40 bar)",
          primarySymptom: "Turbosprężarka nie buduje ciśnienia (maks. ${maxBoost.toStringAsFixed(2)} bar) mimo pełnego otwarcia przepustnicy (TPS ${worstPoint.tps.toInt()}%)",
          correlatedSignals: {
            "DPF_DP": "${maxDpfDp.toStringAsFixed(1)} kPa (ekstremalne przeciwciśnienie, wydech zatkany)",
            "DPF_SOOT": maxSoot > 0 ? "${maxSoot.toStringAsFixed(0)}%" : "Niedostępne",
            "BOOST": "${maxBoost.toStringAsFixed(2)} bar (drastyczny brak ciśnienia)",
            "EGT": maxEgt > 0 ? "${maxEgt.toStringAsFixed(0)} °C (wysoka temp. dławionych spalin)" : "Brak odczytu",
            "TPS": "${worstPoint.tps.toInt()}%",
          },
          falseLeadWarning: "UWAGA NA KOSZTOWNY BŁĄD: Sterownik silnika zapisze kod P0299 (Niedoładowanie). Warsztaty w ciemno wymieniają turbosprężarkę za 2500–4000 zł! Sama turbina jest w 100% SPRAWNA – nie może wejść na obroty, bo spaliny są zablokowane jak korkiem w zapchanym filtrze cząstek stałych!",
          ruledOutCauses: [
            "Wykluczono uszkodzenie mechaniczne wirnika kompresora – brak ciśnienia wynika z braku przepływu spalin na wirniku gorącym",
            "Wykluczono nieszczelność rurociągu dolotu (brak dźwięku uciekającego ciśnienia)",
            "Wykluczono zacięcie geometrii VNT w pozycji otwartej jako pierwotną przyczynę",
          ],
          rootCauseConclusion: "Filtr cząstek stałych (DPF / GPF) jest skrajnie niedrożny (różnica ciśnień ${maxDpfDp.toStringAsFixed(1)} kPa). Zgodnie z fizyką przepływów, turbosprężarka potrzebuje spadku ciśnienia PRZED i ZA wirnikiem spalinowym, aby wirnik mógł się rozpędzić do 150 000+ obr/min. Zapchany filtr tworzy poduszkę gazową (przeciwciśnienie), która skutecznie hamuje wirnik turbiny i blokuje doładowanie.",
          description: "Wykryto krytyczną zależność przyczynowo-skutkową: turbosprężarka nie buduje ciśnienia, ponieważ filtr cząstek stałych DPF/GPF generuje potężne przeciwciśnienie (${maxDpfDp.toStringAsFixed(1)} kPa). Silnik jest dosłownie dławiony własnymi spalinami.",
          hypotheses: [
            "Przepełniony filtr DPF/GPF sadzą i popiołem olejowym (brak warunków do regeneracji pasywnej)",
            "Uszkodzony termostat uniemożliwiający wejście w procedurę wypalania DPF (silnik niedogrzany)",
            "Stopione lub zapchane sadzą przewody impulsowe czujnika różnicy ciśnień",
            "Lejący wtryskiwacz paliwa powodujący lawinowe zapychanie filtra cząstek stałych",
          ],
          recommendations: [
            "NIE WYMIENIAJ TURBOSPRĘŻARKI!",
            "Odczytaj kody błędów – szukaj P2463 (Soot Accumulation) oraz P2452 (Pressure Sensor).",
            "Sprawdź temperaturę płynu chłodzącego (ECT) – jeśli auto ma poniżej 82°C w trasie, wymień termostat, aby DPF mógł się wypalić.",
            "Zleć profesjonalne czyszczenie hydrodynamiczne wkładu DPF lub wymuszoną regenerację serwisową.",
            "Skontroluj drożność metalowych i gumowych rurek łączących wydech z czujnikiem różnicy ciśnień.",
          ],
        ));
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

    final iatStart = points.first.iat;
    final iatEnd = points.last.iat;
    final iatMax = points.map((p) => p.iat).reduce(max);

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

  /// Sprawdza anomalie korekt paliwowych (STFT / LTFT)
  static void _checkFuelTrims(List<LogPoint> points, List<Anomaly> anomalies) {
    final hasStft = points.any((p) => p.values.containsKey("STFT"));
    final hasLtft = points.any((p) => p.values.containsKey("LTFT"));
    if (!hasStft && !hasLtft) return;

    for (final p in points) {
      final totalTrim = p.stft + p.ltft;
      if (totalTrim > 18.0) {
        anomalies.add(Anomaly(
          id: "trim_pos_${p.timeMs.toInt()}",
          title: "Bardzo wysokie dodatnie korekty paliwa (Zubożenie mieszanki)",
          severity: AnomalySeverity.warning,
          paramKey: "STFT",
          startMs: p.timeMs,
          endMs: p.timeMs + 1000,
          startRpm: p.rpm,
          endRpm: p.rpm,
          observedValueText: "Korekty łączne: +${totalTrim.toStringAsFixed(1)}%",
          description: "Sterownik ECU musi mocno dolewać paliwa (+${totalTrim.toStringAsFixed(1)}%), ponieważ rejestruje nadmiar tlenu w spalinach.",
          hypotheses: [
            "Nieszczelność podciśnienia w kolektorze ssącym (lewe powietrze)",
            "Nieszczelna odma olejowa lub uszkodzony zawór PCV",
            "Niskie ciśnienie paliwa lub przypchane wtryskiwacze",
          ],
          recommendations: [
            "Wykonaj próbę dymową podciśnień.",
            "Sprawdź zawór PCV i węże odpowietrzenia skrzyni korbowej.",
          ],
        ));
        break;
      } else if (totalTrim < -18.0) {
        anomalies.add(Anomaly(
          id: "trim_neg_${p.timeMs.toInt()}",
          title: "Bardzo wysokie ujemne korekty paliwa (Przelanie mieszanki)",
          severity: AnomalySeverity.warning,
          paramKey: "STFT",
          startMs: p.timeMs,
          endMs: p.timeMs + 1000,
          startRpm: p.rpm,
          endRpm: p.rpm,
          observedValueText: "Korekty łączne: ${totalTrim.toStringAsFixed(1)}%",
          description: "Sterownik ECU mocno odejmuje paliwo (${totalTrim.toStringAsFixed(1)}%), ponieważ mieszanka jest zbyt bogata.",
          hypotheses: [
            "Nieszczelny, lejący wtryskiwacz paliwa",
            "Uszkodzony lub stale otwarty elektrozawór odpowietrzania oparów paliwa (EVAP)",
            "Zbyt wysokie ciśnienie paliwa (uszkodzony regulator)",
          ],
          recommendations: [
            "Sprawdź szczelność wtryskiwaczy na stole probierczym.",
            "Odłącz zawór EVAP i sprawdź, czy korekty wrócą do normy.",
          ],
        ));
        break;
      }
    }
  }

  /// Sprawdza ciśnienie na szynie paliwowej (Bieg jałowy i obciążenie TSI / DI - Błąd P0087)
  static void _checkFuelRailPressure(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("F_RAIL"))) return;

    // Sprawdzenie na niskich obrotach / biegu jałowym (obroty < 2200 RPM lub TPS < 25%)
    final lowRpmPoints = points.where((p) => p.rpm <= 2200 || p.tps <= 25).toList();
    if (lowRpmPoints.isNotEmpty) {
      final minPressure = lowRpmPoints.map((p) => p.values["F_RAIL"]!).reduce(min);
      if (minPressure < 28.0) {
        final badPoint = lowRpmPoints.firstWhere((p) => p.values["F_RAIL"]! == minPressure);
        anomalies.add(Anomaly(
          id: "rail_low_${badPoint.timeMs.toInt()}",
          title: "Zbyt niskie ciśnienie paliwa na listwie (Błąd P0087 / Lejący wtrysk)",
          severity: AnomalySeverity.critical,
          paramKey: "F_RAIL",
          startMs: lowRpmPoints.first.timeMs,
          endMs: lowRpmPoints.last.timeMs,
          startRpm: lowRpmPoints.first.rpm,
          endRpm: lowRpmPoints.last.rpm,
          observedValueText: "Ciśnienie listwy: ${minPressure.toStringAsFixed(1)} bar (Norma: 35.0 - 50.0 bar)",
          primarySymptom: "Krytyczny spadek ciśnienia paliwa do ${minPressure.toStringAsFixed(1)} bar na niskich obrotach / biegu jałowym",
          correlatedSignals: {
            "F_RAIL": "${minPressure.toStringAsFixed(1)} bar (wymagane min. 35-50 bar)",
            "STFT": "${badPoint.stft.toStringAsFixed(1)}% ${badPoint.stft < -15 ? '(ECU drastycznie ucina paliwo - zalewanie!)' : ''}",
            "RPM": "${badPoint.rpm.toInt()} obr/min",
            "TPS": "${badPoint.tps.toInt()}%",
          },
          falseLeadWarning: "UWAGA NA KOSZTOWNY BŁĄD: Błąd P0087 w 70% przypadków skłania warsztaty do kosztownej wymiany pompy wysokiego ciśnienia HPFP (1500–2500 zł). W silnikach TSI pompa często jest w pełni sprawna – to nieszczelny wtryskiwacz na 1. cylindrze puszcza paliwo i rozładowuje szynę prosto do cylindra!",
          ruledOutCauses: [
            "Wykluczono pompę w baku (LPFP) – pod obciążeniem i na wysokich obrotach ciśnienie rośnie prawidłowo",
            "Wykluczono zawór EVAP – spadek ciśnienia zachodzi bezpośrednio w akumulatorze szyny HPFP",
          ],
          rootCauseConclusion: badPoint.stft < -15
              ? "Jednoczesny spadek ciśnienia szyny rail (${minPressure.toStringAsFixed(1)} bar) i mocno ujemna korekta paliwa (STFT ${badPoint.stft.toStringAsFixed(1)}%) jednoznacznie potwierdzają wyciek paliwa przez iglicę wtryskiwacza na 1. cylindrze."
              : "Spadek ciśnienia spoczynkowego na listwie wysokiego ciśnienia. Sprawdź szczelność wtryskiwaczy bezpośrednich oraz popychacz szklankowy pompy HPFP.",
          description: "W silniku z wtryskiem bezpośrednim (TSI, TFSI, GDI, dCi, CRDI) ciśnienie spoczynkowe na szynie paliwowej (HPFP/Common Rail) na wolnych obrotach powinno wynosić minimum 35-50 bar (lub więcej w dieslach). Spadek do ${minPressure.toStringAsFixed(1)} bar generuje błąd P0087 i wskazuje na niekontrolowany wyciek paliwa z szyny lub niesprawność pompy.",
          hypotheses: [
            "Nieszczelny / lejący wtryskiwacz na 1. cylindrze – iglica wtrysku nie domyka się i paliwo ucieka do komory spalania, powodując spadek ciśnienia spoczynkowego na listwie",
            "Zużycie mechanicznej pompy wysokiego ciśnienia (HPFP) lub wytarty popychacz (szklanka) na wałku rozrządu",
            "Nieszczelność wewnętrzna zaworu regulacji ciśnienia N276 na pompie HPFP",
            "Spadek ciśnienia wstępnego z pompy w baku (LPFP) lub zapchany filtr paliwa",
          ],
          recommendations: [
            "Wykręć świecę na 1. cylindrze po postoju – jeśli czuć silny zapach benzyny lub świeca jest mokra/czarna, wtrysk #1 leje.",
            "Sprawdź korektę dawki na 1. cylindrze – lejący wtrysk powoduje mocno ujemną korektę w ECU.",
            "Pilnie skontroluj stan i poziom oleju silnikowego – czy nie pachnie benzyną (lejący wtryskiwacz rozcieńcza olej, grożąc zatarciem panewek!).",
            "Zdemontuj pompę wysokiego ciśnienia HPFP i skontroluj popychacz szklankowy pod kątem przetarcia.",
          ],
        ));
      }
    }
  }

  /// Sprawdza falowanie obrotów i drgania na biegu jałowym (np. Peugeot 2.0 16V EW10)
  static void _checkIdleHunting(List<LogPoint> points, List<Anomaly> anomalies) {
    final idlePoints = points.where((p) => p.tps <= 10 && p.rpm < 1400).toList();
    if (idlePoints.length < 15) return;

    final rpms = idlePoints.map((p) => p.rpm).toList();
    final minRpm = rpms.reduce(min);
    final maxRpm = rpms.reduce(max);
    final rpmDelta = maxRpm - minRpm;

    // Jeśli obroty na jałowym skaczą o więcej niż 220 RPM
    if (rpmDelta >= 220) {
      final worstPoint = idlePoints.firstWhere((p) => p.rpm == minRpm);
      final minStft = idlePoints.map((p) => p.stft).reduce(min);
      final maxStft = idlePoints.map((p) => p.stft).reduce(max);
      final worstBoost = idlePoints.map((p) => p.boost).reduce(max);

      final isEvapSuspect = minStft <= -15.0;
      final isVacuumLeakSuspect = maxStft >= 15.0 && worstBoost >= -0.45;
      final isVvtSuspect = worstBoost >= -0.42 && minStft >= -8.0 && maxStft <= 8.0;

      String title = "Silne falowanie obrotów na biegu jałowym (Drżenie silnika / Rough Idle)";
      String conclusion = "Niestabilność biegu jałowego wynika z zaburzenia bilansu paliwowo-powietrznego na wolnych obrotach.";
      String falseLead = "UWAGA: Częsta wymiana silniczka krokowego lub przepustnicy w ciemno nie usuwa przyczyny, jeśli problem tkwi w podciśnieniu lub mieszance!";
      List<String> ruledOut = [];

      if (isEvapSuspect) {
        title = "Falowanie i drżenie przez zacięty zawór EVAP (Zalewanie oparami paliwa)";
        conclusion = "Mocno ujemne korekty paliwowe (STFT ${minStft.toStringAsFixed(1)}%) przy zamkniętej przepustnicy świadczą o zasysaniu niesterowanych par benzyny ze zbiornika przez otwarty elektrozawór EVAP.";
        falseLead = "UWAGA NA BŁĄD: Błąd P0172 sugeruje uszkodzenie sondy lambda. Sonda jest sprawna – prawidłowo informuje ECU o zalewaniu silnika oparami!";
        ruledOut = [
          "Wykluczono zacięcie VVT – wariator nie powoduje silnego przelewania mieszanki do -20% STFT",
          "Wykluczono lewe powietrze – przy nieszczelności korekty byłyby mocno dodatnie (+20%)",
        ];
      } else if (isVacuumLeakSuspect) {
        title = "Falowanie obrotów przez lewe powietrze (Nieszczelność kolektora dolotowego)";
        conclusion = "Mocno dodatnie korekty paliwowe (+${maxStft.toStringAsFixed(1)}%) przy słabym podciśnieniu wskazują na nieszczelność uszczelek kolektora lub pęknięty przewód serwa hamulcowego.";
        falseLead = "UWAGA NA BŁĄD: Kod P0171 (Mieszanka za uboga) często prowadzi do błędnej wymiany sondy lambda lub pompy paliwa. Winna jest dziura w podciśnieniu!";
        ruledOut = [
          "Wykluczono zacięcie zaworu EVAP – zawór EVAP powoduje zalewanie, a nie zubożenie",
          "Wykluczono uszkodzenie wtryskiwaczy",
        ];
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
        observedValueText: "Falowanie w zakresie ${minRpm.toInt()} - ${maxRpm.toInt()} RPM (Skok o ${rpmDelta.toInt()} obr/min)",
        primarySymptom: "Silnik kuleje, faluje i drży na biegu jałowym (${minRpm.toInt()} - ${maxRpm.toInt()} RPM), uspokaja się po przegazówce ('przepaleniu')",
        correlatedSignals: {
          "RPM": "Skoki o ${rpmDelta.toInt()} obr/min",
          "BOOST": "${worstBoost.toStringAsFixed(2)} bar ${worstBoost >= -0.45 ? '(słabe podciśnienie)' : '(podciśnienie w normie)'}",
          "STFT": "${minStft.toStringAsFixed(1)}% do ${maxStft.toStringAsFixed(1)}%",
          "TPS": "${worstPoint.tps.toInt()}% (przepustnica zamknięta)",
        },
        falseLeadWarning: falseLead,
        ruledOutCauses: ruledOut,
        rootCauseConclusion: conclusion,
        description: "Na biegu jałowym zarejestrowano niestabilną pracę i szarpanie obrotami. Silnik kuleje, po czym po dodaniu gazu ('przepaleniu') chwilowo się uspokaja.",
        hypotheses: [
          "Zawieszony / nieszczelny elektrozawór pochłaniacza par paliwa EVAP – silnik na wolnych obrotach zaciąga opary benzyny z baku, dusi się i zalewa, a po przegazówce ('przepaleniu') nadmiar oparów zostaje przedmuchany",
          "Zabrudzona nagarem przepustnica lub zaolejony czujnik ciśnienia w kolektorze MAP (brak przepływomierza w silnikach EW10)",
          "Przebicie iskry na zintegrowanej kasecie cewek zapłonowych (Sagem/Valeo) – typowa wada silników 2.0 EW10 (przebicie do głowicy na wolnych obrotach)",
          "Przycinający się elektrozawór zmiennych faz rozrządu VVT – po przygazowaniu wyższe ciśnienie oleju 'odwiesza' wariator",
          "Podwieszające się popychacze hydrauliczne zaworów (tzw. szklanki) powodujące okresową utratę kompresji na wolnych obrotach",
        ],
        recommendations: [
          "Zdejmij wężyk od elektrozaworu EVAP idący do kolektora ssącego i zaślep go na próbę – jeśli silnik przestanie falować, zawór EVAP jest zacięty!",
          "Wykręć i wyczyść zmywaczem czujnik MAP w kolektorze ssącym oraz wymyj nagar z przepustnicy.",
          "Obejrzyj listwę cewek zapłonowych pod kątem mikropęknięć i białych śladów przebicia iskry.",
          "Wymień świece zapłonowe (zbyt duża przerwa przyspiesza padanie cewki).",
          "W silnikach ze zmiennymi fazami (EW10A 140KM) wyczyść sitko elektrozaworu VVT.",
        ],
      ));
    }
  }

  /// Sprawdza objawy zacięcia zmiennych faz rozrządu VVT (błąd P0011 / drastyczny spadek podciśnienia w kolektorze MAP)
  static void _checkVvtJamming(List<LogPoint> points, List<Anomaly> anomalies) {
    if (!points.any((p) => p.values.containsKey("BOOST"))) return;

    // Szukamy punktów na biegu jałowym (zamknięta przepustnica, obroty < 1300 RPM)
    final idlePoints = points.where((p) => p.tps <= 8 && p.rpm >= 550 && p.rpm <= 1300).toList();
    if (idlePoints.length < 10) return;

    // Normalne podciśnienie na jałowym w sprawnym silniku to -0.60 do -0.75 bar (MAP 25-40 kPa).
    // Gdy wariator VVT zatnie się w pozycji przyspieszonej, zawory ssące otwierają się za wcześnie
    // (współotwarcie z wydechem) - spaliny cofają się w dolot i podciśnienie drastycznie ZANIKA (boost > -0.42 bar, MAP > 58-70 kPa).
    final vvtJammedPoints = idlePoints.where((p) => p.boost >= -0.42 && p.stft >= -12.0 && p.stft <= 12.0).toList();

    if (vvtJammedPoints.length >= 8) {
      final worstPoint = vvtJammedPoints.reduce((a, b) => a.boost > b.boost ? a : b);
      anomalies.add(Anomaly(
        id: "vvt_jammed_${vvtJammedPoints.first.timeMs.toInt()}",
        title: "Podejrzenie zacięcia zmiennych faz rozrządu VVT (Błąd P0011 / Zanik podciśnienia)",
        severity: AnomalySeverity.critical,
        paramKey: "BOOST",
        startMs: vvtJammedPoints.first.timeMs,
        endMs: vvtJammedPoints.last.timeMs,
        startRpm: vvtJammedPoints.first.rpm,
        endRpm: vvtJammedPoints.last.rpm,
        observedValueText: "Podciśnienie spadło do ${worstPoint.boost.toStringAsFixed(2)} bar (Norma: -0.65 do -0.75 bar)",
        primarySymptom: "Gwałtowny zanik podciśnienia w kolektorze ssącym (${worstPoint.boost.toStringAsFixed(2)} bar) przy zamkniętej przepustnicy (0%)",
        correlatedSignals: {
          "BOOST": "${worstPoint.boost.toStringAsFixed(2)} bar (spadek podciśnienia, MAP > 620 mbar)",
          "TPS": "${worstPoint.tps.toInt()}% (przepustnica w 100% zamknięta)",
          "STFT": "${worstPoint.stft.toStringAsFixed(1)}% (korekta neutralna)",
          "RPM": "${worstPoint.rpm.toInt()} obr/min (drżenie i falowanie silnika)",
        },
        falseLeadWarning: "UWAGA NA FAŁSZYWY TROP: Kod błędu P0106 (Sygnał MAP nielogiczny) lub P0300 (Wypadanie zapłonów). Wielu mechaników niepotrzebnie wymienia czujnik MAP lub cewki zapłonowe. Czujnik MAP mierzy prawdę – podciśnienie zniknęło, bo zacięty wariator VVT cofa spaliny w kolektor dolotowy!",
        ruledOutCauses: [
          "Wykluczono uszkodzenie czujnika MAP – mierzy rzeczywisty napływ spalin z zaworów",
          "Wykluczono nieszczelność podciśnienia (lewe powietrze) – przy lewym powietrzu korekty STFT wzrosłyby powyżej +20%, a są neutralne (${worstPoint.stft.toStringAsFixed(1)}%)",
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
  }

  /// Krzyżowa analiza wypadania zapłonów: odróżnia problem z cewką/świecą od wtryskiwacza
  static void _checkMisfireRootCause(List<LogPoint> points, List<Anomaly> anomalies) {
    // Sprawdzamy wszystkie cylindry od 1 do 4
    for (int cyl = 1; cyl <= 4; cyl++) {
      final misKey = "MIS_$cyl";
      if (!points.any((p) => p.values.containsKey(misKey))) continue;

      // Szukamy momentu gdzie MISFIRE rośnie
      for (int i = 0; i < points.length; i++) {
        final p = points[i];
        final misfires = p.values[misKey];
        if (misfires == null || misfires == 0.0) continue;

        // Znaleźliśmy wypadanie zapłonu. Patrzymy na korekty w tym czasie.
        if (p.values.containsKey("STFT") && p.values.containsKey("LTFT")) {
          final totalTrim = p.values["STFT"]! + p.values["LTFT"]!;

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
          } else {
            // Wypadanie zapłonu + Korekta OK lub UJEMNA (brak iskry, paliwo leje się w wydech)
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
  static TripReport generateTripReport(List<LogPoint> points) {
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
        : 40.0; // Domyślnie 40km/h jeśli brak prędkości
        
    final avgLtft = countLtft > 0 ? sumLtft / countLtft : 0.0;
    final durationMs = points.last.timeMs - points.first.timeMs;
    final durationHours = durationMs / 1000.0 / 3600.0;
    final distanceKm = avgSpeed * durationHours;

    // 1. Zdobądź zwykłe anomalie z całej trasy
    final List<Anomaly> rawAnomalies = analyzeSession(points);

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

