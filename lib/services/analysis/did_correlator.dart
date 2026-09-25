/// Automatyczne rozpoznanie znaczenia nieznanych DID-ów przez korelację z sygnałami,
/// które już znamy (standardowe OBD PID-y odczytane w tej samej sesji podsłuchu).
///
/// Idea za pracą TUMFTM „Holistic Approach for Automated Reverse-Engineering of UDS
/// Data" (Apache-2.0): zamiast ręcznie zgadywać, co znaczy DID, porównujemy jego
/// przebieg w czasie z przebiegiem znanego sygnału (RPM, prędkość, MAP, MAF…).
/// Jeśli nieznany bajt/para bajtów zmienia się liniowo razem ze znanym kanałem,
/// proponujemy: „to prawdopodobnie dany kanał, skala a, offset b (dopasowanie r)".
///
/// Wszystko liczone lokalnie (korelacja Pearsona + regresja liniowa), bez ML.
library;

import 'dart:math' as math;
import '../../models/obd_pid.dart';
import 'sniff_analyzer.dart';

/// Propozycja znaczenia nieznanego parametru.
class ChannelGuess {
  final LearnedParam param;
  final int byteOffset; // pozycja pierwszego bajtu wartości w danych DID
  final int byteLen; // 1 lub 2
  final bool signed;
  final String canonicalKey; // kanał odniesienia, np. "RPM", "BOOST"
  final String referenceTitle; // czytelny opis sygnału odniesienia
  final double r; // współczynnik korelacji (−1..1)
  final double scale; // wartość = scale * surowa + offset
  final double offset;
  final int points; // liczba sparowanych próbek

  const ChannelGuess({
    required this.param,
    required this.byteOffset,
    required this.byteLen,
    required this.signed,
    required this.canonicalKey,
    required this.referenceTitle,
    required this.r,
    required this.scale,
    required this.offset,
    required this.points,
  });

  /// Równanie w stylu Torque dla dopasowanych bajtów i skali.
  String get equation {
    final a = LearnedParam.byteName(byteOffset);
    final raw = byteLen == 2 ? "(($a*256)+${LearnedParam.byteName(byteOffset + 1)})" : a;
    final s = _fmt(scale);
    final b = offset.abs() < 1e-9 ? "" : (offset > 0 ? "+${_fmt(offset)}" : "-${_fmt(offset.abs())}");
    return "$raw*$s$b";
  }

  int get confidencePct => (r.abs() * 100).round();

  static String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(v.abs() < 1 ? 5 : 3);
  }
}

class DidCorrelator {
  /// Znajduje propozycje mapowań nieznanych DID-ów na znane kanały.
  /// [minR] — próg dopasowania, [minPoints] — minimalna liczba sparowanych próbek,
  /// [tolMs] — maks. różnica czasu przy parowaniu próbek.
  static List<ChannelGuess> analyze(
    List<LearnedParam> params, {
    double minR = 0.9,
    int minPoints = 8,
    int tolMs = 300,
  }) {
    final references = _buildReferences(params);
    if (references.isEmpty) return const [];

    final guesses = <ChannelGuess>[];
    for (final p in params) {
      if (!_isUnknown(p) || p.samples.length < minPoints) continue;
      final best = _bestForParam(p, references, minR, minPoints, tolMs);
      if (best != null) guesses.add(best);
    }
    guesses.sort((a, b) => b.r.abs().compareTo(a.r.abs()));
    return guesses;
  }

  static bool _isUnknown(LearnedParam p) =>
      p.kind == LearnedKind.udsDid || p.kind == LearnedKind.kwpLocalId;

  /// Zdekodowane szeregi odniesienia ze znanych OBD PID-ów odczytanych w sesji.
  static List<_Reference> _buildReferences(List<LearnedParam> params) {
    final refs = <_Reference>[];
    final seen = <String>{};
    for (final p in params) {
      if (p.kind != LearnedKind.obdPid) continue;
      final code = "01${p.idHex}";
      final pid = ObdPid.standardPids.where((o) => o.code == code).cast<ObdPid?>().firstWhere((_) => true, orElse: () => null);
      if (pid == null || seen.contains(pid.shortName)) continue;
      final series = <_Pt>[];
      for (final s in p.samples) {
        final v = pid.decoder(s.bytes);
        if (v.isFinite) series.add(_Pt(s.tMs, v));
      }
      if (_varies(series)) {
        refs.add(_Reference(pid.shortName, "${pid.name} (OBD ${pid.code})", series));
        seen.add(pid.shortName);
      }
    }
    return refs;
  }

