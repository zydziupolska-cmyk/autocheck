import 'dart:convert';

/// Specyfikacja silnika po kodzie producenta (z bazy car2db, zaciągnięta offline).
/// Uzupełnia diagnozę i raport o twarde dane: paliwo, pojemność, moc, moment,
/// doładowanie i roczniki. Nie zawiera typowych usterek — te są w EngineProfiles.
class EngineSpec {
  final String code;
  final String? make;
  final String? fuel; // Gasoline / Diesel / Electro
  final double? volumeCcm;
  final double? powerHp;
  final double? powerKw;
  final double? torqueNm;
  final double? cylinders;
  final String? boost; // np. "Turbocharged"; null = wolnossący
  final int? yearBegin;
  final int? yearEnd;
  final List<String> models;

  const EngineSpec({
    required this.code,
    this.make,
    this.fuel,
    this.volumeCcm,
    this.powerHp,
    this.powerKw,
    this.torqueNm,
    this.cylinders,
    this.boost,
    this.yearBegin,
    this.yearEnd,
    this.models = const [],
  });

  bool get isDiesel => fuel == "Diesel";
  bool get isElectric => fuel == "Electro";
  bool get isTurbo => boost != null;

  String get fuelPl {
    switch (fuel) {
      case "Diesel":
        return "diesel";
      case "Gasoline":
        return "benzyna";
      case "Electro":
        return "elektryczny";
      default:
        return fuel ?? "—";
    }
  }

  /// Pojemność w litrach zaokrąglona do 0.1 (np. 1896 ccm → "1.9 l").
  String? get volumeL {
    if (volumeCcm == null || volumeCcm! <= 0) return null;
    return "${(volumeCcm! / 1000).toStringAsFixed(1)} l";
  }

  /// Zwięzła etykieta do UI/raportu, np. „1.9 l • 90 KM • 210 Nm • diesel • turbo • 1998–2005".
  String get summary {
    final parts = <String>[];
    if (volumeL != null) parts.add(volumeL!);
    if (powerHp != null) parts.add("${powerHp!.toInt()} KM");
    if (torqueNm != null) parts.add("${torqueNm!.toInt()} Nm");
    parts.add(fuelPl);
    if (isTurbo) parts.add("turbo");
    final years = yearRange;
    if (years != null) parts.add(years);
    return parts.join(" • ");
  }

  String? get yearRange {
    if (yearBegin == null && yearEnd == null) return null;
    final b = yearBegin?.toString() ?? "?";
    final e = yearEnd?.toString() ?? "teraz";
    return "$b–$e";
  }

  factory EngineSpec.fromJson(String code, Map<String, dynamic> j) => EngineSpec(
        code: code,
        make: j["make"] as String?,
        fuel: j["fuel"] as String?,
        volumeCcm: (j["volumeCcm"] as num?)?.toDouble(),
        powerHp: (j["powerHp"] as num?)?.toDouble(),
        powerKw: (j["powerKw"] as num?)?.toDouble(),
        torqueNm: (j["torqueNm"] as num?)?.toDouble(),
        cylinders: (j["cylinders"] as num?)?.toDouble(),
        boost: j["boost"] as String?,
        yearBegin: (j["yearBegin"] as num?)?.toInt(),
        yearEnd: (j["yearEnd"] as num?)?.toInt(),
        models: (j["models"] as List?)?.map((e) => e.toString()).toList() ?? const [],
      );
}

/// Rejestr specyfikacji silników wczytany z zasobu JSON (assets/data/engine_specs.json).
class EngineSpecs {
  static final Map<String, EngineSpec> _byCode = {};
  static bool get isLoaded => _byCode.isNotEmpty;

  /// Wczytuje bazę z JSON. Kody zgrupowane w jednej pozycji ("CRLB, DBGA, DEJA")
  /// są rozbijane na osobne wpisy wskazujące tę samą specyfikację.
  static void loadFromJson(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final list = (data["engines"] as List?) ?? const [];
      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        final rawCode = (m["code"] ?? "").toString();
        for (final c in _splitCodes(rawCode)) {
          _byCode[c] = EngineSpec.fromJson(c, m);
        }
      }
    } catch (_) {
      // Brak/zła baza nie może wywrócić startu aplikacji.
    }
  }

  static Iterable<String> _splitCodes(String raw) => raw
      .toUpperCase()
      .split(RegExp(r'[,/;]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && s != "VW");

  /// Bezpośrednie dopasowanie po pełnym kodzie (np. "N47D20", "CFFB").
  static EngineSpec? byCode(String? code) {
    if (code == null) return null;
    return _byCode[code.trim().toUpperCase()];
  }

  /// Szuka w dowolnym tekście (CALID, opis silnika, VIN) znanego kodu silnika.
  /// Dopasowuje całe tokeny i preferuje najdłuższy kod (żeby "N47D20" wygrało z "N47").
  static EngineSpec? findInText(String? haystack) {
    if (haystack == null || haystack.isEmpty) return null;
    final tokens = haystack.toUpperCase().split(RegExp(r'[^A-Z0-9]+')).where((t) => t.length >= 3).toSet();
    EngineSpec? best;
    for (final t in tokens) {
      final s = _byCode[t];
      if (s != null && (best == null || s.code.length > best.code.length)) best = s;
    }
    return best;
  }

  static void clearForTest() => _byCode.clear();
  static int get count => _byCode.length;
}
