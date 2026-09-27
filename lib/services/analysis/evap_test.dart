/// Prowadzony test zaworu EVAP (odpowietrzania zbiornika paliwa).
///
/// Zacięty lub nieszczelny zawór EVAP wpuszcza na wolnych obrotach niesterowane opary
/// paliwa z baku: silnik faluje, sterownik ujmuje paliwa (ujemne korekty). Z samej jazdy
/// trudno to odróżnić od innych przyczyn, dlatego test porównuje dwie fazy biegu jałowego:
/// A — normalnie, B — z zaciśniętym wężem od zaworu do kolektora. Jeśli po odcięciu
/// silnik się uspokaja lub korekty wracają ku zeru — winny jest zawór.
library;

import '../../models/anomaly.dart';
import '../../models/log_point.dart';
import 'signal_stats.dart';

/// Klucz w logu oznaczający fazę testu: 0 = przed zaciśnięciem, 1 = po zaciśnięciu węża.
const evapTestPhaseKey = "EVAP_TEST_PHASE";

enum EvapOutcome { faulty, ok, noSymptoms, insufficient }

class EvapPhaseStats {
  final int samples;
  final double rpmSpread; // p95 − p5
  final int reversals;
  final double? trimMedian; // STFT + LTFT, tylko prawidłowe
  final double rpmMean;
  const EvapPhaseStats(this.samples, this.rpmSpread, this.reversals, this.trimMedian, this.rpmMean);

  static EvapPhaseStats of(List<LogPoint> pts) {
    final trims = [for (final p in pts) ?SignalStats.totalTrim(p)];
    final mean = pts.isEmpty ? 0.0 : pts.map((p) => p.rpm).reduce((a, b) => a + b) / pts.length;
    return EvapPhaseStats(
      pts.length,
      SignalStats.rpmSpread(pts),
      SignalStats.rpmReversals(pts),
      trims.length >= 3 ? SignalStats.median(trims) : null,
      mean,
    );
  }

  bool get hunting => rpmSpread >= 150 && reversals >= 2;
  bool get rich => trimMedian != null && trimMedian! <= -8;
}

class EvapTestVerdict {
  final EvapOutcome outcome;
  final EvapPhaseStats before;
  final EvapPhaseStats after;
  const EvapTestVerdict(this.outcome, this.before, this.after);

  bool get rpmImproved => before.hunting && after.rpmSpread <= before.rpmSpread * 0.6;
  bool get trimImproved =>
      before.rich && after.trimMedian != null && after.trimMedian! - before.trimMedian! >= 5;

  static String _t(double? v) => v == null ? "—" : "${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%";

  /// Opis zmian między fazami (do wyniku i raportu).
  String get comparison => "Falowanie obrotów: ${before.rpmSpread.toInt()} → ${after.rpmSpread.toInt()} obr/min; "
      "korekty paliwa: ${_t(before.trimMedian)} → ${_t(after.trimMedian)}";

  String get title {
    switch (outcome) {
      case EvapOutcome.faulty:
        return "Test EVAP: zawór EVAP przepuszcza opary — do wymiany";
      case EvapOutcome.ok:
        return "Test EVAP: zawór sprawny — przyczyna falowania jest inna";
      case EvapOutcome.noSymptoms:
        return "Test EVAP: brak objawów w czasie testu";
      case EvapOutcome.insufficient:
        return "Test EVAP: za mało odczytów do oceny";
    }
  }

  String get plainSummary {
    switch (outcome) {
      case EvapOutcome.faulty:
        return "Po odcięciu zaworu EVAP ${rpmImproved ? 'silnik przestał falować' : 'mieszanka wróciła do normy'} — "
            "zawór nie domyka i wpuszcza opary paliwa z baku. Wymień zawór odpowietrzania zbiornika (EVAP).";
      case EvapOutcome.ok:
        return "Odcięcie zaworu EVAP niczego nie zmieniło, więc to nie zawór. Sprawdź przepustnicę, "
            "nieszczelności podciśnienia (próba dymowa) i cewki zapłonowe.";
      case EvapOutcome.noSymptoms:
        return "W czasie testu silnik pracował równo, więc test niczego nie rozstrzygnął. Powtórz go, gdy objaw "
            "występuje — np. zaraz po tankowaniu albo na mocno rozgrzanym silniku.";
      case EvapOutcome.insufficient:
        return "Połączenie z autem dało za mało odczytów. Powtórz test — aplikacja wydłuży fazy, żeby zebrać dane.";
    }
  }

