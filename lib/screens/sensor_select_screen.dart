import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import '../models/extended_pid.dart';
import '../services/pid_definitions_store.dart';
import '../models/obd_pid.dart';
import '../services/datalogger_service.dart';
import '../services/obd_service.dart';
import '../theme/app_theme.dart';

class SensorSelectScreen extends StatelessWidget {
  const SensorSelectScreen({super.key});

  static String _rateLabel(PollRate r) {
    switch (r) {
      case PollRate.fast:
        return "odczyt co cykl";
      case PollRate.normal:
        return "co 2 cykle";
      case PollRate.slow:
        return "wolny (co 8 cykli)";
    }
  }

  @override
  Widget build(BuildContext context) {
    final obd = Provider.of<ObdService>(context);
    final logger = Provider.of<DataloggerService>(context);
    final availablePids = obd.discoveredPids;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.tune, color: AppTheme.cyan),
            SizedBox(width: 8),
            Text("Wybór Czujników"),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Podsumowanie wyboru i szacowany FPS
            _buildSamplingInfoCard(logger.selectedPidKeys.length),

            const SizedBox(height: 16),

            // Import definicji parametrów producenta (dowolne auto)
            const _DefinitionsImportCard(),

            const SizedBox(height: 16),

            // Szybkie presety
            const Text(
              "SZYBKIE PROFILE LOGOWANIA",
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 8),
            _buildPresetSelector(logger),

            const SizedBox(height: 20),

            // Lista czujników z podziałem
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "DOSTĘPNE CZUJNIKI W POJEŹDZIE",
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    for (final p in availablePids) {
                      if (!logger.selectedPidKeys.contains(p.shortName)) {
                        logger.togglePid(p.shortName);
                      }
                    }
                  },
                  child: const Text("Zaznacz wszystkie", style: TextStyle(color: AppTheme.cyan, fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 6),

            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: availablePids.length,
              itemBuilder: (context, index) {
                final pid = availablePids[index];
                final isSelected = logger.selectedPidKeys.contains(pid.shortName);

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.surfaceLight : AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? Color(pid.colorValue) : AppTheme.border,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Color(pid.colorValue).withAlpha(30),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          pid.shortName,
                          style: TextStyle(
                            color: Color(pid.colorValue),
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                    title: Text(
                      pid.name,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      "${pid is ExtendedPid ? (pid.source != null ? 'Import: ${pid.source} (${pid.requestCommand})' : 'UDS producenta ${pid.requestCommand}') : 'OBD-II ${pid.code}'} | ${pid.unit} | ${_rateLabel(pid.rate)}",
                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                    trailing: Switch(
                      value: isSelected,
                      activeThumbColor: Color(pid.colorValue),
                      onChanged: (_) => logger.togglePid(pid.shortName),
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

  Widget _buildSamplingInfoCard(int selectedCount) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: AppTheme.surfaceLight,
            child: Icon(Icons.speed, color: AppTheme.cyan),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Wybrano: $selectedCount czujników",
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  "Szybkie kanały (obroty, pedał, doładowanie) są odczytywane w każdym cyklu, temperatury rzadziej. Rzeczywistą częstotliwość widać w Rejestratorze.",
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 4),
                const Text(
                  "Wskazówka: profil „Diagnostyka automatyczna” zbiera wszystko, czego potrzebuje Asystent.",
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetSelector(DataloggerService logger) {
    return Column(
      children: LoggingPreset.presets.map((preset) {
        final isApplied = preset.pidShortNames.every((p) => logger.selectedPidKeys.contains(p)) &&
            preset.pidShortNames.length == logger.selectedPidKeys.length;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: isApplied ? AppTheme.cyan.withAlpha(20) : AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isApplied ? AppTheme.cyan : AppTheme.border,
              width: isApplied ? 1.5 : 1,
            ),
          ),
          child: ListTile(
            title: Text(
              preset.title,
              style: TextStyle(
                color: isApplied ? AppTheme.cyan : AppTheme.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            subtitle: Text(
              preset.description,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
            ),
            trailing: isApplied
                ? const Icon(Icons.check_circle, color: AppTheme.cyan)
                : ElevatedButton(
                    onPressed: () => logger.applyPreset(preset),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.surfaceLight,
                      foregroundColor: AppTheme.textPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                    child: const Text("Użyj", style: TextStyle(fontSize: 12)),
                  ),
          ),
        );
      }).toList(),
    );
  }
}

/// Import plików z definicjami parametrów producenta (format Torque CSV).
class _DefinitionsImportCard extends StatefulWidget {
  const _DefinitionsImportCard();

  @override
  State<_DefinitionsImportCard> createState() => _DefinitionsImportCardState();
}

class _DefinitionsImportCardState extends State<_DefinitionsImportCard> {
  bool _busy = false;

  Future<void> _import() async {
    final store = context.read<PidDefinitionsStore>();
    final obd = context.read<ObdService>();
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(dialogTitle: "Wybierz plik CSV z definicjami (Torque)");
    } catch (e) {
      _snack("Nie udało się otworzyć wyboru pliku: $e");
      return;
    }
    if (picked.isEmpty || !mounted) return;

    setState(() => _busy = true);
    final lines = <String>[];
    try {
      for (final f in picked) {
        final bytes = await f.readAsBytes();
        String content;
        try {
          content = utf8.decode(bytes);
        } catch (_) {
          content = latin1.decode(bytes);
        }
        final r = await store.importCsv(f.name, content);
        lines.add("${f.name}: wczytano ${r.pids.length} definicji${r.skipped.isNotEmpty ? ', pominięto ${r.skipped.length}' : ''}.");
        for (final s in r.skipped.take(5)) {
          lines.add("  • $s");
        }
      }
      if (obd.status == ObdConnectionStatus.connected) {
        final added = await obd.probeImportedNow();
        lines.add("");
        lines.add("Twoje auto odpowiada na $added z nich — zostały dodane do listy czujników.");
      } else {
        lines.add("");
        lines.add("Po połączeniu z autem aplikacja sprawdzi, które z tych parametrów sterownik obsługuje.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text("Import definicji", style: TextStyle(color: AppTheme.textPrimary)),
        content: SingleChildScrollView(
          child: Text(lines.join("\n"), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK"))],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppTheme.red));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PidDefinitionsStore>();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.library_add, color: AppTheme.cyan, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Parametry producenta (import)",
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            "Standardowe parametry OBD-II działają w każdym aucie. Parametry producenta (np. korekty wtryskiwaczy, "
            "zadane doładowanie w benzynie) można dodać z pliku CSV w formacie Torque — gotowe pliki dla wielu "
            "modeli udostępnia społeczność. Aplikacja sama sprawdzi, które z nich obsługuje Twoje auto.",
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 10),
          for (final entry in store.files.entries)
            Row(
              children: [
                const Icon(Icons.description, color: AppTheme.textMuted, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "${entry.key} (${entry.value.pids.length})",
                    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: AppTheme.textMuted, size: 18),
                  tooltip: "Usuń",
                  onPressed: () => store.remove(entry.key),
                ),
              ],
            ),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _import,
              icon: _busy
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.upload_file),
              label: const Text("Importuj plik CSV (Torque)"),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.cyan,
                side: const BorderSide(color: AppTheme.cyan),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
