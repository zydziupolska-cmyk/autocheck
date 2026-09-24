/// Nagranie ruchu na magistrali CAN (podsłuch innego testera, np. Autela na kablu Y).
///
/// Zapis tekstowy — łatwo go przejrzeć, wysłać i wczytać ponownie:
/// ```
/// # Dynomic Diag sniff v1
/// # start=2026-09-24T10:15:00.000
/// # ids=11
/// # label=Touran 1T 2.0 TDI
/// 120	7E0 03 22 F4 0C 55 55 55 55
/// 135	7E8 05 62 F4 0C 1A F8 AA AA
/// ```
library;

class SniffLine {
  final int tMs; // czas od początku nagrania
  final String raw; // linia z adaptera: nagłówek + bajty
  const SniffLine(this.tMs, this.raw);
}

class SniffRecording {
  final DateTime start;
  final bool extendedIds; // CAN 29-bit
  final String label;
  final List<SniffLine> lines;

  SniffRecording({required this.start, required this.extendedIds, this.label = "", List<SniffLine>? lines})
      : lines = lines ?? [];

  Duration get duration => lines.isEmpty ? Duration.zero : Duration(milliseconds: lines.last.tMs);

  String toText() {
    final sb = StringBuffer()
      ..writeln("# Dynomic Diag sniff v1")
      ..writeln("# start=${start.toIso8601String()}")
      ..writeln("# ids=${extendedIds ? 29 : 11}")
      ..writeln("# label=${label.replaceAll(RegExp(r'[\r\n]'), ' ')}");
    for (final l in lines) {
      sb.writeln("${l.tMs}\t${l.raw}");
    }
    return sb.toString();
  }

  /// Wczytuje zapis [toText]; akceptuje też surowy zrzut z terminala (same linie ATMA).
  static SniffRecording fromText(String text) {
    var start = DateTime.now();
    bool? extended;
    var label = "";
    final lines = <SniffLine>[];
    int autoT = 0;
    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith("#")) {
        final kv = line.substring(1).trim();
        if (kv.startsWith("start=")) start = DateTime.tryParse(kv.substring(6)) ?? start;
        if (kv.startsWith("ids=")) extended = kv.substring(4).trim() == "29";
        if (kv.startsWith("label=")) label = kv.substring(6).trim();
        continue;
      }
      final tab = line.indexOf("\t");
      if (tab > 0 && int.tryParse(line.substring(0, tab)) != null) {
        lines.add(SniffLine(int.parse(line.substring(0, tab)), line.substring(tab + 1).trim()));
      } else {
        lines.add(SniffLine(autoT, line));
        autoT += 10;
      }
    }
    // Brak nagłówka: 29-bit rozpoznajemy po pierwszej linii („18 DA F1 10 …”)
    extended ??= lines.isNotEmpty && RegExp(r'^[0-9A-Fa-f]{2}\s[0-9A-Fa-f]{2}\s[0-9A-Fa-f]{2}\s[0-9A-Fa-f]{2}\s').hasMatch(lines.first.raw) &&
        lines.first.raw.toUpperCase().startsWith("18 D");
    return SniffRecording(start: start, extendedIds: extended, label: label, lines: lines);
  }
}
