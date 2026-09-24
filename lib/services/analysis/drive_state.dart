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
