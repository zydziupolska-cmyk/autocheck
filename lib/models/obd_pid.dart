
enum PidCategory {
  engine,
  turbo,
  fuel,
  ignition,
  temperature,
  exhaust,
}

class ObdPid {
  final String code; // np. "010C"
  final String shortName; // np. "RPM"
  final String name; // np. "Obroty silnika"
  final String unit; // np. "obr/min"
  final PidCategory category;
  final int colorValue; // ARGB hex
  final double minExpected;
  final double maxExpected;
  final double Function(List<int> bytes) decoder;

  const ObdPid({
    required this.code,
    required this.shortName,
    required this.name,
    required this.unit,
    required this.category,
    required this.colorValue,
    required this.minExpected,
    required this.maxExpected,
    required this.decoder,
  });

  /// Numer PID dla zapytań Mode 01 (np. 0x0C dla "010C"), null dla innych.
  int? get mode01Pid {
    if (code.length != 4 || !code.startsWith("01")) return null;
    return int.tryParse(code.substring(2), radix: 16);
  }

  /// Identyfikator monitora Mode 06 (np. 0xA2 dla "06A2"), null dla innych.
  int? get mode06Mid {
    if (code.length != 4 || !code.startsWith("06")) return null;
    return int.tryParse(code.substring(2), radix: 16);
  }

  /// Licznik wypadania zapłonów z odpowiedzi Mode 06 (monitory $A2-$AD).
  /// Dane zaczynają się od MID; każdy rekord ma 9 bajtów:
  /// MID, TID, jednostka, wartość(2), min(2), max(2).
  /// Preferowany TID $0C (bieżący cykl jazdy), w drugiej kolejności $0B (średnia z 10 cykli).
  static double decodeMisfireCount(List<int> data) {
    double? current;
    double? average;
    for (int i = 0; i + 9 <= data.length; i += 9) {
      final tid = data[i + 1];
      final value = ((data[i + 3] << 8) | data[i + 4]).toDouble();
      if (tid == 0x0C) current = value;
      if (tid == 0x0B) average = value;
    }
    return current ?? average ?? double.nan;
  }

