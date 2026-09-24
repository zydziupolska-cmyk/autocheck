import 'extended_pid.dart';
import 'obd_pid.dart';
import '../services/torque_equation.dart';

/// Wynik importu pliku z definicjami.
class TorqueImportResult {
  final List<ExtendedPid> pids;
  final List<String> skipped; // opis pominiętych wierszy

  const TorqueImportResult(this.pids, this.skipped);
}

/// Import definicji parametrów w formacie Torque Pro (CSV):
/// `Name, ShortName, ModeAndPID, Equation, Min Value, Max Value, Units, Header`.
///
/// To najpopularniejszy format definicji rozszerzonych PIDów — społeczność ma
/// gotowe pliki dla setek modeli. Parametry, które da się jednoznacznie
/// rozpoznać po nazwie (doładowanie zadane/rzeczywiste, szyna paliwa, korekty
/// wtryskiwaczy, EGT, DPF…), trafiają do kanałów analizatora, pozostałe są
/// logowane pod własną nazwą.
class TorqueCsvImporter {
  static TorqueImportResult parse(String csv, {String sourceName = "import"}) {
    final pids = <ExtendedPid>[];
    final skipped = <String>[];
    final usedKeys = <String, int>{};

    for (final rawLine in csv.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final f = _splitCsv(line);
      if (f.length < 4) continue;
      final name = f[0];
      if (name.toLowerCase() == "name") continue; // wiersz nagłówka
      if (name.startsWith("~") || name.startsWith("!")) continue; // komentarze / pola wyliczane

      final shortName = f[1];
      final modePid = f[2].toUpperCase().replaceFirst("0X", "").replaceAll(" ", "");
      final equation = f[3];
      final minV = f.length > 4 ? double.tryParse(f[4]) : null;
      final maxV = f.length > 5 ? double.tryParse(f[5]) : null;
      final unit = f.length > 6 ? f[6] : "";
      final header = f.length > 7 ? f[7].toUpperCase().replaceAll(" ", "") : "";

      if (modePid.isEmpty || !RegExp(r'^[0-9A-F]{4,8}$').hasMatch(modePid) || modePid.length.isOdd) {
        skipped.add("$name: brak lub nieprawidłowe zapytanie „${f[2]}”");
        continue;
      }
      if (header.isNotEmpty && !RegExp(r'^[0-9A-F]{3}$|^[0-9A-F]{6}$|^[0-9A-F]{8}$').hasMatch(header)) {
        skipped.add("$name: nieobsługiwany nagłówek „$header”");
        continue;
      }
      final TorqueEquation eq;
      try {
        eq = TorqueEquation.parse(equation);
      } on TorqueEquationException catch (e) {
        skipped.add("$name: ${e.message}");
        continue;
      }

      final mapping = _mapToChannel(name, shortName, unit);
      var key = mapping?.key ?? "U_${_sanitize(shortName.isNotEmpty ? shortName : name)}";
      // Unikalna nazwa kanału w obrębie importu
      final n = (usedKeys[key] ?? 0) + 1;
      usedKeys[key] = n;
      if (n > 1) key = "${key}_$n";

      pids.add(ExtendedPid(
        profile: VehicleProfile.custom,
        requestCommand: modePid,
        canHeader: header.isEmpty ? null : header,
        kind: mapping?.kind ?? UdsValueKind.scaled,
        scale: mapping?.scale ?? 1,
        offset: mapping?.offset ?? 0,
        source: sourceName,
        originalName: name,
        code: modePid,
        shortName: key,
        name: mapping != null ? "${mapping.label} (${_clean(name)})" : _clean(name),
        unit: mapping?.unit ?? unit,
        category: mapping?.category ?? PidCategory.engine,
        colorValue: mapping?.color ?? 0xFF90A4AE,
        minExpected: mapping?.min ?? (minV ?? 0),
        maxExpected: mapping?.max ?? (maxV ?? 100),
        rate: mapping?.rate ?? PollRate.normal,
        decoder: eq.evaluate,
      ));
    }
    return TorqueImportResult(pids, skipped);
  }

  static String _clean(String name) => name.replaceFirst(RegExp(r'^\d{3}_'), "").trim();

