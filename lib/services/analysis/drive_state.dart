import 'dart:math';
import '../../models/log_point.dart';

/// Klasyfikacja stanu jazdy na podstawie bieżących wartości czujników.
/// Wspólna dla rejestratora (wykrywanie przyspieszenia na żywo) i analizatora.
class DriveState {
  /// Żądanie kierowcy w %: pedał gazu, a gdy go brak — przepustnica (tylko
  /// benzyna; w dieslu TPS to klapa dławiąca, prawie zawsze otwarta).
  static double? driverDemand(Map<String, double> v, {required bool isDiesel}) {
    if (v.containsKey("PEDAL")) return v["PEDAL"];
    if (!isDiesel && v.containsKey("TPS")) return v["TPS"];
    return null;
  }

  /// Pełny gaz: pedał/przepustnica ≥ 80%, a bez nich obciążenie ≥ 85%.
  static bool isFullThrottle(Map<String, double> v, {required bool isDiesel}) {
    final demand = driverDemand(v, isDiesel: isDiesel);
    if (demand != null) return demand >= 80.0;
    final load = v["LOAD"];
    return load != null && load >= 85.0;
  }

  /// Gaz zdjęty (koniec przyspieszenia): pedał < 50%, bez pedału obciążenie < 60%.
  static bool isThrottleReleased(Map<String, double> v, {required bool isDiesel}) {
    final demand = driverDemand(v, isDiesel: isDiesel);
    if (demand != null) return demand < 50.0;
    final load = v["LOAD"];
    return load != null && load < 60.0;
  }

  /// Bieg jałowy: silnik pracuje, gaz puszczony, auto stoi (jeśli znamy prędkość).
  static bool isIdle(Map<String, double> v, {required bool isDiesel}) {
    final rpm = v["RPM"];
    if (rpm == null || rpm < 400 || rpm > 1300) return false;
    final speed = v["SPEED"];
    if (speed != null && speed > 3) return false;
    final demand = driverDemand(v, isDiesel: isDiesel);
    return demand == null || demand <= 10;
  }

  /// Typowe bezwzględne położenie przepustnicy (PID 11) przy pełnym gazie.
  static const double absThrottleFullOpen = 82;

  /// Położenie przepustnicy z OBD (PID 11) jest bezwzględne: przy puszczonym gazie wiele aut
  /// pokazuje 8–20% (np. Peugeot EW10 ok. 11%), przy pełnym 75–90%. Przeliczamy na otwarcie
  /// 0–100% względem wartości „zamkniętej” danego auta, żeby progi (wolne obroty, pełny gaz)
  /// działały w każdym samochodzie.
  static double throttleOpening(double tps, double closed, {double open = absThrottleFullOpen}) {
    final o = max(open, closed + 30);
    return ((tps - closed) / (o - closed) * 100).clamp(0.0, 100.0).toDouble();
  }

  /// Czy w tej chwili gaz na pewno jest puszczony: silnik pracuje na wolnych obrotach
  /// albo z bardzo małym obciążeniem (hamowanie silnikiem).
  static bool isThrottleClosedCandidate(Map<String, double> v) {
    final rpm = v["RPM"] ?? 0;
    if (rpm < 400) return false;
    final load = v["LOAD"];
    return rpm < 1100 || (load != null && load < 12);
  }

  /// Kopia wartości z przepustnicą przeliczoną na otwarcie (benzyna, gdy znamy położenie zamknięte).
  static Map<String, double> withThrottleOpening(Map<String, double> v, {double? closed, required bool isDiesel}) {
    final tps = v["TPS"];
    if (isDiesel || closed == null || tps == null || closed > 30) return v;
    return {...v, "TPS": throttleOpening(tps, closed)};
  }

  /// Przelicza przepustnicę w całym logu na otwarcie 0–100%. Położenie „zamknięte” to niski
  /// percentyl wartości przy pracującym silniku, „pełne” — większe z typowego i najwyższego
  /// zarejestrowanego. Diesel bez zmian (tam TPS to klapa dławiąca).
  static List<LogPoint> normalizeThrottle(List<LogPoint> pts, {required bool isDiesel}) {
    if (isDiesel) return pts;
    // Położenie zamknięte uczymy się tylko z chwil, gdy gaz na pewno jest puszczony
    // (wolne obroty albo bardzo małe obciążenie) — w logu z samą równą jazdą najniższa
    // wartość wcale nie oznacza zamkniętej przepustnicy.
    final closedSamples = [
      for (final p in pts)
        if (p.values["TPS"] != null && isThrottleClosedCandidate(p.values)) p.values["TPS"]!,
    ]..sort();
    if (closedSamples.length < 3) return pts;
    final closed = closedSamples[(closedSamples.length * 0.1).floor()];
    final running = [
      for (final p in pts)
        if (p.values["TPS"] != null && (p.values["RPM"] ?? 0) > 400) p.values["TPS"]!,
    ]..sort();
    if (closed <= 0.5 || closed > 30) return pts; // już względne albo nietypowe — bez zmian
    final open = max(absThrottleFullOpen, running[((running.length - 1) * 0.99).round()]);
    return [
      for (final p in pts)
        p.values.containsKey("TPS")
            ? LogPoint(timeMs: p.timeMs, values: {...p.values, "TPS": throttleOpening(p.values["TPS"]!, closed, open: open)})
            : p,
    ];
  }

  /// Uzupełnia brakujące wartości ostatnią znaną (max [maxAgeMs] wstecz).
  /// Logger odpytuje wolne parametry rzadziej, więc pojedyncze punkty mają
  /// tylko część kanałów — do analizy potrzebny jest pełny obraz w każdej chwili.
  static List<LogPoint> forwardFill(List<LogPoint> points, {double maxAgeMs = 3000}) {
    final last = <String, (double, double)>{}; // klucz → (wartość, czas)
    final out = <LogPoint>[];
    for (final p in points) {
      p.values.forEach((k, v) => last[k] = (v, p.timeMs));
      final values = <String, double>{};
      last.forEach((k, entry) {
        if (p.timeMs - entry.$2 <= maxAgeMs) values[k] = entry.$1;
      });
      out.add(LogPoint(timeMs: p.timeMs, values: values));
    }
    return out;
  }
}