  /// Standardowy katalog czujników OBD-II (Mode 01)
  static final List<ObdPid> standardPids = [
    ObdPid(
      code: "010C",
      shortName: "RPM",
      name: "Obroty silnika",
      unit: "obr/min",
      category: PidCategory.engine,
      colorValue: 0xFF3A86FF, // Electric Blue
      minExpected: 0,
      maxExpected: 7500,
      decoder: (b) => b.length >= 2 ? ((b[0] * 256) + b[1]) / 4.0 : 0.0,
    ),
    ObdPid(
      code: "010B",
      shortName: "BOOST",
      name: "Doładowanie (Względne)",
      unit: "bar",
      category: PidCategory.turbo,
      colorValue: 0xFF00D2FF, // Neon Cyan
      minExpected: -0.8,
      maxExpected: 2.5,
      // MAP (kPa) przeliczone na ciśnienie względne w bar (MAP - 100kPa)/100
      decoder: (b) => b.isNotEmpty ? ((b[0] - 100.0) / 100.0) : 0.0,
    ),
    ObdPid(
      code: "0110",
      shortName: "MAF",
      name: "Przepływomierz powietrza",
      unit: "g/s",
      category: PidCategory.turbo,
      colorValue: 0xFF00F5D4, // Teal / Mint
      minExpected: 0,
      maxExpected: 350,
      decoder: (b) => b.length >= 2 ? ((b[0] * 256.0) + b[1]) / 100.0 : 0.0,
    ),
    ObdPid(
      code: "010E",
      shortName: "IGN",
      name: "Wyprzedzenie zapłonu",
      unit: "°",
      category: PidCategory.ignition,
      colorValue: 0xFFFF9F1C, // Amber
      minExpected: -15,
      maxExpected: 45,
      decoder: (b) => b.isNotEmpty ? (b[0] / 2.0 - 64.0) : 0.0,
    ),
    ObdPid(
      code: "0111",
      shortName: "TPS",
      name: "Położenie przepustnicy",
      unit: "%",
      category: PidCategory.engine,
      colorValue: 0xFF7000FF, // Purple
      minExpected: 0,
      maxExpected: 100,
      decoder: (b) => b.isNotEmpty ? (b[0] * 100.0 / 255.0) : 0.0,
    ),
    // Pedał gazu — w dieslach TPS (010x11) to klapa dławiąca, która jest prawie
    // zawsze otwarta, więc do wykrywania „gazu w podłodze” potrzebny jest pedał.
    // Dwa warianty o tej samej nazwie: preferowany względny 015A, a jeśli ECU go
    // nie obsługuje — bezwzględny 0149 przeskalowany do 0-100%.
    ObdPid(
      code: "015A",
      shortName: "PEDAL",
      name: "Pedał gazu (względny)",
      unit: "%",
      category: PidCategory.engine,
      colorValue: 0xFFB5179E, // Magenta
      minExpected: 0,
      maxExpected: 100,
      decoder: (b) => b.isNotEmpty ? (b[0] * 100.0 / 255.0) : 0.0,
    ),
    ObdPid(
      code: "0149",
      shortName: "PEDAL",
      name: "Pedał gazu (czujnik D)",
      unit: "%",
      category: PidCategory.engine,
      colorValue: 0xFFB5179E,
      minExpected: 0,
      maxExpected: 100,
      // Czujnik D pokazuje ok. 14-16% w spoczynku i ok. 78-82% przy wciśniętym pedale
      decoder: (b) {
        if (b.isEmpty) return double.nan;
        final raw = b[0] * 100.0 / 255.0;
        return ((raw - 15.0) / (80.0 - 15.0) * 100.0).clamp(0.0, 100.0);
      },
    ),
    ObdPid(
      code: "0134",
      shortName: "AFR",
      name: "Skład mieszanki (AFR)",
      unit: ":1",
      category: PidCategory.fuel,
      colorValue: 0xFFFF007F, // Neon Pink
      minExpected: 10.0,
      maxExpected: 18.0,
      // Lambda = ((A*256)+B)/32768, AFR = Lambda * 14.7 (dla benzyny)
      decoder: (b) {
        if (b.length >= 2) {
          final lambda = ((b[0] * 256.0) + b[1]) / 32768.0;
          return lambda * 14.7;
        }
        return 14.7;
      },
    ),
    ObdPid(
      code: "0106",
      shortName: "STFT",
      name: "Krótka korekta paliwa",
      unit: "%",
      category: PidCategory.fuel,
      colorValue: 0xFFFFBE0B, // Yellow
      minExpected: -25,
      maxExpected: 25,
      decoder: (b) => b.isNotEmpty ? ((b[0] - 128.0) * 100.0 / 128.0) : 0.0,
    ),
    ObdPid(
      code: "0107",
      shortName: "LTFT",
      name: "Długa korekta paliwa",
      unit: "%",
      category: PidCategory.fuel,
      colorValue: 0xFFFB5607, // Orange red
      minExpected: -25,
      maxExpected: 25,
      decoder: (b) => b.isNotEmpty ? ((b[0] - 128.0) * 100.0 / 128.0) : 0.0,
    ),
    ObdPid(
      code: "010F",
      shortName: "IAT",
      name: "Temperatura w dolocie",
      unit: "°C",
      category: PidCategory.temperature,
      colorValue: 0xFF4CC9F0, // Sky Blue
      minExpected: -10,
      maxExpected: 80,
      decoder: (b) => b.isNotEmpty ? (b[0] - 40.0) : 0.0,
    ),
    ObdPid(
      code: "0105",
      shortName: "ECT",
      name: "Temperatura płynu chłodzącego",
      unit: "°C",
      category: PidCategory.temperature,
      colorValue: 0xFF4361EE, // Indigo
      minExpected: 40,
      maxExpected: 120,
      decoder: (b) => b.isNotEmpty ? (b[0] - 40.0) : 0.0,
    ),
    ObdPid(
      code: "0104",
      shortName: "LOAD",
      name: "Obciążenie silnika",
      unit: "%",
      category: PidCategory.engine,
      colorValue: 0xFF06D6A0, // Emerald
      minExpected: 0,
      maxExpected: 100,
      decoder: (b) => b.isNotEmpty ? (b[0] * 100.0 / 255.0) : 0.0,
    ),
    ObdPid(
      code: "010D",
      shortName: "SPEED",
      name: "Prędkość pojazdu",
      unit: "km/h",
      category: PidCategory.engine,
      colorValue: 0xFF9D4EDD, // Violet
      minExpected: 0,
      maxExpected: 280,
      decoder: (b) => b.isNotEmpty ? b[0].toDouble() : 0.0,
    ),
    ObdPid(
      code: "0123",
      shortName: "F_RAIL",
      name: "Ciśnienie na listwie paliwa",
      unit: "bar",
      category: PidCategory.fuel,
      colorValue: 0xFFE63946, // Red
      minExpected: 0,
      maxExpected: 200,
      decoder: (b) => b.length >= 2 ? (((b[0] * 256.0) + b[1]) * 10.0 / 100.0) : 0.0,
    ),
    ObdPid(
      code: "017A",
      shortName: "DPF_DP",
      name: "Różnica ciśnień DPF / GPF",
      unit: "kPa",
      category: PidCategory.exhaust,
      colorValue: 0xFFD00000, // Crimson Red
      minExpected: 0,
      maxExpected: 80,
      // PID 7A: bajt A = maska obsługi, B-C = różnica ciśnień (ze znakiem) / 100 kPa
      decoder: (b) {
        if (b.length < 3) return double.nan;
        var raw = (b[1] << 8) | b[2];
        if (raw >= 0x8000) raw -= 0x10000;
        return raw / 100.0;
      },
    ),
    ObdPid(
      code: "0178",
      shortName: "EGT",
      name: "Temperatura spalin (EGT)",
      unit: "°C",
      category: PidCategory.exhaust,
      colorValue: 0xFFFF5400, // Bright Orange
      minExpected: 100,
      maxExpected: 950,
      // PID 78: bajt A = maska czujników 1-4, potem 4 x 2 bajty (wartość/10 - 40).
      // Bierzemy pierwszy obsługiwany czujnik.
      decoder: (b) {
        if (b.length < 3) return double.nan;
        final mask = b[0];
        for (int s = 0; s < 4; s++) {
          if (mask & (1 << s) != 0 && b.length >= 3 + s * 2) {
            return ((b[1 + s * 2] << 8) | b[2 + s * 2]) / 10.0 - 40.0;
          }
        }
        return ((b[1] << 8) | b[2]) / 10.0 - 40.0;
      },
    ),
    ObdPid(
      code: "012E",
      shortName: "EVAP_VP",
      name: "Elektrozawór EVAP (Otwarcie)",
      unit: "%",
      category: PidCategory.fuel,
      colorValue: 0xFF00B4D8, // Light Blue
      minExpected: 0,
      maxExpected: 100,
      decoder: (b) => b.isNotEmpty ? (b[0] * 100.0 / 255.0) : 0.0,
    ),
    ObdPid(
      code: "012C",
      shortName: "EGR_CMD",
      name: "Zadane Otwarcie EGR",
      unit: "%",
      category: PidCategory.exhaust,
      colorValue: 0xFF9C27B0, // Fioletowy
      minExpected: 0,
      maxExpected: 100,
      decoder: (b) => b.isNotEmpty ? (b[0] * 100.0 / 255.0) : 0.0,
    ),
    ObdPid(
      code: "012D",
      shortName: "EGR_ERR",
      name: "Błąd Pozycjonowania EGR",
      unit: "%",
      category: PidCategory.exhaust,
      colorValue: 0xFFE91E63, // Różowy
      minExpected: -100,
      maxExpected: 100,
      decoder: (b) => b.isNotEmpty ? ((b[0] * 100.0 / 128.0) - 100.0) : 0.0,
    ),
    ObdPid(
      code: "0114",
      shortName: "O2_V",
      name: "Napięcie Sondy Lambda (B1S1)",
      unit: "V",
      category: PidCategory.fuel,
      colorValue: 0xFF8BC34A, // Jasnozielony
      minExpected: 0.0,
      maxExpected: 1.2,
      decoder: (b) => b.isNotEmpty ? (b[0] / 200.0) : 0.0,
    ),
    ObdPid(
      code: "06A2",
      shortName: "MIS_1",
      name: "Wypadanie zapłonu cyl. 1 (licznik)",
      unit: "cnt",
      category: PidCategory.ignition,
      colorValue: 0xFFFF5722,
      minExpected: 0,
      maxExpected: 50,
      // Mode 06, monitor $A2: licznik wypadania zapłonów w bieżącym cyklu jazdy
      decoder: ObdPid.decodeMisfireCount,
    ),
    ObdPid(
      code: "06A3",
      shortName: "MIS_2",
      name: "Wypadanie zapłonu cyl. 2 (licznik)",
      unit: "cnt",
      category: PidCategory.ignition,
      colorValue: 0xFFFF5722,
      minExpected: 0,
      maxExpected: 50,
      // Mode 06, monitor $A3: licznik wypadania zapłonów w bieżącym cyklu jazdy
      decoder: ObdPid.decodeMisfireCount,
    ),
    ObdPid(
      code: "06A4",
      shortName: "MIS_3",
      name: "Wypadanie zapłonu cyl. 3 (licznik)",
      unit: "cnt",
      category: PidCategory.ignition,
      colorValue: 0xFFFF5722,
      minExpected: 0,
      maxExpected: 50,
      // Mode 06, monitor $A4: licznik wypadania zapłonów w bieżącym cyklu jazdy
      decoder: ObdPid.decodeMisfireCount,
    ),
    ObdPid(
      code: "06A5",
      shortName: "MIS_4",
      name: "Wypadanie zapłonu cyl. 4 (licznik)",
      unit: "cnt",
      category: PidCategory.ignition,
      colorValue: 0xFFFF5722,
      minExpected: 0,
      maxExpected: 50,
      // Mode 06, monitor $A5: licznik wypadania zapłonów w bieżącym cyklu jazdy
      decoder: ObdPid.decodeMisfireCount,
    ),
  ];