  static String _sanitize(String s) =>
      s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), "_").replaceAll(RegExp(r'^_+|_+$'), "");

  /// Prosty podział wiersza CSV z obsługą cudzysłowów.
  static List<String> _splitCsv(String line) {
    final out = <String>[];
    final sb = StringBuffer();
    bool quoted = false;
    for (int i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (c == ',' && !quoted) {
        out.add(sb.toString().trim());
        sb.clear();
      } else {
        sb.write(c);
      }
    }
    out.add(sb.toString().trim());
    return out;
  }

  // ---------------------------------------------------------------------------
  // Rozpoznawanie parametrów po nazwie
  // ---------------------------------------------------------------------------

  static final _target = RegExp(r'target|specified|desired|set ?point|request|command|nominal|zadan|soll|vorgabe', caseSensitive: false);

  static int? _cylinder(String s) {
    final m = RegExp(r'(?:cyl(?:inder)?|zyl(?:inder)?|cylindr[a-z]*)\.?\s*#?\s*(\d)', caseSensitive: false).firstMatch(s);
    return m != null ? int.tryParse(m.group(1)!) : null;
  }

  static _Mapping? _mapToChannel(String name, String shortName, String unit) {
    final s = "$name $shortName";
    final u = unit.toLowerCase().replaceAll("°", "").trim();
    final isTarget = _target.hasMatch(s);
    final cyl = _cylinder(s);

    // Korekta wtryskiwacza / równomierność pracy poszczególnych cylindrów
    if (cyl != null && RegExp(r'inject|injection|wtrysk|einspritz|laufruhe|smooth running|balance|quantity (dev|corr)|mengenabweichung', caseSensitive: false).hasMatch(s)) {
      return _Mapping("INJ_CORR_$cyl", "Korekta wtryskiwacza cyl. $cyl", unit, PidCategory.fuel, 0xFFFFB703, -10, 10);
    }
    // Korekta stukowa / cofanie zapłonu na cylinder
    if (cyl != null && RegExp(r'knock|timing (corr|retard)|ignition (retard|angle retard)|klopf|zündwinkelrücknahme|stuk', caseSensitive: false).hasMatch(s)) {
      return _Mapping("KNOCK_$cyl", "Korekta stukowa cyl. $cyl", unit, PidCategory.ignition, 0xFFFF9F1C, -15, 2);
    }
    if (cyl != null && RegExp(r'misfire|wypadani|aussetzer', caseSensitive: false).hasMatch(s)) {
      return _Mapping("MIS_$cyl", "Wypadanie zapłonu cyl. $cyl", unit, PidCategory.ignition, 0xFFFF5722, 0, 50, rate: PollRate.slow);
    }

    // Doładowanie
    if (RegExp(r'boost|charge pressure|charge air pressure|doładowan|ladedruck|\bmap\b|manifold abs', caseSensitive: false).hasMatch(s) &&
        !RegExp(r'temp|valve|zawór|ventil|duty', caseSensitive: false).hasMatch(s)) {
      return _Mapping(isTarget ? "TARGET_BOOST" : "BOOST", isTarget ? "Doładowanie zadane" : "Doładowanie rzeczywiste",
          "bar", PidCategory.turbo, isTarget ? 0xFF80FFDB : 0xFF00D2FF, -0.8, 2.8,
          kind: UdsValueKind.boostPressure, rate: PollRate.fast);
    }
    // Ciśnienie paliwa na szynie
    if (RegExp(r'rail|fuel pressure|ciśnienie paliwa|kraftstoffdruck|raildruck|high pressure', caseSensitive: false).hasMatch(s) &&
        !RegExp(r'temp|valve|zawór|regulator|duty|current', caseSensitive: false).hasMatch(s)) {
      final factor = u == "kpa" ? 0.01 : u == "mpa" ? 10.0 : u == "psi" ? 0.0689476 : (u == "mbar" || u == "hpa") ? 0.001 : 1.0;
      return _Mapping(isTarget ? "RAIL_TGT" : "F_RAIL", isTarget ? "Ciśnienie paliwa zadane" : "Ciśnienie paliwa",
          "bar", PidCategory.fuel, isTarget ? 0xFFFFB3C1 : 0xFFE63946, 0, 2500, scale: factor, rate: PollRate.fast);
    }
    // Filtr DPF
    if (RegExp(r'dpf|particulate|\bfap\b|partikel|filtr cząstek', caseSensitive: false).hasMatch(s)) {
      if (RegExp(r'soot|sadz|ruß|russ|mass|load|masa', caseSensitive: false).hasMatch(s)) {
        return _Mapping("DPF_SOOT", "Zapełnienie DPF", unit, PidCategory.exhaust, 0xFF6C757D, 0, 100);
      }
      if (RegExp(r'differ|delta|pressure|ciśnien|druck', caseSensitive: false).hasMatch(s)) {
        final factor = (u == "mbar" || u == "hpa") ? 0.1 : u == "bar" ? 100.0 : u == "psi" ? 6.89476 : 1.0;
        return _Mapping("DPF_DP", "Różnica ciśnień DPF", "kPa", PidCategory.exhaust, 0xFFD00000, 0, 80, scale: factor, rate: PollRate.fast);
      }
    }
    // Temperatury
    final toC = u == "f" || u == "degf";
    if (RegExp(r'exhaust gas temp|\begt\b|temperatura spalin|abgastemp', caseSensitive: false).hasMatch(s)) {
      return _Mapping("EGT", "Temperatura spalin", "°C", PidCategory.exhaust, 0xFFFF5400, 100, 950,
          scale: toC ? 5 / 9 : 1, offset: toC ? -32 * 5 / 9 : 0);
    }
    if (RegExp(r'oil temp|temperatura oleju|öltemp', caseSensitive: false).hasMatch(s) &&
        !RegExp(r'trans|gear|skrzyn|getriebe|atf', caseSensitive: false).hasMatch(s)) {
      return _Mapping("OIL_T", "Temperatura oleju", "°C", PidCategory.temperature, 0xFFFFC300, 40, 140,
          scale: toC ? 5 / 9 : 1, offset: toC ? -32 * 5 / 9 : 0, rate: PollRate.slow);
    }
    // Turbina VGT / wastegate
    if (RegExp(r'\bvgt\b|\bvnt\b|guide vane|turbine (pos|vane)|turbo (vane|actuator)|kierownic|leitschaufel', caseSensitive: false).hasMatch(s)) {
      return _Mapping(isTarget ? "VGT_CMD" : "VGT_ACT", isTarget ? "Kierownice VGT — zadane" : "Kierownice VGT — rzeczywiste",
          "%", PidCategory.turbo, isTarget ? 0xFFF72585 : 0xFFB5179E, 0, 100);
    }
    if (RegExp(r'wastegate|waste gate', caseSensitive: false).hasMatch(s)) {
      return _Mapping(isTarget ? "WG_CMD" : "WG_ACT", isTarget ? "Wastegate — zadane" : "Wastegate — rzeczywiste",
          "%", PidCategory.turbo, isTarget ? 0xFFF72585 : 0xFFB5179E, 0, 100);
    }
    // EGR
    if (RegExp(r'\begr\b|exhaust gas recirc|recyrkulac|abgasrückf|\bagr\b', caseSensitive: false).hasMatch(s) &&
        RegExp(r'pos|valve|zawór|ventil|open|otwar|stellung', caseSensitive: false).hasMatch(s)) {
      return _Mapping(isTarget ? "EGR_CMD" : "EGR_ACT", isTarget ? "EGR — zadane" : "EGR — rzeczywiste",
          "%", PidCategory.exhaust, isTarget ? 0xFF9C27B0 : 0xFFCE93D8, 0, 100);
    }
    // Lambda
    if (RegExp(r'lambda', caseSensitive: false).hasMatch(s) && !RegExp(r'volt|current|heater|grzał|temp', caseSensitive: false).hasMatch(s)) {
      return _Mapping(isTarget ? "LAMBDA_CMD" : "LAMBDA", isTarget ? "Lambda zadana" : "Lambda", "λ", PidCategory.fuel,
          isTarget ? 0xFFFFB3C6 : 0xFFFF4D6D, 0.7, 4.0);
    }
    // Przepływ powietrza — tylko w g/s lub kg/h (mg/suw to inna wielkość)
    if (RegExp(r'air mass|mass air|\bmaf\b|luftmasse|masa powietrza', caseSensitive: false).hasMatch(s) && !isTarget) {
      if (u == "g/s") return _Mapping("MAF", "Przepływ powietrza", "g/s", PidCategory.turbo, 0xFF00F5D4, 0, 400, rate: PollRate.fast);
      if (u == "kg/h") return _Mapping("MAF", "Przepływ powietrza", "g/s", PidCategory.turbo, 0xFF00F5D4, 0, 400, scale: 1 / 3.6, rate: PollRate.fast);
    }
    return null;
  }
}

class _Mapping {
  final String key;
  final String label;
  final String unit;
  final PidCategory category;
  final int color;
  final double min;
  final double max;
  final UdsValueKind kind;
  final double scale;
  final double offset;
  final PollRate rate;

  _Mapping(this.key, this.label, this.unit, this.category, this.color, this.min, this.max,
      {this.kind = UdsValueKind.scaled, this.scale = 1, this.offset = 0, this.rate = PollRate.normal});
}
