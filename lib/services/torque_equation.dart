/// Interpreter równań w formacie Torque Pro (rozszerzone PIDy w plikach CSV).
///
/// Składnia (wielkość liter bez znaczenia):
/// * zmienne `A`..`Z`, `AA`..`AZ`, `BA`.. — kolejne bajty danych odpowiedzi
///   (po bajcie usługi i identyfikatorze, np. po `62 20 2A`),
/// * `+ - * /` i nawiasy, liczby dziesiętne,
/// * `<` i `>` — przesunięcie bitowe (w Torque `(A<8)+B` to `A*256+B`),
/// * `&` i `|` — operacje bitowe,
/// * `{A:7}` — pojedynczy bit bajtu,
/// * `SIGNED(A)` — bajt ze znakiem, `INT16(A:B)`/`INT24`/`INT32` — liczby ze znakiem
///   z kilku bajtów, `BIT(A:n)`, `ABS(x)`, `MAX(a:b)`, `MIN(a:b)`, `INT(x)`, `AVG(n:x)`.
///
/// Odwołania do innych parametrów (`val{...}`) nie są obsługiwane — takie
/// równania są odrzucane przy imporcie.
library;

class TorqueEquationException implements Exception {
  final String message;
  TorqueEquationException(this.message);
  @override
  String toString() => "Błąd równania: $message";
}

typedef _Eval = double Function(List<int> bytes);

class TorqueEquation {
  final String source;
  final _Eval _eval;

  /// Najwyższy indeks bajtu używany w równaniu (do oceny, czy odpowiedź jest kompletna).
  final int maxByteIndex;

  TorqueEquation._(this.source, this._eval, this.maxByteIndex);

  /// Kompiluje równanie; rzuca [TorqueEquationException] przy nieobsługiwanej składni.
  factory TorqueEquation.parse(String source) {
    final parser = _Parser(_dropUnmatchedClosing(source));
    final eval = parser.parse();
    return TorqueEquation._(source, eval, parser.maxByteIndex);
  }

  /// Wylicza wartość; NaN, gdy w odpowiedzi brakuje bajtów.
  double evaluate(List<int> bytes) {
    if (maxByteIndex >= bytes.length) return double.nan;
    final v = _eval(bytes);
    return v.isFinite ? v : double.nan;
  }

  /// Usuwa niesparowane nawiasy i klamry zamykające — częste literówki w plikach
  /// społeczności, które Torque toleruje, np. „(Signed(BD)*256))+BE”, „{g:1} -1 * -1}”.
  static String _dropUnmatchedClosing(String s) {
    final sb = StringBuffer();
    int paren = 0, brace = 0;
    for (final ch in s.split("")) {
      if (ch == "(") paren++;
      if (ch == "{") brace++;
      if (ch == ")") {
        if (paren == 0) continue;
        paren--;
      }
      if (ch == "}") {
        if (brace == 0) continue;
        brace--;
      }
      sb.write(ch);
    }
    return sb.toString();
  }

  /// Indeks bajtu dla nazwy zmiennej: A=0 … Z=25, AA=26 … AZ=51, BA=52 …
  static int? byteIndex(String name) {
    final n = name.toUpperCase();
    if (!RegExp(r'^[A-Z]{1,2}$').hasMatch(n)) return null;
    if (n.length == 1) return n.codeUnitAt(0) - 65;
    return (n.codeUnitAt(0) - 64) * 26 + (n.codeUnitAt(1) - 65);
  }
}

class _Parser {
  final String src;
  int pos = 0;
  int maxByteIndex = -1;

  _Parser(this.src);

  _Eval parse() {
    if (src.toLowerCase().contains("val{")) {
      throw TorqueEquationException("odwołania do innych parametrów (val{...}) nie są obsługiwane");
    }
    final e = _or();
    _skip();
    if (pos < src.length) throw TorqueEquationException("nieoczekiwany znak '${src[pos]}' w „$src”");
    return e;
  }

  void _skip() {
    while (pos < src.length && src[pos].trim().isEmpty) {
      pos++;
    }
  }

  bool _eat(String c) {
    _skip();
    if (pos < src.length && src[pos] == c) {
      pos++;
      return true;
    }
    return false;
  }

  _Eval _or() {
    var left = _and();
    while (_eat("|")) {
      final l = left, r = _and();
      left = (b) => (l(b).toInt() | r(b).toInt()).toDouble();
    }
    return left;
  }

  _Eval _and() {
    var left = _shift();
    while (_eat("&")) {
      final l = left, r = _shift();
      left = (b) => (l(b).toInt() & r(b).toInt()).toDouble();
    }
    return left;
  }

  _Eval _shift() {
    var left = _additive();
    while (true) {
      if (_eat("<")) {
        final l = left, r = _additive();
        left = (b) => (l(b).toInt() << r(b).toInt()).toDouble();
      } else if (_eat(">")) {
        final l = left, r = _additive();
        left = (b) => (l(b).toInt() >> r(b).toInt()).toDouble();
      } else {
        return left;
      }
    }
  }

