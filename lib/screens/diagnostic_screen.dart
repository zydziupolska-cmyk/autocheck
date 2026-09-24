import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/analysis/drive_analyzer.dart';
import '../models/log_point.dart';
import '../models/anomaly.dart';
import '../services/datalogger_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';
import '../models/engine_profiles.dart';

class DiagnosticScreen extends StatelessWidget {
  final void Function(int tabIndex)? onNavigateToTab;

  const DiagnosticScreen({super.key, this.onNavigateToTab});

  static Color toneOf(AnomalySeverity s) {
    switch (s) {
      case AnomalySeverity.critical:
        return AppTheme.fault;
      case AnomalySeverity.warning:
      case AnomalySeverity.tampering:
        return AppTheme.warn;
      case AnomalySeverity.info:
        return AppTheme.info;
    }
  }

  static String severityLabel(AnomalySeverity s) {
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

  @override
  Widget build(BuildContext context) {
    final logger = Provider.of<DataloggerService>(context);
    final anomalies = logger.detectedAnomalies;
    final session = logger.activeSession;
    final hasLog = session != null && session.points.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Diagnoza"),
        actions: [
          if (hasLog)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  anomalies.isEmpty ? "bez usterek" : "${anomalies.length} ${anomalies.length == 1 ? 'wynik' : 'wyniki'}",
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (!hasLog)
            const Notice("Brak logu do analizy. Nagraj jazdę w zakładce Rejestrator albo wybierz log w Historii.")
          else ...[
            _sessionSummary(session),
            const SizedBox(height: 12),
            ?_engineCard(session.engineInfo),
            if (anomalies.isEmpty)
              const Notice(
                "Parametry dostępne w tym logu nie wskazują usterki. Poniżej: czego ten log nie pozwolił ocenić.",
                tone: AppTheme.ok,
              )
            else
              for (final a in anomalies) AnomalyCard(anomaly: a, onShowChart: () => onNavigateToTab?.call(3)),
            for (final note in DriveAnalyzer.coverageNotes(session.points, isDiesel: session.isDiesel))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, color: AppTheme.textMuted, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(note, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Odniesienie: znane słabości rozpoznanego silnika (nie diagnoza z tego logu).
  Widget? _engineCard(String engineInfo) {
    final engine = EngineProfiles.detect(engineInfo);
    if (engine == null) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          leading: const Icon(Icons.build_circle_outlined, color: AppTheme.info),
          title: Text(engine.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text("Znane słabości tego silnika (${engine.faults.length}) — ogólne, nie z tego logu",
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in engine.faults)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("• ${f.title}", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 1),
                      child: Text(f.note, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.35)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sessionSummary(LogSession session) {
    Widget cell(String label, String value) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTheme.readout.copyWith(fontSize: 14.5)),
          ],
        ),
      ),
    );
    const div = VerticalDivider(width: 1);
    return Panel(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          children: [
            cell(session.mode == LogMode.pull ? "Przyspieszenie" : "Jazda", "${session.durationSec.toStringAsFixed(1)} s"),
            div,
            cell("Maks. obroty", "${session.peakRpm.toInt()}"),
            div,
            cell("Maks. doładowanie", "${session.peakBoost.toStringAsFixed(2)} bar"),
          ],
        ),
      ),
    );
  }
}

/// Karta wyniku diagnozy (używana też w arkuszu na wykresie).
class AnomalyCard extends StatefulWidget {
  final Anomaly anomaly;
  final VoidCallback? onShowChart;
  const AnomalyCard({super.key, required this.anomaly, this.onShowChart});

  @override
  State<AnomalyCard> createState() => _AnomalyCardState();
}

