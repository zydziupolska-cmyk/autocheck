enum PidCategory {
  engine,
  turbo,
  fuel,
  ignition,
  temperature,
  exhaust,
}

/// Jak często odpytywać parametr podczas logowania (jak w profesjonalnych loggerach):
/// szybkie co cykl, normalne co 2 cykle, wolne (temperatury, liczniki) co ok. 8 cykli.
enum PollRate { fast, normal, slow }

/// Przekształcenie wartości po zdekodowaniu.
enum ValueTransform {
  none,

  /// Ciśnienie bezwzględne w kPa → nadciśnienie względem atmosfery w bar
  /// (z użyciem zmierzonego ciśnienia barometrycznego PID 33).
  absKpaToRelBar,
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

  /// Dekoder bajtów danych (bez bajtu usługi i numeru PID). Zwraca NaN,
  /// gdy danych brakuje lub ECU zgłasza, że ta wartość nie jest obsługiwana.
  final double Function(List<int> bytes) decoder;

  final PollRate rate;
  final ValueTransform transform;

  /// Odpowiedź zawiera bajt maski obsługi (PIDy wielowartościowe J1979, np. 70, 6D, 71).
  /// Takie PIDy są sprawdzane przy połączeniu, bo sam bit w masce 0100 nie gwarantuje,
  /// że ECU podaje konkretną wartość (np. zadane doładowanie).
  final bool hasSupportByte;

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
    this.rate = PollRate.normal,
    this.transform = ValueTransform.none,
    this.hasSupportByte = false,
  });

  /// Komenda wysyłana do adaptera (dla PIDów producenta nadpisywana).
  String get command => code;

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

  // ---------------------------------------------------------------------------
  // Pomocnicze dekodery
  // ---------------------------------------------------------------------------

  static double _u8(List<int> b, int i, double Function(int a) f) => b.length > i ? f(b[i]) : double.nan;

  static double _u16(List<int> b, int i, double Function(int v) f) =>
      b.length > i + 1 ? f((b[i] << 8) | b[i + 1]) : double.nan;

  /// PID wielowartościowy: bajt 0 = maska obsługi; wartość tylko gdy [bit] ustawiony.
  static double _sup8(List<int> b, int bit, int i, double Function(int a) f) =>
      b.isNotEmpty && (b[0] & (1 << bit)) != 0 ? _u8(b, i, f) : double.nan;

  static double _sup16(List<int> b, int bit, int i, double Function(int v) f) =>
      b.isNotEmpty && (b[0] & (1 << bit)) != 0 ? _u16(b, i, f) : double.nan;

  static double _pct(int a) => a * 100.0 / 255.0;

  /// Standardowy katalog parametrów OBD-II (SAE J1979, Mode 01 + Mode 06).
  ///
  /// Kilka wpisów może mieć tę samą nazwę (np. BOOST) — to alternatywne źródła
  /// w kolejności preferencji. Po połączeniu używane jest pierwsze, które ECU
  /// faktycznie obsługuje. Kilka wpisów może też mieć ten sam kod (np. 0170
  /// daje zadane i rzeczywiste doładowanie) — wtedy jedno zapytanie zasila
  /// kilka kanałów.
  static final List<ObdPid> standardPids = [
    // --- Silnik ---
    ObdPid(
      code: "010C", shortName: "RPM", name: "Obroty silnika", unit: "obr/min",
      category: PidCategory.engine, colorValue: 0xFF3A86FF, minExpected: 0, maxExpected: 7500,
      rate: PollRate.fast,
      decoder: (b) => _u16(b, 0, (v) => v / 4.0),
    ),
    ObdPid(
      code: "010D", shortName: "SPEED", name: "Prędkość pojazdu", unit: "km/h",
      category: PidCategory.engine, colorValue: 0xFF9D4EDD, minExpected: 0, maxExpected: 280,
      decoder: (b) => _u8(b, 0, (a) => a.toDouble()),
    ),
    ObdPid(
      code: "0104", shortName: "LOAD", name: "Obciążenie silnika", unit: "%",
      category: PidCategory.engine, colorValue: 0xFF06D6A0, minExpected: 0, maxExpected: 100,
      rate: PollRate.fast,
      decoder: (b) => _u8(b, 0, _pct),
    ),
    // Pedał gazu — w dieslach TPS to klapa dławiąca (prawie zawsze otwarta),
    // więc do wykrywania pełnego gazu potrzebny jest pedał.
    ObdPid(
      code: "015A", shortName: "PEDAL", name: "Pedał gazu (względny)", unit: "%",
      category: PidCategory.engine, colorValue: 0xFFB5179E, minExpected: 0, maxExpected: 100,
      rate: PollRate.fast,
      decoder: (b) => _u8(b, 0, _pct),
    ),
    ObdPid(
      code: "0149", shortName: "PEDAL", name: "Pedał gazu (czujnik D)", unit: "%",
      category: PidCategory.engine, colorValue: 0xFFB5179E, minExpected: 0, maxExpected: 100,
      rate: PollRate.fast,
      // Czujnik D: ok. 15% w spoczynku, ok. 80% przy wciśniętym pedale → 0-100%
      decoder: (b) => _u8(b, 0, (a) => ((_pct(a) - 15.0) / 65.0 * 100.0).clamp(0.0, 100.0)),
    ),
    ObdPid(
      code: "0111", shortName: "TPS", name: "Położenie przepustnicy", unit: "%",
      category: PidCategory.engine, colorValue: 0xFF7000FF, minExpected: 0, maxExpected: 100,
      rate: PollRate.fast,
      decoder: (b) => _u8(b, 0, _pct),
    ),
    ObdPid(
      code: "0161", shortName: "TQ_DEMAND", name: "Moment żądany przez kierowcę", unit: "%",
      category: PidCategory.engine, colorValue: 0xFFFFD166, minExpected: -125, maxExpected: 130,
      decoder: (b) => _u8(b, 0, (a) => a - 125.0),
    ),
    ObdPid(
      code: "0162", shortName: "TQ_ACT", name: "Moment rzeczywisty", unit: "%",
      category: PidCategory.engine, colorValue: 0xFFEF476F, minExpected: -125, maxExpected: 130,
      decoder: (b) => _u8(b, 0, (a) => a - 125.0),
    ),
    ObdPid(
      code: "0163", shortName: "TQ_REF", name: "Moment referencyjny silnika", unit: "Nm",
      category: PidCategory.engine, colorValue: 0xFF118AB2, minExpected: 0, maxExpected: 1000,
      rate: PollRate.slow,
      decoder: (b) => _u16(b, 0, (v) => v.toDouble()),
    ),

    // --- Turbo i dolot ---
    // Doładowanie rzeczywiste: preferowany PID 70 (ta sama referencja co zadane),
    // potem rozszerzony MAP 87 (powyżej 255 kPa), na końcu klasyczny MAP 0B.
    ObdPid(
      code: "0170", shortName: "BOOST", name: "Doładowanie rzeczywiste", unit: "bar",
      category: PidCategory.turbo, colorValue: 0xFF00D2FF, minExpected: -0.8, maxExpected: 2.8,
      rate: PollRate.fast, transform: ValueTransform.absKpaToRelBar, hasSupportByte: true,
      decoder: (b) => _sup16(b, 1, 3, (v) => v / 32.0),
    ),
    ObdPid(
      code: "0187", shortName: "BOOST", name: "Doładowanie (MAP rozszerzony)", unit: "bar",
      category: PidCategory.turbo, colorValue: 0xFF00D2FF, minExpected: -0.8, maxExpected: 2.8,
      rate: PollRate.fast, transform: ValueTransform.absKpaToRelBar, hasSupportByte: true,
      decoder: (b) => _sup16(b, 0, 1, (v) => v / 32.0),
    ),
    ObdPid(
      code: "010B", shortName: "BOOST", name: "Doładowanie (MAP)", unit: "bar",
      category: PidCategory.turbo, colorValue: 0xFF00D2FF, minExpected: -0.8, maxExpected: 2.5,
      rate: PollRate.fast, transform: ValueTransform.absKpaToRelBar,
      decoder: (b) => _u8(b, 0, (a) => a.toDouble()),
    ),
    ObdPid(
      code: "0170", shortName: "TARGET_BOOST", name: "Doładowanie zadane (ECU)", unit: "bar",
      category: PidCategory.turbo, colorValue: 0xFF80FFDB, minExpected: -0.8, maxExpected: 2.8,
      rate: PollRate.fast, transform: ValueTransform.absKpaToRelBar, hasSupportByte: true,
      decoder: (b) => _sup16(b, 0, 1, (v) => v / 32.0),
    ),
    ObdPid(
      code: "0171", shortName: "VGT_CMD", name: "Kierownice turbiny VGT — zadane", unit: "%",
      category: PidCategory.turbo, colorValue: 0xFFF72585, minExpected: 0, maxExpected: 100,
      hasSupportByte: true,
      decoder: (b) => _sup8(b, 0, 1, _pct),
    ),
    ObdPid(
      code: "0171", shortName: "VGT_ACT", name: "Kierownice turbiny VGT — rzeczywiste", unit: "%",
      category: PidCategory.turbo, colorValue: 0xFFB5179E, minExpected: 0, maxExpected: 100,
      hasSupportByte: true,
      decoder: (b) => _sup8(b, 1, 2, _pct),
    ),
    ObdPid(
      code: "0172", shortName: "WG_CMD", name: "Wastegate — zadane", unit: "%",
      category: PidCategory.turbo, colorValue: 0xFFF72585, minExpected: 0, maxExpected: 100,
      hasSupportByte: true,
      decoder: (b) => _sup8(b, 0, 1, _pct),
    ),
    ObdPid(
      code: "0172", shortName: "WG_ACT", name: "Wastegate — rzeczywiste", unit: "%",
      category: PidCategory.turbo, colorValue: 0xFFB5179E, minExpected: 0, maxExpected: 100,
      hasSupportByte: true,
      decoder: (b) => _sup8(b, 1, 2, _pct),
    ),
    ObdPid(
      code: "0174", shortName: "TURBO_RPM", name: "Obroty turbosprężarki", unit: "obr/min",
      category: PidCategory.turbo, colorValue: 0xFF4CC9F0, minExpected: 0, maxExpected: 250000,
      hasSupportByte: true,
      decoder: (b) => _sup16(b, 0, 1, (v) => v * 10.0),
    ),
    ObdPid(
      code: "0110", shortName: "MAF", name: "Przepływ powietrza (MAF)", unit: "g/s",
      category: PidCategory.turbo, colorValue: 0xFF00F5D4, minExpected: 0, maxExpected: 400,
      rate: PollRate.fast,
      decoder: (b) => _u16(b, 0, (v) => v / 100.0),
    ),
    ObdPid(
      code: "0166", shortName: "MAF", name: "Przepływ powietrza (MAF A)", unit: "g/s",
      category: PidCategory.turbo, colorValue: 0xFF00F5D4, minExpected: 0, maxExpected: 1000,
      rate: PollRate.fast, hasSupportByte: true,
      decoder: (b) => _sup16(b, 0, 1, (v) => v / 32.0),
    ),
    ObdPid(
      code: "010F", shortName: "IAT", name: "Temperatura w dolocie", unit: "°C",
      category: PidCategory.temperature, colorValue: 0xFF4CC9F0, minExpected: -20, maxExpected: 80,
      decoder: (b) => _u8(b, 0, (a) => a - 40.0),
    ),
    ObdPid(
      code: "0177", shortName: "CAC_T", name: "Temperatura za intercoolerem", unit: "°C",
      category: PidCategory.temperature, colorValue: 0xFF90E0EF, minExpected: -20, maxExpected: 100,
      hasSupportByte: true,
      decoder: (b) => _sup8(b, 0, 1, (a) => a - 40.0),
    ),
    ObdPid(
      code: "0133", shortName: "BARO", name: "Ciśnienie atmosferyczne", unit: "kPa",
      category: PidCategory.engine, colorValue: 0xFF8D99AE, minExpected: 70, maxExpected: 110,
      rate: PollRate.slow,
      decoder: (b) => _u8(b, 0, (a) => a.toDouble()),
    ),

    // --- Paliwo ---
    // Ciśnienie na szynie: PID 6D daje zadane i rzeczywiste (ta sama referencja),
    // w drugiej kolejności 23 (względne) i 59 (bezwzględne).
    ObdPid(
      code: "016D", shortName: "F_RAIL", name: "Ciśnienie na szynie — rzeczywiste", unit: "bar",
      category: PidCategory.fuel, colorValue: 0xFFE63946, minExpected: 0, maxExpected: 2500,
      rate: PollRate.fast, hasSupportByte: true,
      decoder: (b) => _sup16(b, 1, 3, (v) => v * 0.1),
    ),
    ObdPid(
      code: "0123", shortName: "F_RAIL", name: "Ciśnienie na szynie", unit: "bar",
      category: PidCategory.fuel, colorValue: 0xFFE63946, minExpected: 0, maxExpected: 2500,
      rate: PollRate.fast,
      decoder: (b) => _u16(b, 0, (v) => v * 0.1),
    ),
    ObdPid(
      code: "0159", shortName: "F_RAIL", name: "Ciśnienie na szynie (bezwzględne)", unit: "bar",
      category: PidCategory.fuel, colorValue: 0xFFE63946, minExpected: 0, maxExpected: 2500,
      rate: PollRate.fast,
      decoder: (b) => _u16(b, 0, (v) => v * 0.1),
    ),
    ObdPid(
      code: "016D", shortName: "RAIL_TGT", name: "Ciśnienie na szynie — zadane", unit: "bar",
      category: PidCategory.fuel, colorValue: 0xFFFFB3C1, minExpected: 0, maxExpected: 2500,
      rate: PollRate.fast, hasSupportByte: true,
      decoder: (b) => _sup16(b, 0, 1, (v) => v * 0.1),
    ),
    ObdPid(
      code: "015E", shortName: "FUEL_RATE", name: "Zużycie paliwa", unit: "l/h",
      category: PidCategory.fuel, colorValue: 0xFFFB8500, minExpected: 0, maxExpected: 60,
      decoder: (b) => _u16(b, 0, (v) => v / 20.0),
    ),
    ObdPid(
      code: "0134", shortName: "AFR", name: "Skład mieszanki (AFR)", unit: ":1",
      category: PidCategory.fuel, colorValue: 0xFFFF007F, minExpected: 10.0, maxExpected: 18.0,
      // Lambda = ((A*256)+B)/32768, AFR = Lambda * 14.7 (dla benzyny)
      decoder: (b) => _u16(b, 0, (v) => v / 32768.0 * 14.7),
    ),
    ObdPid(
      code: "0134", shortName: "LAMBDA", name: "Lambda (sonda szerokopasmowa)", unit: "λ",
      category: PidCategory.fuel, colorValue: 0xFFFF4D6D, minExpected: 0.7, maxExpected: 4.0,
      decoder: (b) => _u16(b, 0, (v) => v / 32768.0),
    ),
    ObdPid(
      code: "0124", shortName: "LAMBDA", name: "Lambda (sonda 1)", unit: "λ",
      category: PidCategory.fuel, colorValue: 0xFFFF4D6D, minExpected: 0.7, maxExpected: 4.0,
      decoder: (b) => _u16(b, 0, (v) => v / 32768.0),
    ),
    ObdPid(
      code: "0144", shortName: "LAMBDA_CMD", name: "Lambda zadana", unit: "λ",
      category: PidCategory.fuel, colorValue: 0xFFFFB3C6, minExpected: 0.7, maxExpected: 4.0,
      decoder: (b) => _u16(b, 0, (v) => v / 32768.0),
    ),
    ObdPid(
      code: "0106", shortName: "STFT", name: "Krótka korekta paliwa", unit: "%",
      category: PidCategory.fuel, colorValue: 0xFFFFBE0B, minExpected: -25, maxExpected: 25,
      decoder: (b) => _u8(b, 0, (a) => (a - 128.0) * 100.0 / 128.0),
    ),
    ObdPid(
      code: "0107", shortName: "LTFT", name: "Długa korekta paliwa", unit: "%",
      category: PidCategory.fuel, colorValue: 0xFFFB5607, minExpected: -25, maxExpected: 25,
      rate: PollRate.slow,
      decoder: (b) => _u8(b, 0, (a) => (a - 128.0) * 100.0 / 128.0),
    ),
    ObdPid(
      code: "0114", shortName: "O2_V", name: "Napięcie sondy lambda (B1S1)", unit: "V",
      category: PidCategory.fuel, colorValue: 0xFF8BC34A, minExpected: 0.0, maxExpected: 1.2,
      decoder: (b) => _u8(b, 0, (a) => a / 200.0),
    ),
    ObdPid(
      code: "012E", shortName: "EVAP_VP", name: "Elektrozawór EVAP (otwarcie)", unit: "%",
      category: PidCategory.fuel, colorValue: 0xFF00B4D8, minExpected: 0, maxExpected: 100,
      rate: PollRate.slow,
      decoder: (b) => _u8(b, 0, _pct),
    ),

    // --- Zapłon ---
    ObdPid(
      code: "010E", shortName: "IGN", name: "Wyprzedzenie zapłonu", unit: "°",
      category: PidCategory.ignition, colorValue: 0xFFFF9F1C, minExpected: -15, maxExpected: 45,
      rate: PollRate.fast,
      decoder: (b) => _u8(b, 0, (a) => a / 2.0 - 64.0),
    ),
    for (int cyl = 1; cyl <= 4; cyl++)
      ObdPid(
        code: "06${(0xA1 + cyl).toRadixString(16).toUpperCase()}", shortName: "MIS_$cyl",
        name: "Wypadanie zapłonu cyl. $cyl (licznik)", unit: "cnt",
        category: PidCategory.ignition, colorValue: 0xFFFF5722, minExpected: 0, maxExpected: 50,
        rate: PollRate.slow,
        // Mode 06: licznik wypadania zapłonów w bieżącym cyklu jazdy
        decoder: ObdPid.decodeMisfireCount,
      ),

    // --- Spaliny ---
    ObdPid(
      code: "0169", shortName: "EGR_CMD", name: "EGR — otwarcie zadane", unit: "%",
      category: PidCategory.exhaust, colorValue: 0xFF9C27B0, minExpected: 0, maxExpected: 100,
      hasSupportByte: true,
      decoder: (b) => _sup8(b, 0, 1, _pct),
    ),
    ObdPid(
      code: "012C", shortName: "EGR_CMD", name: "EGR — otwarcie zadane", unit: "%",
      category: PidCategory.exhaust, colorValue: 0xFF9C27B0, minExpected: 0, maxExpected: 100,
      decoder: (b) => _u8(b, 0, _pct),
    ),
    ObdPid(
      code: "0169", shortName: "EGR_ACT", name: "EGR — otwarcie rzeczywiste", unit: "%",
      category: PidCategory.exhaust, colorValue: 0xFFCE93D8, minExpected: 0, maxExpected: 100,
      hasSupportByte: true,
      decoder: (b) => _sup8(b, 1, 2, _pct),
    ),
    ObdPid(
      code: "012D", shortName: "EGR_ERR", name: "Błąd pozycjonowania EGR", unit: "%",
      category: PidCategory.exhaust, colorValue: 0xFFE91E63, minExpected: -100, maxExpected: 100,
      decoder: (b) => _u8(b, 0, (a) => a * 100.0 / 128.0 - 100.0),
    ),
    ObdPid(
      code: "017A", shortName: "DPF_DP", name: "Różnica ciśnień na DPF", unit: "kPa",
      category: PidCategory.exhaust, colorValue: 0xFFD00000, minExpected: 0, maxExpected: 80,
      rate: PollRate.fast, hasSupportByte: true,
      // Bajt A = maska obsługi, B-C = różnica ciśnień (ze znakiem) / 100 kPa
      decoder: (b) => _sup16(b, 0, 1, (v) => (v >= 0x8000 ? v - 0x10000 : v) / 100.0),
    ),
    ObdPid(
      code: "0173", shortName: "EXH_P", name: "Ciśnienie spalin (bezwzględne)", unit: "kPa",
      category: PidCategory.exhaust, colorValue: 0xFFFF6D00, minExpected: 90, maxExpected: 400,
      hasSupportByte: true,
      decoder: (b) => _sup16(b, 0, 1, (v) => v * 0.01),
    ),
    ObdPid(
      code: "0178", shortName: "EGT", name: "Temperatura spalin (EGT)", unit: "°C",
      category: PidCategory.exhaust, colorValue: 0xFFFF5400, minExpected: 100, maxExpected: 950,
      hasSupportByte: true,
      // Bajt A = maska czujników 1-4, potem 4 × 2 bajty (wartość/10 - 40); pierwszy obsługiwany
      decoder: (b) {
        if (b.length < 3) return double.nan;
        for (int s = 0; s < 4; s++) {
          if (b[0] & (1 << s) != 0 && b.length >= 3 + s * 2) {
            return ((b[1 + s * 2] << 8) | b[2 + s * 2]) / 10.0 - 40.0;
          }
        }
        return double.nan;
      },
    ),
    ObdPid(
      code: "017C", shortName: "DPF_T", name: "Temperatura przed DPF", unit: "°C",
      category: PidCategory.exhaust, colorValue: 0xFFFFA69E, minExpected: 100, maxExpected: 750,
      hasSupportByte: true,
      decoder: (b) => _sup16(b, 0, 1, (v) => v / 10.0 - 40.0),
    ),

    // --- Temperatury ---
    ObdPid(
      code: "0105", shortName: "ECT", name: "Temperatura płynu chłodzącego", unit: "°C",
      category: PidCategory.temperature, colorValue: 0xFF4361EE, minExpected: 40, maxExpected: 120,
      rate: PollRate.slow,
      decoder: (b) => _u8(b, 0, (a) => a - 40.0),
    ),
    ObdPid(
      code: "015C", shortName: "OIL_T", name: "Temperatura oleju", unit: "°C",
      category: PidCategory.temperature, colorValue: 0xFFFFC300, minExpected: 40, maxExpected: 140,
      rate: PollRate.slow,
      decoder: (b) => _u8(b, 0, (a) => a - 40.0),
    ),
  ];

  /// Zwraca pierwszy (preferowany) PID o danej nazwie
  static ObdPid? getByShortName(String shortName) {
    for (final p in standardPids) {
      if (p.shortName == shortName) return p;
    }
    return null;
  }

  /// Zwraca PID po kodzie hex
  static ObdPid? getByCode(String code) {
    for (final p in standardPids) {
      if (p.code.toUpperCase() == code.toUpperCase()) return p;
    }
    return null;
  }

  /// Pary „zadane → rzeczywiste” (do wykresów i analizy)
  static const Map<String, String> targetPairs = {
    "TARGET_BOOST": "BOOST",
    "RAIL_TGT": "F_RAIL",
    "VGT_CMD": "VGT_ACT",
    "WG_CMD": "WG_ACT",
    "EGR_CMD": "EGR_ACT",
    "LAMBDA_CMD": "LAMBDA",
    "TQ_DEMAND": "TQ_ACT",
  };
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
      id: "auto_diag",
      title: "Diagnostyka automatyczna (zalecane)",
      description: "Wszystko, czego potrzebuje Asystent: obroty, pedał, doładowanie zadane i rzeczywiste, przepływ powietrza, szyna paliwa, VGT, EGR, DPF, temperatury. Parametry nieobsługiwane przez auto są pomijane.",
      pidShortNames: [
        "RPM", "PEDAL", "TPS", "LOAD", "SPEED", "BOOST", "TARGET_BOOST", "MAF", "F_RAIL", "RAIL_TGT",
        "VGT_CMD", "VGT_ACT", "WG_CMD", "WG_ACT", "EGR_CMD", "EGR_ACT", "DPF_DP", "EXH_P", "EGT",
        "IAT", "CAC_T", "ECT", "BARO", "TQ_DEMAND", "TQ_ACT", "IGN", "STFT", "LTFT", "LAMBDA",
        "LAMBDA_CMD", "KNOCK_1", "KNOCK_2", "KNOCK_3", "KNOCK_4", "MIS_1", "MIS_2", "MIS_3", "MIS_4",
      ],
    ),
    const LoggingPreset(
      id: "wot_pull",
      title: "Pomiar przyspieszenia (maks. częstotliwość)",
      description: "Najmniej kanałów = najszybsze próbkowanie: obroty, pedał, doładowanie zadane i rzeczywiste, przepływ powietrza, zapłon/lambda.",
      pidShortNames: ["RPM", "PEDAL", "TPS", "BOOST", "TARGET_BOOST", "MAF", "IGN", "LAMBDA", "F_RAIL", "RAIL_TGT"],
    ),
    const LoggingPreset(
      id: "turbo_dpf",
      title: "Turbo, DPF i przepływ spalin",
      description: "Doładowanie zadane/rzeczywiste, VGT, przepływ powietrza, różnica ciśnień DPF, ciśnienie i temperatura spalin, EGR.",
      pidShortNames: ["RPM", "PEDAL", "TPS", "LOAD", "BOOST", "TARGET_BOOST", "MAF", "VGT_CMD", "VGT_ACT", "WG_CMD", "WG_ACT", "DPF_DP", "EXH_P", "EGT", "EGR_CMD", "EGR_ACT", "BARO"],
    ),
    const LoggingPreset(
      id: "fuel_ignition",
      title: "Paliwo, mieszanka i zapłon",
      description: "Szyna paliwa zadana/rzeczywista, lambda, korekty STFT/LTFT, kąt zapłonu, korekty stukowe i liczniki wypadania zapłonów.",
      pidShortNames: ["RPM", "PEDAL", "TPS", "LOAD", "F_RAIL", "RAIL_TGT", "LAMBDA", "LAMBDA_CMD", "AFR", "STFT", "LTFT", "IGN", "KNOCK_1", "KNOCK_2", "KNOCK_3", "KNOCK_4", "MIS_1", "MIS_2", "MIS_3", "MIS_4"],
    ),
    const LoggingPreset(
      id: "idle",
      title: "Wolne obroty (falowanie, VVT, EVAP)",
      description: "Obroty, podciśnienie w kolektorze, korekty paliwa, zawór EVAP i przepustnica.",
      pidShortNames: ["RPM", "BOOST", "STFT", "LTFT", "EVAP_VP", "TPS", "PEDAL", "IGN", "SPEED", "ECT"],
    ),
  ];
}
