import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/analysis/drive_analyzer.dart';
import '../models/log_point.dart';
import '../models/anomaly.dart';
import '../services/datalogger_service.dart';
import '../services/report_builder.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';
import '../widgets/vin_dialog.dart';
import '../models/engine_profiles.dart';
import '../models/engine_specs.dart';
import '../services/engine_memory.dart';
import '../services/fault_notes.dart';

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
            const SizedBox(height: 8),
            _VinRow(session: session),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _shareCustomerReport(context, session, anomalies),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text("Raport dla klienta"),
              ),
            ),
            const SizedBox(height: 12),
            _EngineCard(vin: session.vin, engineInfo: session.engineInfo),
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

  Future<void> _shareCustomerReport(
      BuildContext context, LogSession session, List<Anomaly> anomalies) async {
    final messenger = ScaffoldMessenger.of(context);
    final engine = context.read<EngineMemory>().resolveFor(session.vin, session.engineInfo);
    final userFaults = engine != null ? context.read<FaultNotes>().notesFor(engine.profile.code) : const <UserFault>[];
    final report = DiagnosisReport(session: session, anomalies: anomalies, engine: engine, userFaults: userFaults);
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final html = File("${dir.path}/dynomic_raport_$stamp.html");
      await html.writeAsString(report.toHtml());
      final txt = File("${dir.path}/dynomic_raport_$stamp.txt");
      await txt.writeAsString(report.toPlainText());
      await SharePlus.instance.share(ShareParams(
        files: [XFile(html.path), XFile(txt.path)],
        text: "Raport diagnostyczny Dynomic Diag",
      ));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Nie udało się przygotować raportu: $e"), backgroundColor: AppTheme.fault),
      );
    }
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
            if (session.hasBoostData) ...[
              div,
              cell("Maks. doładowanie", "${session.peakBoost.toStringAsFixed(2)} bar"),
            ],
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

/// Karta rozpoznanego silnika: pewność, na czym oparto, ręczny wybór (zapis pod VIN)
/// i znane słabości jednostki.
class _EngineCard extends StatelessWidget {
  final String vin;
  final String engineInfo;
  const _EngineCard({required this.vin, required this.engineInfo});

  static (String, Color) _confidence(EngineConfidence c) {
    switch (c) {
      case EngineConfidence.confirmed:
        return ("potwierdzony", AppTheme.ok);
      case EngineConfidence.high:
        return ("pewność wysoka", AppTheme.ok);
      case EngineConfidence.medium:
        return ("pewność średnia — potwierdź", AppTheme.warn);
      case EngineConfidence.low:
        return ("niepewne — wybierz ręcznie", AppTheme.warn);
    }
  }

