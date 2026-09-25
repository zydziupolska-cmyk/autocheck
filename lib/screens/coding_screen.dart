import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/vag_modules.dart';
import '../models/uds_nrc.dart';
import '../services/coding_service.dart';
import '../services/obd_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';

/// Kodowanie i adaptacje: odczyt wartości serwisowych modułów, kopia zapasowa
/// przed naprawą i przywracanie z kopii. Bez ingerencji w chronioną pamięć.
class CodingScreen extends StatefulWidget {
  const CodingScreen({super.key});

  @override
  State<CodingScreen> createState() => _CodingScreenState();
}

class _CodingScreenState extends State<CodingScreen> {
  // Domyślnie moduły, które prawie zawsze są na CAN i mają kodowanie
  final _selected = <String>{"7E0", "713", "714", "715", "17"};
  List<ModuleCoding>? _readings;

  static const _commonModules = [
    ("7E0", "Silnik"),
    ("713", "ABS / ESP"),
    ("714", "Zestaw wskaźników"),
    ("715", "Poduszki powietrzne"),
    ("746", "Klimatyzacja"),
    ("09", "Elektronika centralna"),
    ("17", "Zestaw wskaźników (17)"),
    ("44", "Wspomaganie kierownicy"),
  ];

  VagModule _moduleFor(String id) =>
      VagModule.all.where((m) => m.requestId == id).firstOrNull ??
      VagModule.all.where((m) => m.asamName.isNotEmpty && m.requestId == id).firstOrNull ??
      VagModule(_commonModules.where((m) => m.$1 == id).map((m) => m.$2).firstOrNull ?? "Moduł $id", "", id,
          _respFor(id));

  static String _respFor(String id) {
    final v = int.tryParse(id, radix: 16);
    if (v != null && v >= 0x700 && v <= 0x7FF) return (v + 0x6A).toRadixString(16).toUpperCase();
    return id;
  }

  Future<void> _read(CodingService coding) async {
    final modules = _selected.map(_moduleFor).toList();
    final r = await coding.read(modules);
    if (mounted) setState(() => _readings = r);
  }

