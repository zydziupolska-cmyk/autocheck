// Syntetyczne logi przyspieszenia z typowymi usterkami — wyłącznie do testów
// reguł Asystenta (AnomalyEngine). Nie są częścią aplikacji.
import 'dart:math';
import 'package:autocheck/models/log_point.dart';

enum SyntheticScenario {
  healthy,
  boostLeak,
  knockRetard,
  leanAfr,
  badMaf,
  skodaRapidInjector,
  peugeotIdleHunting,
  dpfBlockedUnderboost,
  dpfEgrDelete,
  lazyO2Sensor,
  cylinderMisfireFuel,
  cylinderMisfireSpark,
}

extension SyntheticScenarioExt on SyntheticScenario {
  String get title {
    switch (this) {
      case SyntheticScenario.healthy:
        return "1. Silnik Sprawny (Wzorcowy log 3. bieg)";
      case SyntheticScenario.boostLeak:
        return "2. Nieszczelność Dolotu (Spadek Boostu przy 4200 RPM)";
      case SyntheticScenario.knockRetard:
        return "3. Cofanie Zapłonu / Stukanie (Złe paliwo / świece)";
      case SyntheticScenario.leanAfr:
        return "4. Skrajnie Uboga Mieszanka (Pompa paliwa / wtryski)";
      case SyntheticScenario.badMaf:
        return "5. Zaniżający Przepływomierz MAF (Dławienie góry)";
      case SyntheticScenario.skodaRapidInjector:
        return "6. Skoda Rapid TSI (Lejący wtrysk #1 & Błąd P0087 na jałowym)";
      case SyntheticScenario.peugeotIdleHunting:
        return "7. Peugeot 307 CC 2.0 (Falowanie i drżenie na jałowym - VVT / EVAP)";
      case SyntheticScenario.dpfBlockedUnderboost:
        return "8. Zatkany Filtr DPF / GPF (Brak doładowania przez dławienie spalinami)";
      case SyntheticScenario.dpfEgrDelete:
        return "9. Wykrywanie usunięcia ekologii (DPF/EGR Delete)";
      case SyntheticScenario.lazyO2Sensor:
        return "10. Leniwa Sonda Lambda (Brak opadania AFR przy hamowaniu)";
      case SyntheticScenario.cylinderMisfireFuel:
        return "11. Wypadanie zapłonu z braku paliwa (Przytkany wtryskiwacz)";
      case SyntheticScenario.cylinderMisfireSpark:
        return "12. Wypadanie zapłonu z braku iskry (Uszkodzona cewka)";
    }
  }

  String get description {
    switch (this) {
      case SyntheticScenario.healthy:
        return "Płynny wzrost doładowania do 1.35 bar, gładki zapłon, bezpieczny AFR 11.8:1.";
      case SyntheticScenario.boostLeak:
        return "Przy 4200 RPM puszcza wąż dolotowy - nagły spadek ciśnienia z 1.3 bar do 0.45 bar.";
      case SyntheticScenario.knockRetard:
        return "Sterownik cofa zapłon o -6.5° w zakresie 4000-5300 RPM z powodu wykrytego stukania.";
      case SyntheticScenario.leanAfr:
        return "Przy pełnym doładowaniu AFR rośnie do niebezpiecznego 14.3:1 (brak wydajności paliwa).";
      case SyntheticScenario.badMaf:
        return "Przepływomierz ucina pomiar przy 135 g/s i dławi silnik na wysokich obrotach.";
      case SyntheticScenario.skodaRapidInjector:
        return "Na wolnych obrotach ciśnienie na listwie spada do 19 bar (Błąd P0087), korekty ujemne -22% i wypadanie zapłonu na 1. cylindrze.";
      case SyntheticScenario.peugeotIdleHunting:
        return "Na wolnych obrotach silnik mocno faluje (650-1050 RPM), zanika podciśnienie (wariator VVT zacięty w wyprzedzeniu), po 'przepaleniu' uspokaja się.";
      case SyntheticScenario.dpfBlockedUnderboost:
        return "Gaz w podłodze, a doładowanie wynosi zaledwie 0.35 bar. Różnica ciśnień DPF rośnie do 45 kPa (sadza 92%) - spaliny dławią wirnik turbosprężarki!";
      case SyntheticScenario.dpfEgrDelete:
        return "Auto rozpędza się bez problemu, ale czujnik różnicy ciśnień DPF zgłasza stałe 0.0 kPa, a zadane otwarcie EGR to 0% w całym zakresie obrotów.";
      case SyntheticScenario.lazyO2Sensor:
        return "Podczas puszczenia gazu (Fuel Overrun) sonda potrzebuje ponad 1.5 sekundy, żeby zauważyć czyste powietrze. Sonda jest zapchana i wymaga wymiany.";
      case SyntheticScenario.cylinderMisfireFuel:
        return "Na wysokich obrotach cylinder nr 3 wypada z zapłonu. Korekty paliwowe (STFT) szybują na +20%, co ewidentnie sugeruje zapchany wtryskiwacz.";
      case SyntheticScenario.cylinderMisfireSpark:
        return "Na wysokich obrotach cylinder nr 3 wypada z zapłonu. Korekty paliwowe spadają lekko na minus (niespalone paliwo trafia w wydech) - ewidentna awaria cewki lub świecy.";
    }
  }
}

