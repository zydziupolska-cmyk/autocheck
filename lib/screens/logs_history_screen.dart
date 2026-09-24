import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/datalogger_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';
import '../models/log_point.dart';

class LogsHistoryScreen extends StatelessWidget {
  final void Function(int tabIndex)? onNavigateToTab;

  const LogsHistoryScreen({super.key, this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    final logger = Provider.of<DataloggerService>(context);
    final history = logger.sessionsHistory;

    return Scaffold(
      appBar: AppBar(title: const Text("Historia")),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _buildExportCard(context, logger),
          const SizedBox(height: 20),
          SectionLabel("Zapisane logi (${history.length})"),
          if (history.isEmpty)
            const Notice("Brak zapisanych logów. Każdy pomiar z Rejestratora zapisuje się tu automatycznie.")
          else
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (int i = 0; i < history.length; i++) ...[
                    if (i > 0) const Divider(),
                    _sessionRow(context, logger, history[i]),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sessionRow(BuildContext context, DataloggerService logger, LogSession session) {
    final isSelected = logger.activeSession?.id == session.id;
    return Material(
      color: isSelected ? AppTheme.surfaceLight : Colors.transparent,
      child: InkWell(
        // Dotknięcie wybiera log (eksport, Diagnoza) bez przechodzenia na wykres
        onTap: logger.isRecording ? null : () => logger.selectSession(session),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              Container(width: 3, height: 40, color: isSelected ? AppTheme.accent : Colors.transparent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        DateFormat("dd.MM.yyyy HH:mm").format(session.createdAt),
                        "${session.durationSec.toStringAsFixed(1)} s",
                        "maks. ${session.peakRpm.toInt()} obr/min",
                        "${session.peakBoost.toStringAsFixed(2)} bar",
                      ].join(" • "),
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12, fontFeatures: AppTheme.tabular),
                    ),
                    if (session.vehicleLabel != null)
                      Text(
                        "${session.vehicleLabel}${session.isDiesel ? ' • diesel' : ''}",
                        style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.show_chart, size: 20),
                tooltip: "Pokaż na wykresie",
                onPressed: () {
                  logger.selectSession(session);
                  onNavigateToTab?.call(3);
                },
              ),
              IconButton(
                icon: const Icon(Icons.ios_share, size: 20),
                tooltip: "Eksportuj ten log (CSV)",
                onPressed: () => logger.exportAndShareCsv(session: session),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: "Usuń log",
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text("Usunąć log?"),
                      content: Text(session.title, style: const TextStyle(color: AppTheme.textSecondary)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Anuluj")),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text("Usuń", style: TextStyle(color: AppTheme.fault)),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) await logger.deleteSession(session);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExportCard(BuildContext context, DataloggerService logger) {
    final hasLog = logger.currentPoints.isNotEmpty;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text("Eksport CSV", style: AppTheme.sectionTitle),
          const SizedBox(height: 4),
          const Text(
            "Zgodny z MegaLogViewer, Virtual Dyno i Excelem.",
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          Text(
            hasLog
                ? "Wybrany: ${logger.isRecording ? 'bieżące nagranie' : logger.activeSession?.title ?? 'bieżące nagranie'}"
                : "Nie wybrano logu. Dotknij log na liście poniżej.",
            style: TextStyle(color: hasLog ? AppTheme.textPrimary : AppTheme.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: !hasLog
                ? null
                : () async {
                    final path = await logger.exportAndShareCsv();
                    if (path != null && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Zapisano plik: $path")));
                    }
                  },
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text("Udostępnij wybrany log"),
          ),
        ],
      ),
    );
  }
}
