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
import '../widgets/ui.dart';

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
      appBar: AppBar(title: const Text("Parametry")),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Text(
            "Wybrano ${logger.selectedPidKeys.length}. Szybkie kanały (obroty, pedał, doładowanie) są czytane w każdym cyklu, "
            "temperatury rzadziej.",
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          const SectionLabel("Profil logowania"),
          _buildPresetSelector(logger),
          const SizedBox(height: 20),
          SectionLabel(
            "Dostępne w tym aucie (${availablePids.length})",
            trailing: TextButton(
              onPressed: () {
                for (final p in availablePids) {
                  if (!logger.selectedPidKeys.contains(p.shortName)) logger.togglePid(p.shortName);
                }
              },
              child: const Text("Zaznacz wszystkie", style: TextStyle(fontSize: 12.5)),
            ),
          ),
          if (availablePids.isEmpty)
            const Notice("Po połączeniu z autem pojawi się tu lista parametrów, które udostępnia sterownik.")
          else
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (int i = 0; i < availablePids.length; i++) ...[
                    if (i > 0) const Divider(),
                    _pidRow(availablePids[i], logger),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 20),
          const _DefinitionsImportCard(),
        ],
      ),
    );
  }

  Widget _pidRow(ObdPid pid, DataloggerService logger) {
    final isSelected = logger.selectedPidKeys.contains(pid.shortName);
    final source = pid is ExtendedPid
        ? (pid.source != null ? "${pid.source} • ${pid.requestCommand}" : "UDS ${pid.requestCommand}")
        : "OBD ${pid.code}";
    return InkWell(
      onTap: () => logger.togglePid(pid.shortName),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pid.name, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    "$source • ${pid.unit.isEmpty ? '—' : pid.unit} • ${_rateLabel(pid.rate)}",
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            Checkbox(value: isSelected, onChanged: (_) => logger.togglePid(pid.shortName)),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetSelector(DataloggerService logger) {
    final presets = LoggingPreset.presets;
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (int i = 0; i < presets.length; i++) ...[
            if (i > 0) const Divider(),
            Builder(builder: (context) {
              final preset = presets[i];
              final isApplied = preset.pidShortNames.every((p) => logger.selectedPidKeys.contains(p)) &&
                  preset.pidShortNames.length == logger.selectedPidKeys.length;
              return InkWell(
                onTap: isApplied ? null : () => logger.applyPreset(preset),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(preset.title, style: TextStyle(fontSize: 14, fontWeight: isApplied ? FontWeight.w600 : FontWeight.w500)),
                            const SizedBox(height: 2),
                            Text(preset.description, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        isApplied ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: isApplied ? AppTheme.accent : AppTheme.textMuted,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ],
      ),
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
        lines.add("Auto odpowiada na $added z nich — dodano je do listy parametrów.");
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
        title: const Text("Import definicji"),
        content: SingleChildScrollView(
          child: Text(lines.join("\n"), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK"))],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppTheme.fault));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PidDefinitionsStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel("Parametry producenta"),
        const Text(
          "Dodatkowe parametry (np. korekty wtryskiwaczy, zadane doładowanie w benzynie) z pliku CSV w formacie Torque "
          "albo z trybu Nauka od testera. Aplikacja sama sprawdzi, które obsługuje auto.",
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5),
        ),
        const SizedBox(height: 10),
        if (store.files.isNotEmpty) ...[
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, entry) in store.files.entries.indexed) ...[
                  if (i > 0) const Divider(),
                  Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(entry.key, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                        ),
                        Text("${entry.value.pids.length}",
                            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12.5, fontFeatures: AppTheme.tabular)),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: "Usuń",
                          onPressed: () => store.remove(entry.key),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        OutlinedButton.icon(
          onPressed: _busy ? null : _import,
          icon: _busy
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.upload_file, size: 18),
          label: const Text("Importuj plik CSV (Torque)"),
        ),
      ],
    );
  }
}
