class LogPoint {
  /// Czas od rozpoczęcia logowania w milisekundach
  final double timeMs;

  /// Mapa odczytanych wartości: klucz to shortName (np. "RPM", "BOOST", "IGN")
  final Map<String, double> values;

  const LogPoint({
    required this.timeMs,
    required this.values,
  });

  double get timeSec => timeMs / 1000.0;

  double? getValue(String key) => values[key];

  bool has(String key) => values.containsKey(key);

  double get rpm => values["RPM"] ?? 0.0;
  double get boost => values["BOOST"] ?? 0.0;
  double get maf => values["MAF"] ?? 0.0;
  double get ign => values["IGN"] ?? 0.0;
  /// Żądanie kierowcy: pedał gazu (jeśli logowany), w przeciwnym razie przepustnica.
  /// W dieslach przepustnica (klapa dławiąca) jest niemal zawsze otwarta,
  /// więc bez pedału fałszywie wyglądałoby to na ciągły „gaz w podłodze”.
  double get tps => values["PEDAL"] ?? values["TPS"] ?? 0.0;
  double get throttlePlate => values["TPS"] ?? 0.0;
  double get afr => values["AFR"] ?? 14.7;
  double get stft => values["STFT"] ?? 0.0;
  double get ltft => values["LTFT"] ?? 0.0;
  double get iat => values["IAT"] ?? 20.0;
  double get ect => values["ECT"] ?? 90.0;
  double get load => values["LOAD"] ?? 0.0;
  double get speed => values["SPEED"] ?? 0.0;
  double get fRail => values["F_RAIL"] ?? 0.0;
  double get dpfDp => values["DPF_DP"] ?? 0.0;
  double get dpfSoot => values["DPF_SOOT"] ?? 0.0;
  double get egt => values["EGT"] ?? 0.0;
  double get evapVp => values["EVAP_VP"] ?? 0.0;

  Map<String, dynamic> toJson() => {
    "timeMs": timeMs,
    "values": values,
  };

  factory LogPoint.fromJson(Map<String, dynamic> json) => LogPoint(
    timeMs: (json["timeMs"] as num).toDouble(),
    values: (json["values"] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, (v as num).toDouble()),
    ),
  );
}

class LogSession {
  final String id;
  final String title;
  final DateTime createdAt;
  final List<String> activePidKeys;
  final List<LogPoint> points;
  final double durationSec;

  /// Log z silnika Diesla — wyłącza reguły analizy przeznaczone dla benzyny.
  final bool isDiesel;

  /// Opis pojazdu, z którego pochodzi log (np. "Volkswagen Touran (1T) • WVG...").
  final String? vehicleLabel;

  /// Log demonstracyjny z symulatora (nie jest zapisywany w historii).
  final bool isDemo;

  LogSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.activePidKeys,
    required this.points,
    this.isDiesel = false,
    this.vehicleLabel,
    this.isDemo = false,
  }) : durationSec = points.isEmpty ? 0.0 : (points.last.timeMs - points.first.timeMs) / 1000.0;

  Map<String, dynamic> toJson() => {
        "id": id,
        "title": title,
        "createdAt": createdAt.toIso8601String(),
        "activePidKeys": activePidKeys,
        "isDiesel": isDiesel,
        "vehicleLabel": vehicleLabel,
        "points": points.map((p) => p.toJson()).toList(),
      };

  factory LogSession.fromJson(Map<String, dynamic> json) => LogSession(
        id: json["id"] as String,
        title: json["title"] as String,
        createdAt: DateTime.tryParse(json["createdAt"] as String? ?? "") ?? DateTime.now(),
        activePidKeys: (json["activePidKeys"] as List).map((e) => e.toString()).toList(),
        isDiesel: json["isDiesel"] as bool? ?? false,
        vehicleLabel: json["vehicleLabel"] as String?,
        points: (json["points"] as List).map((e) => LogPoint.fromJson(e as Map<String, dynamic>)).toList(),
      );

  double get peakRpm {
    if (points.isEmpty) return 0;
    return points.map((p) => p.rpm).reduce((a, b) => a > b ? a : b);
  }

  double get peakBoost {
    if (points.isEmpty) return 0;
    return points.map((p) => p.boost).reduce((a, b) => a > b ? a : b);
  }

  double get minAfr {
    if (points.isEmpty) return 14.7;
    final afrPoints = points.where((p) => p.values.containsKey("AFR")).map((p) => p.afr);
    return afrPoints.isEmpty ? 14.7 : afrPoints.reduce((a, b) => a < b ? a : b);
  }

  double get minTiming {
    if (points.isEmpty) return 0;
    final ignPoints = points.where((p) => p.values.containsKey("IGN")).map((p) => p.ign);
    return ignPoints.isEmpty ? 0 : ignPoints.reduce((a, b) => a < b ? a : b);
  }
}
