enum AnomalySeverity {
  info,
  warning,
  critical,
  tampering,
}

class Anomaly {
  final String id;
  final String title;
  final AnomalySeverity severity;
  final String paramKey; // np. "IGN", "BOOST", "AFR", "MAF"
  final double startMs;
  final double endMs;
  final double startRpm;
  final double endRpm;
  final String observedValueText; // np. "Spadek z 1.35 bar do 0.48 bar"
  final String description; // Dokładny opis usterki w j. polskim
  final List<String> hypotheses; // Co może być przyczyną usterki?
  final List<String> recommendations; // Co sprawdzić w pierwszej kolejności?
  final String? primarySymptom; // Główny objaw (np. "Brak narastania ciśnienia doładowania")
  final Map<String, String>? correlatedSignals; // Sygnały z innych czujników w tym samym ułamku sekundy
  final String? falseLeadWarning; // Ostrzeżenie przed mylnym tropem (np. "Nie wymieniaj w ciemno czujnika X!")
  final List<String>? ruledOutCauses; // Przyczyny wykluczone przez inne parametry
  final String? rootCauseConclusion; // Końcowy techniczny wniosek przyczynowo-skutkowy
  final String? plainSummary; // Wniosek prostym językiem dla kierowcy („co jest zepsute i co zrobić”)
  final String? engineNote; // Notatka o typowej usterce wykrytego silnika (z bazy silników)

  const Anomaly({
    required this.id,
    required this.title,
    required this.severity,
    required this.paramKey,
    required this.startMs,
    required this.endMs,
    required this.startRpm,
    required this.endRpm,
    required this.observedValueText,
    required this.description,
    required this.hypotheses,
    required this.recommendations,
    this.primarySymptom,
    this.correlatedSignals,
    this.falseLeadWarning,
    this.ruledOutCauses,
    this.rootCauseConclusion,
    this.plainSummary,
    this.engineNote,
  });

  /// Kopia z dołączoną notatką o typowej usterce silnika.
  Anomaly withEngineNote(String note) => Anomaly(
        id: id,
        title: title,
        severity: severity,
        paramKey: paramKey,
        startMs: startMs,
        endMs: endMs,
        startRpm: startRpm,
        endRpm: endRpm,
        observedValueText: observedValueText,
        description: description,
        hypotheses: hypotheses,
        recommendations: recommendations,
        primarySymptom: primarySymptom,
        correlatedSignals: correlatedSignals,
        falseLeadWarning: falseLeadWarning,
        ruledOutCauses: ruledOutCauses,
        rootCauseConclusion: rootCauseConclusion,
        plainSummary: plainSummary,
        engineNote: note,
      );

  double get startSec => startMs / 1000.0;
  double get endSec => endMs / 1000.0;

  String get severityLabel {
    switch (severity) {
      case AnomalySeverity.critical:
        return "KRYTYCZNE";
      case AnomalySeverity.warning:
        return "OSTRZEŻENIE";
      case AnomalySeverity.info:
        return "INFORMACJA";
      case AnomalySeverity.tampering:
        return "MANIPULACJA (TAMPERING)";
    }
  }

  int get severityColorHex {
    switch (severity) {
      case AnomalySeverity.critical:
        return 0xFFFF3B30; // Bright Red
      case AnomalySeverity.warning:
        return 0xFFFF9500; // Orange
      case AnomalySeverity.info:
        return 0xFF30D158; // Green / Cyan
      case AnomalySeverity.tampering:
        return 0xFFBF5AF2; // Purple for tampering
    }
  }
}