  static EvapTestVerdict evaluate(List<LogPoint> points) {
    final a = points.where((p) => p.values[evapTestPhaseKey] == 0).toList();
    final b = points.where((p) => p.values[evapTestPhaseKey] == 1).toList();
    final before = EvapPhaseStats.of(a);
    final after = EvapPhaseStats.of(b);
    EvapOutcome outcome;
    if (a.length < 6 || b.length < 6) {
      outcome = EvapOutcome.insufficient;
    } else {
      final v = EvapTestVerdict(EvapOutcome.ok, before, after);
      if (v.rpmImproved || v.trimImproved) {
        outcome = EvapOutcome.faulty;
      } else if (before.hunting || before.rich) {
        outcome = EvapOutcome.ok;
      } else {
        outcome = EvapOutcome.noSymptoms;
      }
    }
    return EvapTestVerdict(outcome, before, after);
  }

  /// Wynik jako pozycja diagnozy (trafia do ekranu Diagnoza i raportu dla klienta).
  Anomaly toAnomaly(List<LogPoint> points) {
    final first = points.first;
    final last = points.last;
    final faulty = outcome == EvapOutcome.faulty;
    return Anomaly(
      id: "evap_test_${outcome.name}_${first.timeMs.toInt()}",
      title: title,
      severity: faulty ? AnomalySeverity.critical : AnomalySeverity.info,
      paramKey: trimImproved ? "STFT" : "RPM",
      startMs: first.timeMs,
      endMs: last.timeMs,
      startRpm: before.rpmMean,
      endRpm: after.rpmMean,
      observedValueText: comparison,
      plainSummary: plainSummary,
      description: "Test porównał bieg jałowy przed i po zaciśnięciu węża od zaworu EVAP do kolektora ssącego "
          "(${before.samples} i ${after.samples} odczytów).",
      correlatedSignals: {
        "Przed zaciśnięciem": "falowanie ${before.rpmSpread.toInt()} obr/min, korekty ${_t(before.trimMedian)}",
        "Po zaciśnięciu": "falowanie ${after.rpmSpread.toInt()} obr/min, korekty ${_t(after.trimMedian)}",
      },
      rootCauseConclusion: faulty
          ? "Zawór EVAP nie domyka — przy zamkniętej przepustnicy opary z kanistra trafiają do kolektora i zalewają mieszankę."
          : null,
      hypotheses: faulty
          ? const ["Zacięty lub nieszczelny elektrozawór odpowietrzania zbiornika (EVAP)"]
          : const [
              "Zabrudzona przepustnica / czujnik MAP",
              "Nieszczelność podciśnienia (wąż, kolektor, serwo, odma)",
              "Przebicie na cewkach zapłonowych",
              "Przycinający się zawór zmiennych faz rozrządu (VVT)",
            ],
      recommendations: faulty
          ? const [
              "Wymień elektrozawór EVAP (zawór odpowietrzania zbiornika paliwa).",
              "Sprawdź, czy kanister węglowy nie jest zalany paliwem (częste przy tankowaniu „pod korek”).",
              "Po wymianie skasuj kody i wykonaj adaptację biegu jałowego.",
            ]
          : outcome == EvapOutcome.ok
              ? const [
                  "Wyczyść przepustnicę i czujnik MAP, wykonaj adaptację przepustnicy.",
                  "Wykonaj próbę dymową podciśnień.",
                  "Obejrzyj listwę cewek zapłonowych pod kątem pęknięć.",
                ]
              : const ["Powtórz test, gdy objaw występuje."],
    );
  }
}