class _AnomalyCardState extends State<AnomalyCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final a = widget.anomaly;
    final onShowChart = widget.onShowChart;
    final tone = DiagnosticScreen.toneOf(a.severity);
    final conclusion = a.rootCauseConclusion?.split("\n") ?? const <String>[];
    final mainCause = conclusion.isNotEmpty ? conclusion.first : null;
    final evidence = conclusion
        .skip(1)
        .map((l) => l.replaceFirst(RegExp(r'^•\s*'), ""))
        .where((l) => l.trim().isNotEmpty)
        .toList();

    return Panel(
      margin: const EdgeInsets.only(bottom: 12),
      stripe: tone,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            StatusDot(tone, size: 7),
                            const SizedBox(width: 6),
                            Text(
                              DiagnosticScreen.severityLabel(a.severity),
                              style: TextStyle(color: tone, fontSize: 11.5, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                "${a.startSec.toStringAsFixed(1)}–${a.endSec.toStringAsFixed(1)} s • ${a.startRpm.toInt()}–${a.endRpm.toInt()} obr/min",
                                style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5, fontFeatures: AppTheme.tabular),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(a.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3)),
                        const SizedBox(height: 4),
                        Text(a.observedValueText, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                      ],
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: AppTheme.textMuted),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(),
                  const SizedBox(height: 12),
                  if (a.plainSummary != null) ...[
                    Text(a.plainSummary!, style: const TextStyle(fontSize: 14, height: 1.4)),
                    const SizedBox(height: 14),
                  ],
                  if (mainCause != null) ...[
                    const SectionLabel("Najbardziej prawdopodobna przyczyna"),
                    Text(mainCause, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.35)),
                    for (final e in evidence)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text("• $e", style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
                      ),
                    const SizedBox(height: 14),
                  ],
                  if (a.engineNote != null) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 1),
                          child: Icon(Icons.build_circle_outlined, size: 16, color: AppTheme.info),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(a.engineNote!, style: const TextStyle(color: AppTheme.info, fontSize: 12.5, height: 1.35))),
                      ],
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (a.falseLeadWarning != null) ...[
                    Notice(a.falseLeadWarning!, tone: AppTheme.warn),
                    const SizedBox(height: 14),
                  ],
                  if (a.correlatedSignals != null && a.correlatedSignals!.isNotEmpty) ...[
                    const SectionLabel("Pozostałe parametry w tym czasie"),
                    Panel(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (final (i, e) in a.correlatedSignals!.entries.indexed) ...[
                            if (i > 0) const Divider(),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 110,
                                    child: Text(e.key, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
                                  ),
                                  Expanded(
                                    child: Text(e.value, style: const TextStyle(fontSize: 12.5, fontFeatures: AppTheme.tabular)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (a.ruledOutCauses != null && a.ruledOutCauses!.isNotEmpty) ...[
                    const SectionLabel("Wykluczone"),
                    for (final ro in a.ruledOutCauses!)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(Icons.check, color: AppTheme.ok, size: 15),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(ro, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 10),
                  ],
                  if (a.hypotheses.isNotEmpty) ...[
                    const SectionLabel("Możliwe przyczyny"),
                    for (final h in a.hypotheses)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text("• $h", style: const TextStyle(fontSize: 13)),
                      ),
                    const SizedBox(height: 10),
                  ],
                  if (a.recommendations.isNotEmpty) ...[
                    const SectionLabel("Co sprawdzić"),
                    for (final (i, r) in a.recommendations.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 20,
                              child: Text(
                                "${i + 1}.",
                                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13, fontFeatures: AppTheme.tabular),
                              ),
                            ),
                            Expanded(child: Text(r, style: const TextStyle(fontSize: 13))),
                          ],
                        ),
                      ),
                    const SizedBox(height: 10),
                  ],
                  if (a.description.isNotEmpty) ...[
                    Text(a.description, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12.5, height: 1.4)),
                    const SizedBox(height: 12),
                  ],
                  if (onShowChart != null)
                    OutlinedButton.icon(
                      onPressed: onShowChart,
                      icon: const Icon(Icons.show_chart, size: 18),
                      label: const Text("Pokaż na wykresie"),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
