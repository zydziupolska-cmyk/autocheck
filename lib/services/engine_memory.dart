import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/engine_profiles.dart';
import '../models/vehicle_info.dart';
import '../models/vin_decoder.dart';

/// Zapamiętany wybór silnika dla konkretnego auta (po VIN) plus rozpoznawanie
/// z oceną pewności. Raz potwierdzony silnik jest pewny przy kolejnych wizytach.
class EngineMemory extends ChangeNotifier {
  final bool persist;
  final Map<String, String> _byVin = {}; // VIN → kod silnika

  EngineMemory({this.persist = true}) {
    if (persist) _load();
  }

  /// Zapamiętany kod silnika dla VIN (null, gdy niezapamiętany).
  String? codeForVin(String? vin) {
    if (vin == null || vin.length < 11) return null;
    return _byVin[vin.toUpperCase()];
  }

  bool isRemembered(String? vin) => codeForVin(vin) != null;

  /// Zapisuje ręczny wybór silnika dla auta.
  Future<void> remember(String vin, String engineCode) async {
    if (vin.length < 11) return;
    _byVin[vin.toUpperCase()] = engineCode;
    notifyListeners();
    await _save();
  }

  Future<void> forget(String vin) async {
    _byVin.remove(vin.toUpperCase());
    notifyListeners();
    await _save();
  }

  /// Rozpoznaje silnik dla pojazdu: najpierw zapamiętany wybór (pewność „confirmed”),
  /// potem punktowe rozpoznanie z danych z uwzględnieniem marki z VIN.
  EngineMatch? resolve(VehicleInfo? info) {
    if (info == null) return null;
    final code = codeForVin(info.vin);
    if (code != null) {
      final p = EngineProfiles.byCode(code);
      if (p != null) return EngineMatch(p, EngineConfidence.confirmed, "wybór zapamiętany dla tego auta");
    }
    final vinMake = VinDecoder.decode(info.vin).make;
    return EngineProfiles.identify(engineHaystack(info), vinMake: vinMake);
  }

  /// Jak [resolve], ale wprost z VIN i tekstu danych (dla logów z historii).
  EngineMatch? resolveFor(String vin, String engineInfo) {
    final code = codeForVin(vin);
    if (code != null) {
      final p = EngineProfiles.byCode(code);
      if (p != null) return EngineMatch(p, EngineConfidence.confirmed, "wybór zapamiętany dla tego auta");
    }
    final vinMake = vin.length == 17 ? VinDecoder.decode(vin).make : null;
    return EngineProfiles.identify(engineInfo, vinMake: vinMake);
  }

  /// Tekst z danych pojazdu do rozpoznania silnika.
  static String engineHaystack(VehicleInfo info) =>
      [info.manufacturer, info.modelName, info.engineDescription, info.calibrationId, info.ecuName, info.vin].join(" ");

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File("${docs.path}/engine_memory.json");
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _byVin.addAll(map.map((k, v) => MapEntry(k, v.toString())));
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd wczytania pamięci silników: $e");
    }
  }

  Future<void> _save() async {
    if (!persist) return;
    try {
      await (await _file()).writeAsString(jsonEncode(_byVin));
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd zapisu pamięci silników: $e");
    }
  }
}
