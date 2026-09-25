import '../models/anomaly.dart';
import '../models/engine_profiles.dart';
import '../models/log_point.dart';

/// Raport z diagnozy dla klienta warsztatu.
///
/// Buduje czytelny dokument z podsumowaniem pomiaru, wykrytymi usterkami
/// (prostym językiem, z krokami do sprawdzenia) i znanymi słabościami silnika.
/// Zwraca wersję tekstową i HTML — HTML wygląda profesjonalnie i można go na
/// telefonie wydrukować do PDF albo wysłać klientowi.
class DiagnosisReport {
  final LogSession session;
  final List<Anomaly> anomalies;
  final EngineMatch? engine;
  final String workshopName;
  final DateTime generatedAt;

  DiagnosisReport({
    required this.session,
    required this.anomalies,
    this.engine,
    this.workshopName = "Dynomic",
    DateTime? generatedAt,
  }) : generatedAt = generatedAt ?? DateTime.now();

  bool get hasCritical => anomalies.any((a) => a.severity == AnomalySeverity.critical);
  bool get hasIssues => anomalies.isNotEmpty;

  String get _verdict {
    if (hasCritical) return "Wykryto poważną usterkę wymagającą naprawy";
    if (hasIssues) return "Wykryto nieprawidłowości wymagające uwagi";
    return "Nie wykryto usterek w zarejestrowanych parametrach";
  }

  static String _sevLabel(AnomalySeverity s) {
    switch (s) {
      case AnomalySeverity.critical:
        return "Usterka";
      case AnomalySeverity.warning:
        return "Ostrzeżenie";
      case AnomalySeverity.tampering:
        return "Ingerencja w układ";
      case AnomalySeverity.info:
        return "Informacja";
    }
  }

  static String _d(DateTime t) =>
      "${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year} "
      "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";

  // ---------------------------------------------------------------- tekst
  String toPlainText() {
    final b = StringBuffer();
    b.writeln("RAPORT DIAGNOSTYCZNY — $workshopName");
    b.writeln("Data: ${_d(generatedAt)}");
    b.writeln();
    b.writeln("POJAZD");
    if (session.vehicleLabel != null) b.writeln("  ${session.vehicleLabel}");
    if (session.vin.isNotEmpty) b.writeln("  VIN: ${session.vin}");
    if (engine != null) b.writeln("  Silnik: ${engine!.profile.name}");
    b.writeln();
    b.writeln("POMIAR");
    b.writeln("  Tryb: ${session.mode == LogMode.pull ? 'Przyspieszenie' : 'Jazda diagnostyczna'}");
    b.writeln("  Czas: ${session.durationSec.toStringAsFixed(1)} s");
    b.writeln("  Maks. obroty: ${session.peakRpm.toInt()} obr/min");
    b.writeln("  Maks. doładowanie: ${session.peakBoost.toStringAsFixed(2)} bar");
    b.writeln();
    b.writeln("WYNIK: $_verdict");
    b.writeln();
    if (hasIssues) {
      b.writeln("WYKRYTE USTERKI (${anomalies.length})");
      for (final a in anomalies) {
        b.writeln();
        b.writeln("• [${_sevLabel(a.severity)}] ${a.title}");
        b.writeln("  ${a.observedValueText}");
        if (a.plainSummary != null) b.writeln("  ${a.plainSummary}");
        if (a.engineNote != null) b.writeln("  ${a.engineNote}");
        if (a.recommendations.isNotEmpty) {
          b.writeln("  Do sprawdzenia:");
          for (final (i, r) in a.recommendations.indexed) {
            b.writeln("    ${i + 1}. $r");
          }
        }
      }
      b.writeln();
    }
    if (engine != null && engine!.profile.faults.isNotEmpty) {
      b.writeln("ZNANE SŁABOŚCI SILNIKA ${engine!.profile.name} (ogólne)");
      for (final f in engine!.profile.faults) {
        b.writeln("  • ${f.title} — ${f.note}");
      }
      b.writeln();
    }
    b.writeln("---");
    b.writeln("Raport na podstawie pomiaru parametrów pracy silnika. Nie zastępuje");
    b.writeln("oględzin mechanicznych. Wygenerowano w aplikacji Dynomic Diag.");
    return b.toString();
  }

  // ---------------------------------------------------------------- HTML
  static String _esc(String s) => s
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");

  String _sevColor(AnomalySeverity s) {
    switch (s) {
      case AnomalySeverity.critical:
        return "#E5484D";
      case AnomalySeverity.warning:
        return "#E2B340";
      case AnomalySeverity.tampering:
        return "#B08968";
      case AnomalySeverity.info:
        return "#5B8DEF";
    }
  }