  _Eval _additive() {
    var left = _multiplicative();
    while (true) {
      if (_eat("+")) {
        final l = left, r = _multiplicative();
        left = (b) => l(b) + r(b);
      } else if (_eat("-")) {
        final l = left, r = _multiplicative();
        left = (b) => l(b) - r(b);
      } else {
        return left;
      }
    }
  }

  _Eval _multiplicative() {
    var left = _unary();
    while (true) {
      if (_eat("*")) {
        final l = left, r = _unary();
        left = (b) => l(b) * r(b);
      } else if (_eat("/")) {
        final l = left, r = _unary();
        left = (b) => l(b) / r(b);
      } else {
        return left;
      }
    }
  }

  _Eval _unary() {
    if (_eat("-")) {
      final e = _unary();
      return (b) => -e(b);
    }
    if (_eat("+")) return _unary();
    return _primary();
  }

  _Eval _primary() {
    _skip();
    if (pos >= src.length) throw TorqueEquationException("niekompletne równanie „$src”");

    if (_eat("(")) {
      final e = _or();
      if (!_eat(")")) throw TorqueEquationException("brak nawiasu zamykającego w „$src”");
      return e;
    }

    // {A:7} — bit bajtu
    if (_eat("{")) {
      final m = RegExp(r'\s*([A-Za-z]{1,2})\s*:\s*(\d+)\s*\}').matchAsPrefix(src, pos);
      if (m == null) throw TorqueEquationException("nieobsługiwany zapis bitu w „$src”");
      pos = m.end;
      final idx = _useByte(m.group(1)!);
      final bit = int.parse(m.group(2)!);
      return (b) => ((b[idx] >> bit) & 1).toDouble();
    }

    // Liczba
    final num = RegExp(r'(\d+\.?\d*|\.\d+)').matchAsPrefix(src, pos);
    if (num != null) {
      pos = num.end;
      final v = double.parse(num.group(0)!);
      return (_) => v;
    }

    // Identyfikator: funkcja lub zmienna-bajt
    final id = RegExp(r'[A-Za-z_][A-Za-z0-9_]*').matchAsPrefix(src, pos);
    if (id == null) throw TorqueEquationException("nieoczekiwany znak '${src[pos]}' w „$src”");
    pos = id.end;
    final name = id.group(0)!.toUpperCase();

    _skip();
    if (pos < src.length && src[pos] == "(") {
      pos++;
      final args = <_Eval>[_or()];
      while (_eat(":") || _eat(",")) {
        args.add(_or());
      }
      if (!_eat(")")) throw TorqueEquationException("brak nawiasu zamykającego w „$src”");
      return _function(name, args);
    }

    final idx = TorqueEquation.byteIndex(name);
    if (idx == null) throw TorqueEquationException("nieznana zmienna „$name”");
    _useByte(name);
    return (b) => b[idx].toDouble();
  }

  int _useByte(String name) {
    final idx = TorqueEquation.byteIndex(name);
    if (idx == null) throw TorqueEquationException("nieznana zmienna „$name”");
    if (idx > maxByteIndex) maxByteIndex = idx;
    return idx;
  }

  _Eval _function(String name, List<_Eval> args) {
    switch (name) {
      case "SIGNED":
        final a = args.first;
        return (b) {
          final v = a(b).toInt();
          // Bajt lub słowo ze znakiem (U2)
          if (v <= 0xFF) return (v >= 0x80 ? v - 0x100 : v).toDouble();
          if (v <= 0xFFFF) return (v >= 0x8000 ? v - 0x10000 : v).toDouble();
          return v.toDouble();
        };
      case "ABS":
        final a = args.first;
        return (b) => a(b).abs();
      case "INT":
        final a = args.first;
        return (b) => a(b).truncateToDouble();
      case "INT16":
      case "INT24":
      case "INT32":
        // Liczba ze znakiem z kolejnych bajtów (od najstarszego), np. INT16(A:B)
        final bits = int.parse(name.substring(3));
        return (b) {
          int v = 0;
          for (final a in args) {
            v = (v << 8) | (a(b).toInt() & 0xFF);
          }
          final sign = 1 << (bits - 1);
          return (v >= sign ? v - (1 << bits) : v).toDouble();
        };
      case "BIT":
        // BIT(A:5) — bit numer 5 bajtu A
        if (args.length != 2) throw TorqueEquationException("BIT wymaga dwóch argumentów");
        return (b) => ((args[0](b).toInt() >> args[1](b).toInt()) & 1).toDouble();
      case "AVG":
        // AVG(n:x) w Torque to średnia krocząca z n próbek — logger zapisuje surowe próbki,
        // więc używamy bieżącej wartości (uśrednianie widać na wykresie)
        return args.last;
      case "MAX":
        return (b) => args.map((e) => e(b)).reduce((x, y) => x > y ? x : y);
      case "MIN":
        return (b) => args.map((e) => e(b)).reduce((x, y) => x < y ? x : y);
      default:
        throw TorqueEquationException("nieobsługiwana funkcja $name()");
    }
  }
}