  @override
  Widget build(BuildContext context) {
    final memory = context.watch<EngineMemory>();
    final match = memory.resolveFor(vin, engineInfo);
    final canRemember = vin.length >= 11;
    final spec = EngineSpecs.findInText(engineInfo);
    final faultNotes = context.watch<FaultNotes>();
    final code = match?.profile.code;
    final myFaults = code != null ? faultNotes.notesFor(code) : const <UserFault>[];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          leading: const Icon(Icons.build_circle_outlined, color: AppTheme.info),
          title: Text(match?.profile.name ?? "Silnik nierozpoznany",
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Builder(builder: (_) {
            if (match == null) {
              return const Text("Nie dopasowano do bazy — możesz wybrać ręcznie",
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12));
            }
            final (label, color) = _confidence(match.confidence);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  StatusDot(color, size: 7),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500)),
                ]),
                Text("na podstawie: ${match.basis}", style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
              ],
            );
          }),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (spec != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.info_outline, size: 16, color: AppTheme.textMuted),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text("Dane katalogowe (${spec.code}): ${spec.summary}",
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.35)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            if (match != null) ...[
              const SectionLabel("Znane słabości tego silnika (ogólne, nie z tego logu)"),
              for (final f in match.profile.faults)
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
              const SizedBox(height: 4),
            ],
            if (code != null) ...[
              const Divider(height: 20),
              Row(
                children: [
                  const Expanded(child: SectionLabel("Twoje notatki usterek (warsztat)")),
                  TextButton.icon(
                    onPressed: () => _addFault(context, faultNotes, code, match!.profile.name),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text("Dodaj"),
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                  ),
                ],
              ),
              if (myFaults.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text("Brak. Dopisz własne obserwacje — zbudujesz prywatną bazę usterek Dynomic.",
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                )
              else
                for (final f in myFaults)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("• ${f.title}", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                              if (f.note.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(left: 12, top: 1),
                                  child: Text(f.note, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.35)),
                                ),
                            ],
                          ),
                        ),
                        InkWell(
                          onTap: () => faultNotes.remove(code, f.id),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close, size: 16, color: AppTheme.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: 4),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canRemember ? () => _pick(context, memory) : null,
                    icon: const Icon(Icons.edit, size: 16),
                    label: Text(match == null ? "Wybierz silnik" : "Zmień silnik"),
                  ),
                ),
                if (match?.confidence == EngineConfidence.confirmed) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: "Zapomnij wybór",
                    onPressed: () {
                      memory.forget(vin);
                      context.read<DataloggerService>().reanalyze();
                    },
                  ),
                ],
              ],
            ),
            if (!canRemember)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text("Brak VIN w tym logu — wybór nie zostanie zapamiętany.",
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _addFault(BuildContext context, FaultNotes notes, String code, String engineName) async {
    final titleCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Nowa usterka — $engineName", style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: "Usterka (krótko)", hintText: "np. Rozciągnięty łańcuch rozrządu"),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtrl,
              textCapitalization: TextCapitalization.sentences,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: "Notatka (objawy, przebieg, naprawa)", hintText: "np. Stukanie na zimnym, błąd korelacji wałków przy ~180 tys. km"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Anuluj")),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Zapisz")),
        ],
      ),
    );
    if (ok == true) await notes.add(code, titleCtrl.text, noteCtrl.text);
  }

  Future<void> _pick(BuildContext context, EngineMemory memory) async {
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (_) => const _EnginePicker(),
    );
    if (code == null) return;
    await memory.remember(vin, code);
    if (context.mounted) context.read<DataloggerService>().reanalyze();
  }
}

class _EnginePicker extends StatefulWidget {
  const _EnginePicker();
  @override
  State<_EnginePicker> createState() => _EnginePickerState();
}

class _EnginePickerState extends State<_EnginePicker> {
  String _q = "";

  @override
  Widget build(BuildContext context) {
    final items = EngineProfiles.all
        .where((p) => _q.isEmpty || "${p.name} ${p.code} ${p.aliases.join(' ')}".toLowerCase().contains(_q.toLowerCase()))
        .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (ctx, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                labelText: "Szukaj silnika (nazwa lub kod, np. EA189, N47, 1.9 TDI)",
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: ListView.separated(
              controller: scroll,
              itemCount: items.length,
              separatorBuilder: (_, i) => const Divider(height: 1),
              itemBuilder: (_, i) => ListTile(
                dense: true,
                title: Text(items[i].name, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(items[i].code, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
                onTap: () => Navigator.pop(context, items[i].code),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// VIN zapisanego logu: podgląd albo „Dodaj VIN” (wpisanie / aparat), gdy sterownik go nie podał.
class _VinRow extends StatelessWidget {
  final LogSession session;
  const _VinRow({required this.session});

  @override
  Widget build(BuildContext context) {
    final hasVin = session.vin.length == 17;
    return Row(
      children: [
        Icon(hasVin ? Icons.directions_car_outlined : Icons.info_outline,
            size: 16, color: hasVin ? AppTheme.textMuted : AppTheme.warn),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            hasVin ? "VIN ${session.vin}" : "Brak VIN w tym logu — raport i rozpoznanie silnika będą uboższe",
            style: TextStyle(
              color: hasVin ? AppTheme.textSecondary : AppTheme.warn,
              fontSize: 12.5,
              fontFamily: hasVin ? "monospace" : null,
            ),
          ),
        ),
        TextButton(
          onPressed: () async {
            final vin = await showVinDialog(context, initial: hasVin ? session.vin : "");
            if (vin == null || !context.mounted) return;
            await context.read<DataloggerService>().setSessionVin(session, vin);
          },
          child: Text(hasVin ? "Zmień" : "Dodaj VIN"),
        ),
      ],
    );
  }
}