  static ChannelGuess? _bestForParam(
      LearnedParam p, List<_Reference> refs, double minR, int minPoints, int tolMs) {
    final len = p.samples.map((s) => s.bytes.length).fold<int>(9999, (a, b) => a < b ? a : b);
    if (len == 0 || len == 9999) return null;

    ChannelGuess? best;
    // Kandydaci: każdy bajt (uint8) i każda para bajtów (uint16 BE), wersja bez/ze znakiem.
    for (int off = 0; off < len; off++) {
      for (final wide in [false, true]) {
        if (wide && off + 1 >= len) continue;
        final bl = wide ? 2 : 1;
        for (final signed in [false, true]) {
          final cand = <_Pt>[
            for (final s in p.samples) _Pt(s.tMs, _raw(s.bytes, off, bl, signed).toDouble()),
          ];
          if (!_varies(cand)) continue;
          for (final ref in refs) {
            final paired = _pair(cand, ref.series, tolMs);
            if (paired.length < minPoints) continue;
            final r = _pearson(paired);
            if (r.abs() < minR) continue;
            if (best == null || r.abs() > best.r.abs()) {
              final fit = _linfit(paired); // ref = a*cand + b
              best = ChannelGuess(
                param: p,
                byteOffset: off,
                byteLen: bl,
                signed: signed,
                canonicalKey: ref.key,
                referenceTitle: ref.title,
                r: r,
                scale: fit.$1,
                offset: fit.$2,
                points: paired.length,
              );
            }
          }
        }
      }
    }
    return best;
  }

  static int _raw(List<int> b, int off, int len, bool signed) {
    if (len == 1) {
      final v = b[off];
      return signed && v >= 0x80 ? v - 0x100 : v;
    }
    final v = (b[off] << 8) | b[off + 1];
    return signed && v >= 0x8000 ? v - 0x10000 : v;
  }

  static bool _varies(List<_Pt> s) {
    if (s.length < 3) return false;
    final first = s.first.v;
    return s.any((p) => (p.v - first).abs() > 1e-9);
  }

  /// Paruje próbki kandydata z odniesieniem po najbliższym czasie (w granicy tolMs).
  static List<(double, double)> _pair(List<_Pt> cand, List<_Pt> ref, int tolMs) {
    final out = <(double, double)>[];
    int j = 0;
    for (final c in cand) {
      // przesuwamy wskaźnik referencji do najbliższego czasu
      while (j + 1 < ref.length && (ref[j + 1].t - c.t).abs() <= (ref[j].t - c.t).abs()) {
        j++;
      }
      // szukamy też w tył, gdyby cofnięcie było bliżej (referencja niesortowana idealnie)
      int bestIdx = j;
      int bestDt = (ref[j].t - c.t).abs();
      for (final k in [j - 1, j + 1]) {
        if (k >= 0 && k < ref.length) {
          final dt = (ref[k].t - c.t).abs();
          if (dt < bestDt) {
            bestDt = dt;
            bestIdx = k;
          }
        }
      }
      if (bestDt <= tolMs) out.add((c.v, ref[bestIdx].v));
    }
    return out;
  }

  static double _pearson(List<(double, double)> pts) {
    final n = pts.length;
    double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0;
    for (final (x, y) in pts) {
      sx += x;
      sy += y;
      sxx += x * x;
      syy += y * y;
      sxy += x * y;
    }
    final cov = n * sxy - sx * sy;
    final dx = n * sxx - sx * sx;
    final dy = n * syy - sy * sy;
    if (dx <= 0 || dy <= 0) return 0;
    return cov / (math.sqrt(dx) * math.sqrt(dy));
  }

  /// Regresja liniowa y = a*x + b (metoda najmniejszych kwadratów).
  static (double, double) _linfit(List<(double, double)> pts) {
    final n = pts.length;
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (final (x, y) in pts) {
      sx += x;
      sy += y;
      sxx += x * x;
      sxy += x * y;
    }
    final den = n * sxx - sx * sx;
    if (den == 0) return (1.0, 0.0);
    final a = (n * sxy - sx * sy) / den;
    final b = (sy - a * sx) / n;
    return (a, b);
  }

}

class _Pt {
  final int t;
  final double v;
  const _Pt(this.t, this.v);
}

class _Reference {
  final String key;
  final String title;
  final List<_Pt> series;
  const _Reference(this.key, this.title, this.series);
}