  String toHtml() {
    final b = StringBuffer();
    b.writeln('<!doctype html><html lang="pl"><head><meta charset="utf-8">');
    b.writeln('<meta name="viewport" content="width=device-width, initial-scale=1">');
    b.writeln('<title>Raport diagnostyczny — $workshopName</title>');
    b.writeln('''<style>
      * { box-sizing: border-box; }
      body { font-family: -apple-system, Roboto, "Segoe UI", sans-serif; color: #16181B; margin: 0; padding: 24px; background: #fff; }
      .wrap { max-width: 760px; margin: 0 auto; }
      header { border-bottom: 3px solid #E51C1C; padding-bottom: 12px; margin-bottom: 20px; }
      header h1 { margin: 0; font-size: 22px; }
      header .brand { color: #E51C1C; font-weight: 800; letter-spacing: -0.3px; }
      header .date { color: #6B7178; font-size: 13px; margin-top: 4px; }
      h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: #6B7178; margin: 22px 0 8px; }
      .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 4px 16px; font-size: 14px; }
      .grid div b { color: #6B7178; font-weight: 500; }
      .verdict { padding: 12px 14px; border-radius: 8px; font-weight: 600; font-size: 15px; margin: 8px 0; }
      .finding { border: 1px solid #E5E7EB; border-left: 4px solid #ccc; border-radius: 8px; padding: 12px 14px; margin-bottom: 12px; }
      .finding .sev { font-size: 12px; font-weight: 700; }
      .finding h3 { margin: 4px 0; font-size: 16px; }
      .finding .obs { color: #444; font-size: 14px; }
      .finding .note { background: #F4F6F8; border-radius: 6px; padding: 8px 10px; margin-top: 8px; font-size: 13px; }
      ol { margin: 8px 0 0; padding-left: 20px; font-size: 14px; }
      li { margin-bottom: 3px; }
      .weak { font-size: 13.5px; margin-bottom: 6px; }
      .weak b { font-weight: 600; }
      footer { margin-top: 28px; border-top: 1px solid #E5E7EB; padding-top: 12px; color: #6B7178; font-size: 12px; }
      @media print { body { padding: 0; } .noprint { display: none; } }
    </style></head><body><div class="wrap">''');

    b.writeln('<header><h1><span class="brand">Dynomic</span> · Raport diagnostyczny</h1>'
        '<div class="date">Wygenerowano: ${_d(generatedAt)}</div></header>');

    b.writeln('<h2>Pojazd</h2><div class="grid">');
    if (session.vehicleLabel != null) b.writeln('<div><b>Pojazd:</b> ${_esc(session.vehicleLabel!)}</div>');
    if (session.vin.isNotEmpty) b.writeln('<div><b>VIN:</b> ${_esc(session.vin)}</div>');
    if (engine != null) b.writeln('<div><b>Silnik:</b> ${_esc(engine!.profile.name)}</div>');
    b.writeln('</div>');

    b.writeln('<h2>Pomiar</h2><div class="grid">'
        '<div><b>Tryb:</b> ${session.mode == LogMode.pull ? 'Przyspieszenie' : 'Jazda diagnostyczna'}</div>'
        '<div><b>Czas:</b> ${session.durationSec.toStringAsFixed(1)} s</div>'
        '<div><b>Maks. obroty:</b> ${session.peakRpm.toInt()} obr/min</div>'
        '<div><b>Maks. doładowanie:</b> ${session.peakBoost.toStringAsFixed(2)} bar</div>'
        '</div>');

    final vColor = hasCritical ? "#FDECEC;color:#B4232700" : hasIssues ? "#FBF3DF" : "#E7F3EA";
    final vText = hasCritical ? "#B42327" : hasIssues ? "#7A5B00" : "#1E6B33";
    b.writeln('<div class="verdict" style="background:${vColor.split(';').first};color:$vText">$_verdict</div>');

    if (hasIssues) {
      b.writeln('<h2>Wykryte usterki (${anomalies.length})</h2>');
      for (final a in anomalies) {
        final col = _sevColor(a.severity);
        b.writeln('<div class="finding" style="border-left-color:$col">');
        b.writeln('<div class="sev" style="color:$col">${_sevLabel(a.severity)}</div>');
        b.writeln('<h3>${_esc(a.title)}</h3>');
        b.writeln('<div class="obs">${_esc(a.observedValueText)}</div>');
        if (a.plainSummary != null) b.writeln('<div class="note">${_esc(a.plainSummary!)}</div>');
        if (a.engineNote != null) b.writeln('<div class="note">${_esc(a.engineNote!)}</div>');
        if (a.recommendations.isNotEmpty) {
          b.writeln('<ol>');
          for (final r in a.recommendations) {
            b.writeln('<li>${_esc(r)}</li>');
          }
          b.writeln('</ol>');
        }
        b.writeln('</div>');
      }
    }

    if (engine != null && engine!.profile.faults.isNotEmpty) {
      b.writeln('<h2>Znane słabości silnika ${_esc(engine!.profile.name)} (ogólne)</h2>');
      for (final f in engine!.profile.faults) {
        b.writeln('<div class="weak"><b>${_esc(f.title)}</b> — ${_esc(f.note)}</div>');
      }
    }

    b.writeln('<footer>Raport na podstawie pomiaru parametrów pracy silnika. '
        'Nie zastępuje oględzin mechanicznych. Wygenerowano w aplikacji Dynomic Diag.</footer>');
    b.writeln('</div></body></html>');
    return b.toString();
  }
}
