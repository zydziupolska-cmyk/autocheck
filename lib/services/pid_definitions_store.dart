import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/torque_csv.dart';
import 'obd_service.dart';

/// Zaimportowane pliki z definicjami parametrów (format Torque CSV).
/// Pliki są trzymane w katalogu aplikacji i wczytywane przy starcie; definicje
/// trafiają do [ObdService.importedPids] i są sprawdzane przy każdym połączeniu.
class PidDefinitionsStore extends ChangeNotifier {
  final ObdService obd;
  final bool persist;
  final Map<String, TorqueImportResult> _files = {};

  PidDefinitionsStore({required this.obd, this.persist = true}) {
    if (persist) _load();
  }

  Map<String, TorqueImportResult> get files => Map.unmodifiable(_files);
  int get totalDefinitions => _files.values.fold(0, (a, r) => a + r.pids.length);

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory("${docs.path}/pid_definitions");
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _load() async {
    try {
      final dir = await _dir();
      await for (final f in dir.list()) {
        if (f is! File || !f.path.toLowerCase().endsWith(".csv")) continue;
        final name = f.uri.pathSegments.last;
        _files[name] = TorqueCsvImporter.parse(await f.readAsString(), sourceName: name);
      }
      _apply();
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd wczytywania definicji: $e");
    }
  }

  /// Importuje plik. Zwraca wynik (także gdy nic nie dało się wczytać — wtedy plik nie jest zapisywany).
  Future<TorqueImportResult> importCsv(String fileName, String content) async {
    final name = fileName.toLowerCase().endsWith(".csv") ? fileName : "$fileName.csv";
    final result = TorqueCsvImporter.parse(content, sourceName: name);
    if (result.pids.isEmpty) return result;
    _files[name] = result;
    if (persist) {
      try {
        await File("${(await _dir()).path}/$name").writeAsString(content);
      } catch (e) {
        if (kDebugMode) debugPrint("Błąd zapisu definicji: $e");
      }
    }
    _apply();
    return result;
  }

  Future<void> remove(String name) async {
    _files.remove(name);
    if (persist) {
      try {
        final f = File("${(await _dir()).path}/$name");
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _apply();
  }

  void _apply() {
    obd.importedPids = [for (final r in _files.values) ...r.pids];
    notifyListeners();
  }
}
