import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/vag_modules.dart';
import '../models/uds_nrc.dart';
import 'obd_service.dart';

/// Kopia zapasowa kodowania i adaptacji jednego modułu — zapisana wartość DID.
class CodingBackupEntry {
  final int did;
  final String label;
  final List<int> bytes;
  const CodingBackupEntry(this.did, this.label, this.bytes);

  Map<String, dynamic> toJson() => {
        "did": did,
        "label": label,
        "hex": bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      };

  static CodingBackupEntry fromJson(Map<String, dynamic> j) {
    final hex = (j["hex"] as String?) ?? "";
    return CodingBackupEntry(
      j["did"] as int,
      (j["label"] as String?) ?? "",
      [for (int i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)],
    );
  }
}

/// Kopia zapasowa całego auta (jeden lub więcej modułów).
class CodingBackup {
  final DateTime createdAt;
  final String vehicleLabel;
  final String vin;
  final Map<String, List<CodingBackupEntry>> modules; // klucz: requestId modułu

  CodingBackup({required this.createdAt, required this.vehicleLabel, required this.vin, required this.modules});

  Map<String, dynamic> toJson() => {
        "version": 1,
        "createdAt": createdAt.toIso8601String(),
        "vehicle": vehicleLabel,
        "vin": vin,
        "modules": {
          for (final e in modules.entries) e.key: [for (final v in e.value) v.toJson()],
        },
      };

  static CodingBackup fromJson(Map<String, dynamic> j) => CodingBackup(
        createdAt: DateTime.tryParse(j["createdAt"] as String? ?? "") ?? DateTime.now(),
        vehicleLabel: (j["vehicle"] as String?) ?? "",
        vin: (j["vin"] as String?) ?? "",
        modules: {
          for (final e in (j["modules"] as Map).entries)
            e.key as String: [for (final v in (e.value as List)) CodingBackupEntry.fromJson(v as Map<String, dynamic>)],
        },
      );

  int get totalValues => modules.values.fold(0, (a, b) => a + b.length);
}

/// Odczyt, kopia zapasowa i przywracanie kodowania oraz adaptacji przez UDS.
///
/// Zakres świadomie ograniczony do wartości serwisowych, które sterownik udostępnia
/// standardowo (usługi 22/2E). Nie rusza chronionej pamięci programu ani nie omija
/// zabezpieczeń — to kopia „na wszelki wypadek” przed naprawą albo wymianą modułu.
class CodingService extends ChangeNotifier {
  final ObdService obd;
  final bool persist;

  CodingService({required this.obd, this.persist = true}) {
    if (persist) refresh();
  }

  bool _busy = false;
  String? _progress;
  List<File> _saved = [];

  bool get busy => _busy;
  String? get progress => _progress;
  List<File> get saved => List.unmodifiable(_saved);
  bool get canUse => obd.canScanVagModules;

  /// Odczyt kodowania i adaptacji wybranych modułów.
  Future<List<ModuleCoding>> read(List<VagModule> modules) async {
    if (_busy) return const [];
    _busy = true;
    final out = <ModuleCoding>[];
    try {
      for (int i = 0; i < modules.length; i++) {
        final m = modules[i];
        _progress = "Odczyt: ${m.name} (${i + 1}/${modules.length})";
        notifyListeners();
        out.add(await obd.readModuleCoding(m));
      }
    } finally {
      _busy = false;
      _progress = null;
      notifyListeners();
    }
    return out;
  }

  /// Tworzy i zapisuje kopię zapasową z odczytanych modułów.
  Future<File?> backup(List<ModuleCoding> readings) async {
    final v = obd.vehicleInfo;
    final backup = CodingBackup(
      createdAt: DateTime.now(),
      vehicleLabel: v != null ? "${v.manufacturer} ${v.modelName}" : "Pojazd",
      vin: v?.vin ?? "",
      modules: {
        for (final r in readings)
          if (r.responded)
            r.module.requestId: [
              for (final val in r.values)
                if (val.readable) CodingBackupEntry(val.did, val.label, val.bytes!),
            ],
      },
    );
    backup.modules.removeWhere((_, v) => v.isEmpty);
    if (backup.modules.isEmpty || !persist) return null;
    try {
      final dir = await _dir();
      final ts = backup.createdAt.toIso8601String().replaceAll(":", "-").split(".").first;
      final vin = backup.vin.isNotEmpty ? "_${backup.vin}" : "";
      final file = File("${dir.path}/kodowanie${vin}_$ts.json");
      await file.writeAsString(const JsonEncoder.withIndent("  ").convert(backup.toJson()));
      await refresh();
      return file;
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd zapisu kopii kodowania: $e");
      return null;
    }
  }

  /// Wynik próby przywrócenia jednej wartości.
  Future<List<RestoreResult>> restore(CodingBackup backup) async {
    if (_busy) return const [];
    _busy = true;
    final results = <RestoreResult>[];
    try {
      for (final entry in backup.modules.entries) {
        final module = VagModule.all.where((m) => m.requestId == entry.key).firstOrNull ??
            VagModule("Moduł ${entry.key}", "", entry.key, _responseFor(entry.key));
        for (final v in entry.value) {
          _progress = "Przywracanie: ${module.name} • ${v.label}";
          notifyListeners();
          final (ok, nrc) = await obd.writeModuleDid(module, v.did, v.bytes);
          results.add(RestoreResult(module.name, v.label, ok, nrc));
        }
      }
    } finally {
      _busy = false;
      _progress = null;
      notifyListeners();
    }
    return results;
  }

  static String _responseFor(String requestId) {
    final v = int.tryParse(requestId, radix: 16);
    if (v != null && v >= 0x700 && v <= 0x7FF) return (v + 0x6A).toRadixString(16).toUpperCase();
    return requestId;
  }

  Future<CodingBackup?> load(File f) async {
    try {
      return CodingBackup.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd wczytania kopii: $e");
      return null;
    }
  }

  Future<void> share(File f) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: "Kopia kodowania Dynomic Diag"));
  }

  Future<void> delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
    await refresh();
  }

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory("${docs.path}/coding");
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> refresh() async {
    try {
      final dir = await _dir();
      final files = <File>[
        await for (final f in dir.list())
          if (f is File && f.path.endsWith(".json")) f,
      ];
      files.sort((a, b) => b.path.compareTo(a.path));
      _saved = files;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd listy kopii: $e");
    }
  }
}

class RestoreResult {
  final String moduleName;
  final String label;
  final bool ok;
  final int? nrc;
  const RestoreResult(this.moduleName, this.label, this.ok, this.nrc);

  /// Czytelny powód niepowodzenia na podstawie kodu odmowy UDS (pełna tablica NRC).
  String get reason => ok ? "zapisano" : UdsNrc.describePl(nrc);
}
