import 'obd_pid.dart';
import 'pids_db/vag_pids.dart';
import 'pids_db/bmw_pids.dart';

/// Producent pojazdu lub unikalny protokół do wybierania rozszerzonych PIDów.
enum VehicleProfile {
  generic,
  vag,
  bmw,
  fca,
  psa,
}

/// Rozszerzony PID, który wykorzystuje specyficzne dla producenta komendy (np. Mode 22, UDS)
class ExtendedPid extends ObdPid {
  final VehicleProfile profile;
  
  /// Pełna komenda żądania, np. "22115C" dla zadanego doładowania VAG, 
  /// lub po prostu "010B" jeśli podpinamy pod standard.
  final String requestCommand;
  
  /// Opcjonalny nagłówek CAN (CAN Header) wymagany do komunikacji z konkretnym 
  /// modułem (np. "7E0" dla ECU silnika w 11-bit CAN, "18DA10F1" w 29-bit CAN).
  /// Jeśli null, komunikacja leci na domyślnym adresie rozgłoszeniowym.
  final String? canHeader;

  const ExtendedPid({
    required this.profile,
    required this.requestCommand,
    this.canHeader,
    required super.code,
    required super.shortName,
    required super.name,
    required super.unit,
    required super.category,
    required super.colorValue,
    required super.minExpected,
    required super.maxExpected,
    required super.decoder,
  });

  /// Zebrana baza wszystkich rozszerzonych PIDów
  static final List<ExtendedPid> extendedPids = [
    ...VagPids.pids,
    ...BmwPids.pids,
    // Przykładowy Target Boost dla PSA (wbudowany manualnie)
    ExtendedPid(
      profile: VehicleProfile.psa,
      requestCommand: "221010",
      canHeader: null,
      code: "221010",
      shortName: "TARGET_BOOST",
      name: "Zadane Doładowanie (PSA)",
      unit: "bar",
      category: PidCategory.turbo,
      colorValue: 0xFF00FF00,
      minExpected: -0.8,
      maxExpected: 2.5,
      decoder: (b) => b.length >= 2 ? (((b[0] * 256.0) + b[1]) / 1000.0 - 1.0) : 0.0,
    ),
  ];

  /// Zwraca listę rozszerzonych PIDów dla danego profilu pojazdu
  static List<ExtendedPid> getForProfile(VehicleProfile profile) {
    return extendedPids.where((p) => p.profile == profile).toList();
  }
}
