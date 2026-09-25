import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Jedna usterka dopisana przez mechanika dla danego silnika.
class UserFault {
  final String id;
  final String title;
  final String note;
  final DateTime added;

  const UserFault({required this.id, required this.title, required this.note, required this.added});

  Map<String, dynamic> toJson() => {"id": id, "title": title, "note": note, "added": added.toIso8601String()};

  factory UserFault.fromJson(Map<String, dynamic> j) => UserFault(
        id: j["id"] as String,
        title: j["title"] as String? ?? "",
        note: j["note"] as String? ?? "",
        added: DateTime.tryParse(j["added"] as String? ?? "") ?? DateTime.now(),
      );
}

/// Prywatna baza usterek Dynomic: własne notatki mechanika przypisane do silnika
/// (po kodzie silnika). Z czasem staje się unikalną, warsztatową bazą wiedzy —
/// czego nie da żadna kupiona ani skopiowana baza. Wszystko lokalnie, offline.
class FaultNotes extends ChangeNotifier {
  final bool persist;
  final Map<String, List<UserFault>> _byCode = {}; // kod silnika → lista usterek

  FaultNotes({this.persist = true}) {
    if (persist) _load();
  }

  String _key(String code) => code.trim().toUpperCase();

  /// Usterki dopisane dla danego silnika (pusta lista, gdy brak).
  List<UserFault> notesFor(String? code) {
    if (code == null || code.trim().isEmpty) return const [];
    return List.unmodifiable(_byCode[_key(code)] ?? const []);
  }

  bool get isEmpty => _byCode.values.every((l) => l.isEmpty);
  int get totalCount => _byCode.values.fold(0, (a, l) => a + l.length);

  Future<void> add(String code, String title, String note) async {
    if (code.trim().isEmpty || title.trim().isEmpty) return;
    final list = _byCode.putIfAbsent(_key(code), () => []);
    list.add(UserFault(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title.trim(),
      note: note.trim(),
      added: DateTime.now(),
    ));
    notifyListeners();
    await _save();
  }

  Future<void> remove(String code, String id) async {
    _byCode[_key(code)]?.removeWhere((f) => f.id == id);
    notifyListeners();
    await _save();
  }

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File("${docs.path}/fault_notes.json");
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      map.forEach((code, list) {
        _byCode[code] = [for (final e in (list as List)) UserFault.fromJson(e as Map<String, dynamic>)];
      });
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd wczytania notatek usterek: $e");
    }
  }

  Future<void> _save() async {
    if (!persist) return;
    try {
      final out = _byCode.map((k, v) => MapEntry(k, v.map((f) => f.toJson()).toList()));
      await (await _file()).writeAsString(jsonEncode(out));
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd zapisu notatek usterek: $e");
    }
  }
}