/// Generuje kompletny log przyspieszenia (od 1800 do 6700 RPM)
List<LogPoint> generateSyntheticRun(SyntheticScenario scenario) {
  final List<LogPoint> points = [];
  final rnd = Random(42);
  // Licznik wypadania zapłonów jest narastający, jak prawdziwy licznik Mode 06
  double mis3Total = 0;

  // Przyspieszenie trwa ok. 6 sekund, próbkowanie co 50ms (20 Hz)
  const totalPoints = 120;
  const dt = 50.0; // ms

  for (int i = 0; i < totalPoints; i++) {
    final t = i / totalPoints; // 0.0 do 1.0
    final timeMs = i * dt;

    // Obroty od 1800 do 6700 RPM
    double rpm = 1800.0 + (6700.0 - 1800.0) * pow(t, 0.95);
    
    // Odpuszczamy gaz po 4 sekundach (i=80), żeby wywołać Fuel Overrun (odcięcie)
    final tps = (i > 5 && i < 80) ? 100.0 : (i <= 5 ? (i * 20.0) : 0.0);
    
    if (i >= 80) {
      // Hamowanie silnikiem, obroty spadają powoli
      rpm = 6000.0 - (i - 80) * 80.0;
    }

    // Doładowanie bazowe i zadane (TARGET_BOOST)
    double targetBoost = 0.0;
    if (rpm < 2200) {
      targetBoost = 0.1 + (rpm - 1800) / 400 * 0.45;
    } else if (rpm < 3200) {
      targetBoost = 0.55 + (rpm - 2200) / 1000 * 0.80; // Peak 1.35 bar
    } else {
      targetBoost = 1.35 - (rpm - 3200) / 3500 * 0.15; // Hold ~1.20 bar
    }

    double boost = 0.0;
    if (rpm < 2200) {
      boost = 0.1 + (rpm - 1800) / 400 * 0.4;
    } else if (rpm < 3200) {
      boost = 0.5 + (rpm - 2200) / 1000 * 0.85; // Peak 1.35 bar
    } else {
      boost = 1.35 - (rpm - 3200) / 3500 * 0.15; // Hold ~1.20 bar
    }

    // Kąt wyprzedzenia zapłonu bazowy: 8° przy spoolu, rośnie do 17° przy 6500 RPM
    double ign = 8.0 + (rpm - 1800) / 4900 * 9.5;

    // AFR bazowy: schodzi do 11.8:1 w doładowaniu
    double afr = 14.7;
    if (tps > 80) {
      afr = 13.0 - (boost > 0.5 ? 1.2 : 0.0);
    } else if (tps == 0.0 && rpm > 2000) {
      // Hamowanie silnikiem (Fuel Overrun)
      if (scenario == SyntheticScenario.lazyO2Sensor) {
        // Leniwa sonda - trzyma się 14.7 przez 1.5 sekundy po odpuszczeniu gazu, dopiero potem rośnie
        final decelTime = (i - 80) * dt; // 80 to moment puszczenia gazu
        if (decelTime > 1500) {
          afr = 20.0;
        } else {
          afr = 14.7 + (decelTime / 1500) * 1.5; // Bardzo powolny wzrost do 16
        }
      } else {
        // Zdrowa sonda w ułamek sekundy łapie >18.0
        afr = 20.0;
      }
    }

    // MAF bazowy: gładko do ok. 210 g/s
    double maf = 18.0 + (rpm - 1800) / 4900 * 195.0 * (boost > 0.5 ? 1.0 : 0.6);

    // IAT bazowe: 22°C rosnące do 36°C
    double iat = 22.0 + t * 14.0;
    double stft = (rnd.nextDouble() - 0.5) * 3.0;

    // Aplikowanie scenariuszy awaryjnych:
    switch (scenario) {
      case SyntheticScenario.healthy:
        // Wszystko w normie
        break;

      case SyntheticScenario.boostLeak:
        // Przy 4200 RPM pęka rura, ciśnienie spada gwałtownie
        if (rpm >= 4150) {
          final dropFactor = min(1.0, (rpm - 4150) / 300.0);
          boost = boost - dropFactor * 0.85; // spada z 1.30 do 0.45 bar
          maf = maf * 0.8;
        }
        break;

      case SyntheticScenario.knockRetard:
        // W zakresie 4100 - 5400 RPM sterownik cofa zapłon (szarpany retard)
        if (rpm >= 4100 && rpm <= 5400) {
          ign = ign - 6.5 + (rnd.nextDouble() * 1.5);
        }
        break;

      case SyntheticScenario.leanAfr:
        // Od 4200 RPM pompa paliwa nie wydala, AFR szybuje do 14.3:1
        if (rpm >= 4200) {
          final leanRise = min(2.5, (rpm - 4200) / 800.0 * 2.5);
          afr = afr + leanRise; // Skacze do 14.3:1
        }
        break;

      case SyntheticScenario.badMaf:
        // Przy 4200 RPM MAF ucina i zaczyna spadać
        if (rpm >= 4200) {
          maf = 135.0 - (rpm - 4200) / 2500.0 * 30.0;
        }
        break;

      case SyntheticScenario.skodaRapidInjector:
        // Na niskich obrotach/jałowym ciśnienie listwy spada do 19 bar (Błąd P0087), a STFT leci na -22%
        break;

      case SyntheticScenario.peugeotIdleHunting:
        // Falowanie na wolnych obrotach
        break;

      case SyntheticScenario.dpfBlockedUnderboost:
        // Turbo ledwo dmucha, bo wydech jest zapchany
        boost = 0.15 + (rpm - 1800) / 4900.0 * 0.22; // maks ~0.37 bar!
        break;
        
      case SyntheticScenario.dpfEgrDelete:
        // Auto jedzie sprawnie, symulacja "pustego" DPF i zaślepionego EGR zostanie ustawiona w dalszej części kodu
        break;

      case SyntheticScenario.lazyO2Sensor:
        // Logika AFR jest obsłużona poza switchem
        break;
        
      case SyntheticScenario.cylinderMisfireFuel:
        if (rpm >= 3500) {
          // Skrajnie uboga mieszanka, ECU dokłada paliwo
          stft = 18.0 + rnd.nextDouble() * 5.0; // Korekta szybuje do ~20-23%
          ign = ign - 4.0; // Złe spalanie cofa lekko zapłon
        }
        break;
        
      case SyntheticScenario.cylinderMisfireSpark:
        if (rpm >= 3500) {
          // Niespalone paliwo idzie w wydech (sonda widzi przelanie, ECU ucina dawkę)
          stft = -5.0 - rnd.nextDouble() * 3.0; 
          ign = ign - 8.0; // Knock sensor szaleje od losowych zapłonów w wydechu
        }
        break;
    }

    // Układ wydechowy: DPF i EGT
    double dpfDp = 0.0;
    if (scenario == SyntheticScenario.dpfBlockedUnderboost) {
      dpfDp = 28.0 + (rpm - 1800) / 4900.0 * 18.0;
    } else if (scenario == SyntheticScenario.dpfEgrDelete) {
      dpfDp = 0.1; // Stała nienaturalna wartość (zawieszona)
    } else {
      dpfDp = 3.2 + (rpm / 6000.0) * 8.5;
    }

    double dpfSoot = (scenario == SyntheticScenario.dpfBlockedUnderboost) ? 91.0 : 28.0;
    if (scenario == SyntheticScenario.dpfEgrDelete) dpfSoot = 0.0;

    double egt = (scenario == SyntheticScenario.dpfBlockedUnderboost)
        ? (680.0 + (rpm - 1800) / 4900.0 * 120.0)
        : (420.0 + (rpm / 6000.0) * 220.0);

    // Zawór EGR - zazwyczaj otwarty na niższych obrotach, zamknięty przy pełnym bucie.
    double egrCmd = 0.0;
    if (scenario != SyntheticScenario.dpfEgrDelete) {
      egrCmd = (rpm < 3000) ? max(0.0, 40.0 - (rpm - 1800) / 1200 * 40.0) : 0.0;
    }

    // Ciśnienie na szynie wysokiego ciśnienia (F_RAIL): norma 40 bar na jałowym, do 140 bar pod pełnym gazem
    double fRail = (rpm < 2200) ? 40.0 : (40.0 + (rpm - 2200) / 4500 * 100.0);

    if (scenario == SyntheticScenario.skodaRapidInjector) {
      if (rpm <= 2400) {
        fRail = 19.2; // Drastyczny spadek ciśnienia na wolnych obrotach (P0087)
        stft = -22.5; // Bardzo ujemna korekta (ECU próbuje zubożyć zalaną mieszankę)
        ign = ign - 3.5;
      } else {
        fRail = 90.0 + (rpm - 2400) / 4300 * 30.0;
      }
    } else if (scenario == SyntheticScenario.peugeotIdleHunting) {
      // W pierwszej połowie logu auto stoi na jałowym i faluje (680 - 1050 RPM)
      if (i < 40) {
        final oscillation = sin(i * 0.5) * 190.0;
        final idleRpm = 850.0 + oscillation;
        boost = -0.38 + sin(i * 0.5) * 0.06; // Zanik podciśnienia w kolektorze przez współotwarcie zaworów VVT
        stft = 2.5 + (rnd.nextDouble() - 0.5) * 2.0; // Neutralne korekty paliwowe (spaliny to nie paliwo, więc korekta nie skacze dramatycznie)
        ign = 6.0 - sin(i * 0.5) * 5.0; // ECU kontruje zapłonem

        points.add(LogPoint(
          timeMs: timeMs,
          values: {
            "RPM": double.parse(idleRpm.toStringAsFixed(0)),
            "BOOST": double.parse(boost.toStringAsFixed(2)),
            "TARGET_BOOST": -0.65, // Standardowe podciśnienie docelowe na wolnych
            "MAF": 12.0,
            "IGN": double.parse(ign.toStringAsFixed(1)),
            "TPS": 0.0,
            "AFR": 13.8,
            "STFT": double.parse(stft.toStringAsFixed(1)),
            "LTFT": -11.2,
            "F_RAIL": 3.8, // MPI ciśnienie wtrysku pośredniego
            "IAT": 26.0,
            "ECT": 92.0,
            "SPEED": 0.0,
            "DPF_DP": 1.2,
            "DPF_SOOT": 15.0,
            "EGT": 210.0,
          },
        ));
        continue;
      } else {
        // Przepalenie silnika (dodanie gazu, obroty rosną i uspokajają się)
        stft = -2.5;
      }
    }

    // Dodaj odrobinę naturalnego szumu sensora
    boost += (rnd.nextDouble() - 0.5) * 0.02;
    targetBoost += (rnd.nextDouble() - 0.5) * 0.01;
    ign += (rnd.nextDouble() - 0.5) * 0.3;
    afr += (rnd.nextDouble() - 0.5) * 0.1;
    maf += (rnd.nextDouble() - 0.5) * 1.5;

    points.add(LogPoint(
      timeMs: timeMs,
      values: {
        "RPM": double.parse(rpm.toStringAsFixed(0)),
        "BOOST": double.parse(boost.toStringAsFixed(2)),
        "TARGET_BOOST": double.parse(targetBoost.toStringAsFixed(2)),
        "MAF": double.parse(maf.toStringAsFixed(1)),
        "IGN": double.parse(ign.toStringAsFixed(1)),
        "TPS": double.parse(tps.toStringAsFixed(0)),
        "AFR": double.parse(afr.toStringAsFixed(1)),
        "O2_V": double.parse((0.1 + rnd.nextDouble() * 0.8).toStringAsFixed(2)),
        "STFT": double.parse(stft.toStringAsFixed(1)),
        "LTFT": (scenario == SyntheticScenario.skodaRapidInjector) ? -14.5 : 2.3,
        "F_RAIL": double.parse(fRail.toStringAsFixed(1)),
        "IAT": double.parse(iat.toStringAsFixed(1)),
        "ECT": 90.0,
        "SPEED": double.parse((50.0 + t * 90.0).toStringAsFixed(0)),
        "DPF_DP": double.parse(dpfDp.toStringAsFixed(1)),
        "DPF_SOOT": double.parse(dpfSoot.toStringAsFixed(1)),
        "EGT": double.parse(egt.toStringAsFixed(0)),
        "EGR_CMD": double.parse(egrCmd.toStringAsFixed(1)),
        "EGR_ERR": 0.0, // Symulujemy brak błędów pozycjonowania
        "MIS_1": 0.0,
        "MIS_2": 0.0,
        "MIS_3": mis3Total += (rpm >= 3500 && (scenario == SyntheticScenario.cylinderMisfireFuel || scenario == SyntheticScenario.cylinderMisfireSpark)) ? (5.0 + rnd.nextDouble() * 10).roundToDouble() : 0.0,
        "MIS_4": 0.0,
      },
    ));
  }

  return points;
}