  Future<void> _backup(CodingService coding) async {
    if (_readings == null) return;
    final f = await coding.backup(_readings!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(f != null ? "Zapisano kopię: ${f.uri.pathSegments.last}" : "Brak wartości do zapisania."),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final coding = context.watch<CodingService>();
    final obd = context.watch<ObdService>();
    return Scaffold(
      appBar: AppBar(title: const Text("Kodowanie i adaptacje")),
      body: obd.status != ObdConnectionStatus.connected
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Notice("Połącz się z autem, żeby odczytać identyfikację i kodowanie sterowników."),
            )
          : !obd.canScanVagModules
              ? _universal(context, coding, obd)
              : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                const Notice(
                  "Kopia zapasowa wartości serwisowych (kodowanie, numery, wersje) na wypadek naprawy albo "
                  "wymiany modułu. Odczyt niczego nie zmienia w aucie.",
                  icon: Icons.shield_outlined,
                ),
                const SizedBox(height: 16),
                const SectionLabel("Moduły do odczytu"),
                Panel(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      for (final (id, name) in _commonModules)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _selected.contains(id),
                          onChanged: coding.busy
                              ? null
                              : (v) => setState(() => v == true ? _selected.add(id) : _selected.remove(id)),
                          title: Text(name, style: const TextStyle(fontSize: 14)),
                          secondary: Text(id, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12, fontFeatures: AppTheme.tabular)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (coding.progress != null)
                  Row(children: [
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(coding.progress!, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                  ])
                else
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: coding.busy || _selected.isEmpty ? null : () => _read(coding),
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text("Odczytaj"),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: coding.busy || _readings == null ? null : () => _backup(coding),
                        icon: const Icon(Icons.save_outlined, size: 18),
                        label: const Text("Zapisz kopię"),
                      ),
                    ),
                  ]),
                if (_readings != null) ...[
                  const SizedBox(height: 16),
                  for (final r in _readings!) _moduleCard(r),
                ],
                const SizedBox(height: 16),
                _savedCard(context, coding),
              ],
            ),
    );
  }

  /// Auta spoza VAG: uniwersalny odczyt identyfikacji sterownika silnika.
  Widget _universal(BuildContext context, CodingService coding, ObdService obd) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        const Notice(
          "Dla tej marki mam na razie uniwersalny odczyt identyfikacji sterownika silnika (VIN, numery, "
          "wersje oprogramowania). Pełne kodowanie modułów dopiszę z nagrania oryginalnego testera.",
          icon: Icons.info_outline,
        ),
        const SizedBox(height: 12),
        if (coding.progress != null)
          Row(children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text(coding.progress!, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
          ])
        else
          ElevatedButton.icon(
            onPressed: coding.busy ? null : () async {
              final r = await obd.readEcuIdentification();
              if (context.mounted) setState(() => _readings = [r]);
            },
            icon: const Icon(Icons.download, size: 18),
            label: const Text("Odczytaj identyfikację sterownika"),
          ),
        if (_readings != null) ...[
          const SizedBox(height: 16),
          for (final r in _readings!) _moduleCard(r),
        ],
      ],
    );
  }

  Widget _moduleCard(ModuleCoding r) {
    final readable = r.values.where((v) => v.readable).toList();
    return Panel(
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        title: Text(r.module.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
          r.responded ? "${readable.length} wartości" : "moduł nie odpowiedział",
          style: TextStyle(color: r.responded ? AppTheme.textMuted : AppTheme.warn, fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final v in r.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v.label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                  const SizedBox(height: 2),
                  if (!v.readable)
                    Text(
                      v.nrc == null ? "brak odczytu" : UdsNrc.describePl(v.nrc),
                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                    )
                  else
                    SelectableText(
                      _display(v),
                      style: const TextStyle(fontFamily: "monospace", fontSize: 13, fontFeatures: AppTheme.tabular),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _display(DidValue v) {
    if (CodingDids.textual.contains(v.did)) {
      final t = String.fromCharCodes(v.bytes!.where((b) => b >= 0x20 && b <= 0x7E));
      if (t.trim().isNotEmpty) return t.trim();
    }
    return v.hex;
  }

  Widget _savedCard(BuildContext context, CodingService coding) {
    return Panel(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        leading: const Icon(Icons.folder_open, color: AppTheme.textSecondary),
        title: Text("Zapisane kopie (${coding.saved.length})", style: const TextStyle(fontSize: 14)),
        children: [
          for (final f in coding.saved)
            ListTile(
              dense: true,
              title: Text(f.uri.pathSegments.last, style: const TextStyle(fontSize: 12.5)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.restore, size: 18), tooltip: "Przywróć z tej kopii", onPressed: () => _restore(context, coding, f)),
                IconButton(icon: const Icon(Icons.ios_share, size: 18), onPressed: () => coding.share(f)),
                IconButton(icon: const Icon(Icons.delete_outline, size: 18), onPressed: () => coding.delete(f)),
              ]),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.upload_file, size: 18),
            title: const Text("Wczytaj kopię z pliku i przywróć", style: TextStyle(fontSize: 12.5)),
            onTap: () => _restoreFromPicker(context, coding),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreFromPicker(BuildContext context, CodingService coding) async {
    try {
      final picked = await FilePicker.pickFiles(dialogTitle: "Wybierz kopię kodowania (JSON)");
      if (picked.isEmpty) return;
      final bytes = await picked.first.readAsBytes();
      final backup = CodingBackup.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
      if (context.mounted) await _confirmRestore(context, coding, backup);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Nie udało się wczytać kopii: $e")));
      }
    }
  }

  Future<void> _restore(BuildContext context, CodingService coding, dynamic f) async {
    final backup = await coding.load(f);
    if (backup == null || !context.mounted) return;
    await _confirmRestore(context, coding, backup);
  }

  Future<void> _confirmRestore(BuildContext context, CodingService coding, CodingBackup backup) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Przywrócić kodowanie?"),
        content: Text(
          "Kopia z ${backup.createdAt.toString().split('.').first}, ${backup.vehicleLabel}"
          "${backup.vin.isNotEmpty ? ' (${backup.vin})' : ''}.\n\n"
          "Zostanie zapisanych ${backup.totalValues} wartości do ${backup.modules.length} modułów. "
          "Rób to przy włączonym zapłonie i zgaszonym silniku. Część wartości może wymagać dostępu "
          "zabezpieczonego — te zostaną pominięte, a aplikacja pokaże które.",
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("Anuluj")),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text("Przywróć")),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final results = await coding.restore(backup);
    if (!context.mounted) return;
    final done = results.where((r) => r.ok).length;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Text("Przywrócono $done z ${results.length}"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final r in results)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(r.ok ? Icons.check : Icons.remove, size: 16, color: r.ok ? AppTheme.ok : AppTheme.warn),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text("${r.moduleName} • ${r.label}: ${r.reason}", style: const TextStyle(fontSize: 12.5)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text("OK"))],
      ),
    );
  }
}
