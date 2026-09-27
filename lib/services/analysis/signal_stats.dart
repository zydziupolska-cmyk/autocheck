import 'dart:math';
import '../../models/log_point.dart';

/// Wspólne statystyki sygnałów dla reguł analizy — liczone na czasie, a nie liczbie próbek,
/// i odporne na wartości „brak danych” ze sterownika.
class SignalStats {
  static double median(List<double> v) {
    final s = [...v]..sort();
    return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
  }

  /// Percentyl q (0..1).
  static double pct(List<double> v, double q) {
    final s = [...v]..sort();
    return s[((s.length - 1) * q).round()];
  }

  /// Mediana odstępu między próbkami (ms). Szybki CAN: kilkanaście próbek/s,
  /// stare auta na K-line: poniżej 1/s.
  static double medianDtMs(List<LogPoint> pts) {
    final d = <double>[];
    for (int i = 1; i < pts.length; i++) {
      final dt = pts[i].timeMs - pts[i - 1].timeMs;
      if (dt > 0) d.add(dt);
    }
    return d.isEmpty ? 500 : median(d);
  }

  /// Łączny czas trwania próbek (sumuje odstępy nie dłuższe niż [maxGapMs]).
  static double durationMs(List<LogPoint> pts, double maxGapMs) {
    double t = 0;
    for (int i = 1; i < pts.length; i++) {
      final dt = pts[i].timeMs - pts[i - 1].timeMs;
      if (dt > 0 && dt <= maxGapMs) t += dt;
    }
    return t;
  }

  /// Prawidłowa korekta paliwa. Sterowniki ograniczają korektę do ok. ±25–35%, więc wartości
  /// powyżej ±50% to „brak danych” (np. 0xFF = +99,2% w pętli otwartej) albo śmieci odczytu.
  static double? validTrim(LogPoint p, String key) {
    final v = p.values[key];
    if (v == null || !v.isFinite || v.abs() > 50.0) return null;
    return v;
  }

  /// Suma prawidłowych korekt (STFT + LTFT) albo null, gdy żadnej nie ma.
  static double? totalTrim(LogPoint p) {
    final st = validTrim(p, "STFT");
    final lt = validTrim(p, "LTFT");
    if (st == null && lt == null) return null;
    return (st ?? 0) + (lt ?? 0);
  }

  /// Liczba zmian kierunku obrotów (szczyt ↔ dołek) z histerezą — odróżnia falowanie
  /// od jednostajnego spadku obrotów.
  static int rpmReversals(List<LogPoint> w, {double hysteresis = 80}) {
    if (w.length < 3) return 0;
    int reversals = 0;
    int dir = 0;
    double extreme = w.first.rpm;
    for (final p in w.skip(1)) {
      if (dir >= 0 && p.rpm > extreme) {
        extreme = p.rpm;
        dir = 1;
      } else if (dir <= 0 && p.rpm < extreme) {
        extreme = p.rpm;
        dir = -1;
      } else if (dir == 1 && extreme - p.rpm >= hysteresis) {
        reversals++;
        dir = -1;
        extreme = p.rpm;
      } else if (dir == -1 && p.rpm - extreme >= hysteresis) {
        reversals++;
        dir = 1;
        extreme = p.rpm;
      }
    }
    return reversals;
  }

  /// Rozrzut obrotów odporny na pojedyncze skoki: percentyl 95 − percentyl 5.
  static double rpmSpread(List<LogPoint> pts) {
    if (pts.length < 2) return 0;
    final r = [for (final p in pts) p.rpm];
    return max(0, pct(r, 0.95) - pct(r, 0.05));
  }
}
