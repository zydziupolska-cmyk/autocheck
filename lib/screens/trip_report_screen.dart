import 'package:flutter/material.dart';
import '../models/trip_report.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';
import 'diagnostic_screen.dart';

class TripReportScreen extends StatelessWidget {
  final TripReport report;

  const TripReportScreen({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Raport z trasy")),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _header(),
          const SizedBox(height: 16),
          _stats(),
          if (report.aggregatedAnomalies.isNotEmpty) ...[
            const SizedBox(height: 20),
            const SectionLabel("Wykryte problemy"),
            for (final agg in report.aggregatedAnomalies) _anomalyCard(agg),
          ],
        ],
      ),
    );
  }

  Widget _header() {
    final Color tone;
    final String status;
    final String subtitle;
    if (report.criticalCondition) {
      tone = AppTheme.fault;
      status = "Wykryto poważne usterki";
      subtitle = "Auto wymaga wizyty w warsztacie.";
    } else if (report.needsAttention) {
      tone = AppTheme.warn;
      status = "Wymaga uwagi";
      subtitle = "Problemy, które mogą wpływać na spalanie lub moc.";
    } else {
      tone = AppTheme.ok;
      status = "Bez usterek";
      subtitle = "W trakcie jazdy nie wykryto przewlekłych usterek.";
    }
    return Panel(
      stripe: tone,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status, style: AppTheme.sectionTitle.copyWith(fontSize: 17)),
                const SizedBox(height: 4),
                Text(subtitle, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Readout(label: "Ocena", value: "${report.healthScore}", unit: "/100", size: 26),
        ],
      ),
    );
  }

  Widget _stats() {
    final items = [
      ("Czas", "${report.duration.inMinutes}", "min"),
      ("Dystans (szac.)", report.distanceKm.toStringAsFixed(1), "km"),
      ("Maks. obroty", report.maxRpm.toStringAsFixed(0), "obr/min"),
      ("Maks. doładowanie", report.maxBoostBar.toStringAsFixed(2), "bar"),
      ("Maks. temp. płynu", report.maxEctC.toStringAsFixed(0), "°C"),
      ("Śr. korekta LTFT", report.avgLtft.toStringAsFixed(1), "%"),
    ];
    final rows = <Widget>[];
    for (int i = 0; i < items.length; i += 2) {
      if (i > 0) rows.add(const Divider());
      rows.add(IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (j, it) in items.sublist(i, i + 2).indexed) ...[
              if (j > 0) const VerticalDivider(width: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Readout(label: it.$1, value: it.$2, unit: it.$3, size: 18),
                ),
              ),
            ],
          ],
        ),
      ));
    }
    return Panel(padding: EdgeInsets.zero, child: Column(children: rows));
  }

  Widget _anomalyCard(AggregatedAnomaly agg) {
    final a = agg.sample;
    final tone = DiagnosticScreen.toneOf(a.severity);
    return Panel(
      margin: const EdgeInsets.only(bottom: 10),
      stripe: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(DiagnosticScreen.severityLabel(a.severity),
                  style: TextStyle(color: tone, fontSize: 11.5, fontWeight: FontWeight.w600)),
              if (agg.occurrenceCount > 1)
                Text("  •  ${agg.occurrenceCount}× w trakcie jazdy",
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
            ],
          ),
          const SizedBox(height: 4),
          Text(a.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(a.plainSummary ?? a.description, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          if (a.recommendations.isNotEmpty) ...[
            const SizedBox(height: 10),
            const SectionLabel("Co sprawdzić"),
            for (final (i, r) in a.recommendations.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text("${i + 1}. $r", style: const TextStyle(fontSize: 13)),
              ),
          ],
        ],
      ),
    );
  }
}