  /// Zwraca PID po kodzie skróconym
  static ObdPid? getByShortName(String shortName) {
    try {
      return standardPids.firstWhere((p) => p.shortName == shortName);
    } catch (_) {
      return null;
    }
  }

  /// Zwraca PID po kodzie hex
  static ObdPid? getByCode(String code) {
    try {
      return standardPids.firstWhere((p) => p.code.toUpperCase() == code.toUpperCase());
    } catch (_) {
      return null;
    }
  }
}

/// Profile logowania
class LoggingPreset {
  final String id;
  final String title;
  final String description;
  final List<String> pidShortNames;

  const LoggingPreset({
    required this.id,
    required this.title,
    required this.description,
    required this.pidShortNames,
  });

  static final List<LoggingPreset> presets = [
    const LoggingPreset(
      id: "wot_pull",
      title: "Pomiar WOT / Przyspieszenie (Hamownia)",
      description: "Maksymalny FPS do analizy przyspieszenia: Obroty, Doładowanie, Przepływomierz, Kąt zapłonu, Przepustnica, AFR.",
      pidShortNames: ["RPM", "BOOST", "MAF", "IGN", "TPS", "PEDAL", "AFR"],
    ),
    const LoggingPreset(
      id: "turbo_diag",
      title: "Diagnostyka Układu Turbo & Dolotu",
      description: "Ciśnienie doładowania, obroty, przepływ powietrza i temperatura w dolocie (wykrywanie nieszczelności i overboostu).",
      pidShortNames: ["RPM", "BOOST", "MAF", "IAT", "TPS", "PEDAL"],
    ),
    const LoggingPreset(
      id: "dpf_turbo_correlate",
      title: "Turbosprężarka vs DPF/GPF (Spaliny)",
      description: "Analiza zależności braku mocy: Ciśnienie doładowania, różnica ciśnień DPF, temperatura spalin EGT i zawór EGR.",
      pidShortNames: ["RPM", "BOOST", "MAF", "DPF_DP", "EGT", "TPS", "PEDAL", "EGR_CMD"],
    ),
    const LoggingPreset(
      id: "idle_evap_vvt",
      title: "Wolne Obroty / VVT & EVAP",
      description: "Wykrywanie przyczyn falowania i drżenia: Obroty, Podciśnienie MAP, Korekty STFT, Zawór EVAP, Przepustnica.",
      pidShortNames: ["RPM", "BOOST", "STFT", "LTFT", "EVAP_VP", "TPS", "IGN"],
    ),
    const LoggingPreset(
      id: "fuel_ignition",
      title: "Paliwo, Mieszanka i Zapłon",
      description: "Cofanie zapłonu, skład mieszanki AFR, korekty STFT/LTFT, ciśnienie na szynie i liczniki wypadania zapłonów (Mode 06).",
      pidShortNames: ["RPM", "IGN", "AFR", "STFT", "LTFT", "F_RAIL", "TPS", "MIS_1", "MIS_2", "MIS_3", "MIS_4"],
    ),
    const LoggingPreset(
      id: "all_sensors",
      title: "Wszystkie Obsługiwane Sensory",
      description: "Pełny log ze wszystkich czujników dostępnych w samochodzie.",
      pidShortNames: ["RPM", "BOOST", "MAF", "IGN", "TPS", "PEDAL", "AFR", "O2_V", "STFT", "LTFT", "IAT", "ECT", "LOAD", "SPEED", "F_RAIL", "DPF_DP", "EGT", "EVAP_VP", "EGR_CMD", "EGR_ERR", "MIS_1", "MIS_2", "MIS_3", "MIS_4"],
    ),
  ];
}
