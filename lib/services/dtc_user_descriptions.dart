import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/dtc_code.dart';

/// Własne opisy kodów DTC pisane przez mechanika w aplikacji — prywatna baza
/// Dynomic. Zapisywane lokalnie i wstrzykiwane do DtcCode.userOverlay, dzięki
/// czemu getByCode zwraca Twój opis z najwyższym priorytetem (offline).
class DtcUserDescriptions extends ChangeNotifier {
  final bool persist;
  final Map<String, Map<String, dynamic>> _byCode = {}; // kod → {title, category, description, commonCauses[], diagnosticsSteps[]}

  DtcUserDescriptions({this.persist = true}) {
    if (persist) _load();
  }

  String _key(String code) => code.toUpperCase().trim();

  Map<String, dynamic>? forCode(String code) => _byCode[_key(code)];
  bool has(String code) => _byCode.containsKey(_key(code));
  int get count => _byCode.length;
  List<String> get codes => _byCode.keys.toList()..sort();

  /// Zapisuje/aktualizuje własny opis kodu i od razu wstrzykuje go do DtcCode.
  Future<void> set(String code, {
    required String title,
    String? category,
    String description = "",
    List<String> commonCauses = const [],
    List<String> diagnosticsSteps = const [],
  }) async {
    if (code.trim().isEmpty || title.trim().isEmpty) return;
    final m = {
      "title": title.trim(),
      if (category != null && category.trim().isNotEmpty) "category": category.trim(),
      "description": description.trim(),
      "commonCauses": commonCauses.where((c) => c.trim().isNotEmpty).toList(),
      "diagnosticsSteps": diagnosticsSteps.where((s) => s.trim().isNotEmpty).toList(),
    };
    _byCode[_key(code)] = m;
    DtcCode.setUserDescription(code, m);
    notifyListeners();
    await _save();
  }

  Future<void> remove(String code) async {
    _byCode.remove(_key(code));
    DtcCode.setUserDescription(code, null);
    notifyListeners();
    await _save();
  }

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File("${docs.path}/dtc_user_descriptions.json");
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      map.forEach((code, v) {
        final m = (v as Map).cast<String, dynamic>();
        _byCode[code] = m;
        DtcCode.setUserDescription(code, m);
      });
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd wczytania własnych opisów DTC: $e");
    }
  }

  Future<void> _save() async {
    if (!persist) return;
    try {
      await (await _file()).writeAsString(jsonEncode(_byCode));
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd zapisu własnych opisów DTC: $e");
    }
  }
}
