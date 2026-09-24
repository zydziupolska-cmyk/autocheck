import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/datalogger_service.dart';
import '../theme/app_theme.dart';

class LogsHistoryScreen extends StatelessWidget {
  final void Function(int tabIndex)? onNavigateToTab;

  const LogsHistoryScreen({super.key, this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    final logger = Provider.of<DataloggerService>(context);
    final history = logger.sessionsHistory;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.history, color: AppTheme.cyan),
            SizedBox(width: 8),
            Text("Zapisane Logi & Eksport CSV"),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Karta szybkiego eksportu aktywnego logu
            _buildExportCard(context, logger),

            const SizedBox(height: 20),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "HISTORIA SESJI POMIAROWYCH",
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                Text(
                  "${history.length} zapisanych",
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (history.isEmpty)
              _buildEmptyHistory()
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: history.length,
                itemBuilder: (context, index) {
                  final session = history[index];
                  final isSelected = logger.activeSession?.id == session.id;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: isSelected ? AppTheme.surfaceLight : AppTheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected ? AppTheme.cyan : AppTheme.border,
                        width: isSelected ? 1.5 : 1,
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      leading: CircleAvatar(
                        backgroundColor: AppTheme.blue.withAlpha(30),
                        child: const Icon(Icons.analytics, color: AppTheme.cyan),
                      ),
                      title: Text(
                        session.title,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 2),
                          Text(
                            DateFormat("dd.MM.yyyy HH:mm:ss").format(session.createdAt),
                            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "Czas: ${session.durationSec.toStringAsFixed(1)}s | Max Boost: ${session.peakBoost.toStringAsFixed(2)} bar | Max RPM: ${session.peakRpm.toInt()}",
                            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                          ),
                          if (session.vehicleLabel != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              "${session.vehicleLabel}${session.isDiesel ? ' • Diesel' : ''}",
                              style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
                            ),
                          ],
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.show_chart, color: AppTheme.cyan),
                            tooltip: "Wczytaj na wykres",
                            onPressed: () {
                              logger.selectSession(session);
                              onNavigateToTab?.call(3); // Idź do wykresu
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: AppTheme.textMuted),
                            tooltip: "Usuń log",
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: AppTheme.surface,
                                  title: const Text("Usunąć log?", style: TextStyle(color: AppTheme.textPrimary)),
                                  content: Text(session.title, style: const TextStyle(color: AppTheme.textSecondary)),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Anuluj")),
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text("Usuń", style: TextStyle(color: AppTheme.red)),
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
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildExportCard(BuildContext context, DataloggerService logger) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cyan.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.file_upload, color: AppTheme.cyan, size: 20),
              SizedBox(width: 8),
              Text(
                "Eksportuj do Tunera / PC (Format CSV)",
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            "Pliki CSV są w pełni zgodne z programami MegaLogViewer, Virtual Dyno, Excel oraz aplikacjami do chiptuningu.",
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: logger.currentPoints.isEmpty
                ? null
                : () async {
                    final path = await logger.exportAndShareCsv();
                    if (path != null && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("Wygenerowano plik CSV: $path"),
                          backgroundColor: AppTheme.green,
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.share),
            label: const Text("Udostępnij aktualny log (WhatsApp / E-mail / Dysk)"),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.cyan,
              foregroundColor: Colors.black,
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyHistory() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Center(
        child: Column(
          children: [
            Icon(Icons.history_toggle_off, color: AppTheme.textMuted, size: 40),
            SizedBox(height: 8),
            Text(
              "Brak zapisanych logów",
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
