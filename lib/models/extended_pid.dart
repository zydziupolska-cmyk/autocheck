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

  /// Definicje zaimportowane przez użytkownika (pliki CSV Torque) — dla dowolnego auta.
  custom,
}

/// Jak interpretować wartość parametru producenta.
enum UdsValueKind {
  /// Wartość bez przekształceń.
  raw,

  /// Ciśnienie doładowania: jednostka (kPa / hPa / bar, bezwzględne lub względne)
  /// wykrywana przy połączeniu po wartości atmosferycznej, wynik w bar nadciśnienia.
  boostPressure,

  /// Ciśnienie paliwa: przeliczane na bar według jednostki z tabeli.
  railPressure,

  /// Wartość z importu CSV już przeliczona na jednostkę kanału (współczynnik [ExtendedPid.scale]).
  scaled,
}

/// Rozszerzony PID, który wykorzystuje specyficzne dla producenta komendy (np. Mode 22, UDS)
class ExtendedPid extends ObdPid {
  final VehicleProfile profile;

  /// Pełna komenda żądania, np. "22202A" (UDS ReadDataByIdentifier).
  final String requestCommand;

  /// Opcjonalny nagłówek CAN (CAN Header) wymagany do komunikacji z konkretnym
  /// modułem (np. "7E0" dla ECU silnika w 11-bit CAN).
  /// Jeśli null, komunikacja leci na adres ECU silnika.
  final String? canHeader;

  final UdsValueKind kind;

  /// Współczynnik i przesunięcie dla [UdsValueKind.scaled] (np. °F → °C, mbar → kPa).
  final double scale;
  final double offset;

  /// Nazwa pliku, z którego pochodzi definicja (import użytkownika).
  final String? source;

  /// Oryginalna nazwa z pliku definicji.
  final String? originalName;

  const ExtendedPid({
    required this.profile,
    required this.requestCommand,
    this.canHeader,
    this.kind = UdsValueKind.raw,
    this.scale = 1,
    this.offset = 0,
    this.source,
    this.originalName,
    required super.code,
    required super.shortName,
    required super.name,
    required super.unit,
    required super.category,
    required super.colorValue,
    required super.minExpected,
    required super.maxExpected,
    required super.decoder,
    super.rate,
  });

  @override
  String get command => requestCommand;

  /// Mapowanie nazw z tabel producenta (generowanych z CSV) na kanały, które
  /// rozumie analizator. Dzięki temu np. zadane doładowanie z UDS VAG trafia do
  /// tego samego kanału TARGET_BOOST co standardowy PID 70.
  static const Map<String, (String, String, UdsValueKind)> _canonical = {
    // VAG (UDS, sterowniki MQB)
    "CHARGE": ("BOOST", "Doładowanie rzeczywiste (UDS)", UdsValueKind.boostPressure),
    "PUTS": ("TARGET_BOOST", "Doładowanie zadane (UDS)", UdsValueKind.boostPressure),
    "FRP": ("F_RAIL", "Ciśnienie na szynie (UDS)", UdsValueKind.railPressure),
    "LMBDA": ("LAMBDA", "Lambda rzeczywista (UDS)", UdsValueKind.raw),
    "LMBDS": ("LAMBDA_CMD", "Lambda zadana (UDS)", UdsValueKind.raw),
    "TCC1": ("KNOCK_1", "Korekta stukowa cyl. 1 (UDS)", UdsValueKind.raw),
    "TCC2": ("KNOCK_2", "Korekta stukowa cyl. 2 (UDS)", UdsValueKind.raw),
    "TCC3": ("KNOCK_3", "Korekta stukowa cyl. 3 (UDS)", UdsValueKind.raw),
    "TCC4": ("KNOCK_4", "Korekta stukowa cyl. 4 (UDS)", UdsValueKind.raw),
    "TC1": ("IGN", "Kąt zapłonu cyl. 1 (UDS)", UdsValueKind.raw),
    "TORQUE": ("TQ_NM", "Moment rzeczywisty (UDS)", UdsValueKind.raw),
    "WGDSA": ("WG_ACT", "Wastegate — rzeczywiste (UDS)", UdsValueKind.raw),
    "WGDS": ("WG_CMD", "Wastegate — zadane (UDS)", UdsValueKind.raw),
    // BMW
    "BOOSTACT": ("BOOST", "Doładowanie rzeczywiste (UDS)", UdsValueKind.boostPressure),
    "BOOSTTGT": ("TARGET_BOOST", "Doładowanie zadane (UDS)", UdsValueKind.boostPressure),
    "RAILACT": ("F_RAIL", "Ciśnienie na szynie (UDS)", UdsValueKind.railPressure),
    "RAILTGT": ("RAIL_TGT", "Ciśnienie na szynie — zadane (UDS)", UdsValueKind.railPressure),
    "EGT1": ("EGT", "Temperatura spalin (UDS)", UdsValueKind.raw),
    "DPFSOOT": ("DPF_SOOT", "Masa sadzy w DPF (UDS)", UdsValueKind.raw),
    "TRANSTEMP": ("GEAR_OIL_T", "Temperatura oleju skrzyni (UDS)", UdsValueKind.raw),

    // Aliasy diagnostyki diesla — dla tabel producenta, importu (CSV Torque)
    // i kanałów nauczonych z magistrali („Nauka od testera”). Dzięki temu dane
    // z różnych źródeł trafiają do tych samych kanałów, których używa analizator.
    // DPF — różnica ciśnień (analizator liczy z niej zatkanie filtra)
    "DPFDP": ("DPF_DP", "Różnica ciśnień na DPF (UDS)", UdsValueKind.raw),
    "DPFDIFFP": ("DPF_DP", "Różnica ciśnień na DPF (UDS)", UdsValueKind.raw),
    "DPFDIFF": ("DPF_DP", "Różnica ciśnień na DPF (UDS)", UdsValueKind.raw),
    "DPFPRESS": ("DPF_DP", "Różnica ciśnień na DPF (UDS)", UdsValueKind.raw),
    "PDPF": ("DPF_DP", "Różnica ciśnień na DPF (UDS)", UdsValueKind.raw),
    "SOOTP": ("DPF_DP", "Różnica ciśnień na DPF (UDS)", UdsValueKind.raw),
    // DPF — masa/ładunek sadzy
    "DPFSOOTMASS": ("DPF_SOOT", "Masa sadzy w DPF (UDS)", UdsValueKind.raw),
    "SOOTMASS": ("DPF_SOOT", "Masa sadzy w DPF (UDS)", UdsValueKind.raw),
    "DPFLOAD": ("DPF_SOOT", "Ładunek sadzy w DPF (UDS)", UdsValueKind.raw),
    "PMLOAD": ("DPF_SOOT", "Ładunek sadzy w DPF (UDS)", UdsValueKind.raw),
    // Temperatura spalin
    "EGT": ("EGT", "Temperatura spalin (UDS)", UdsValueKind.raw),
    "EGTB1": ("EGT", "Temperatura spalin (UDS)", UdsValueKind.raw),
    "EXHTEMP": ("EGT", "Temperatura spalin (UDS)", UdsValueKind.raw),
    "TABG": ("EGT", "Temperatura spalin (UDS)", UdsValueKind.raw),
    // EGR — zadane / rzeczywiste
    "EGRCMD": ("EGR_CMD", "EGR — zadane (UDS)", UdsValueKind.raw),
    "EGRDES": ("EGR_CMD", "EGR — zadane (UDS)", UdsValueKind.raw),
    "EGRSET": ("EGR_CMD", "EGR — zadane (UDS)", UdsValueKind.raw),
    "EGRACT": ("EGR_ACT", "EGR — rzeczywiste (UDS)", UdsValueKind.raw),
    "EGRPOS": ("EGR_ACT", "EGR — rzeczywiste (UDS)", UdsValueKind.raw),
    "EGRFB": ("EGR_ACT", "EGR — rzeczywiste (UDS)", UdsValueKind.raw),
    // Temperatura oleju silnika
    "OILTEMP": ("OIL_T", "Temperatura oleju (UDS)", UdsValueKind.raw),
    "TOIL": ("OIL_T", "Temperatura oleju (UDS)", UdsValueKind.raw),
    "OILT": ("OIL_T", "Temperatura oleju (UDS)", UdsValueKind.raw),
    // Masowy przepływ powietrza
    "AIRMASS": ("MAF", "Przepływ powietrza (UDS)", UdsValueKind.raw),
    "MAFACT": ("MAF", "Przepływ powietrza (UDS)", UdsValueKind.raw),
    "MASSAIR": ("MAF", "Przepływ powietrza (UDS)", UdsValueKind.raw),
    "MLHFM": ("MAF", "Przepływ powietrza (UDS)", UdsValueKind.raw),
    // Geometria turbiny (VGT/VNT) — analizator porównuje zadane z rzeczywistym
    "VGTCMD": ("VGT_CMD", "Geometria turbiny — zadane (UDS)", UdsValueKind.raw),
    "VNTCMD": ("VGT_CMD", "Geometria turbiny — zadane (UDS)", UdsValueKind.raw),
    "VGTACT": ("VGT_ACT", "Geometria turbiny — rzeczywiste (UDS)", UdsValueKind.raw),
    "VNTACT": ("VGT_ACT", "Geometria turbiny — rzeczywiste (UDS)", UdsValueKind.raw),
  };

  /// Kanoniczna nazwa kanału dla nazwy z tabeli producenta / importu CSV /
  /// nauki z magistrali (lub ta sama nazwa, gdy nie ma mapowania). Dzięki temu
  /// różne źródła danych trafiają do tych samych kanałów, których używa analizator.
  static String canonicalKeyFor(String shortName) =>
      _canonical[shortName.toUpperCase()]?.$1 ?? shortName;

  /// Kanały producenta z nazwami rozumianymi przez analizator.
  static List<ExtendedPid> channelsFor(VehicleProfile profile) {
    return [
      for (final p in extendedPids.where((p) => p.profile == profile)) _toCanonical(p),
    ];
  }

  static ExtendedPid _toCanonical(ExtendedPid p) {
    final c = _canonical[p.shortName.toUpperCase()];
    if (c == null) return p;
    final (key, name, kind) = c;
    return ExtendedPid(
      profile: p.profile,
      requestCommand: p.requestCommand,
      canHeader: p.canHeader?.toUpperCase(),
      kind: kind,
      code: p.code,
      shortName: key,
      name: name,
      unit: kind == UdsValueKind.boostPressure || kind == UdsValueKind.railPressure ? "bar" : p.unit,
      category: p.category,
      colorValue: p.colorValue,
      minExpected: kind == UdsValueKind.boostPressure ? -0.8 : p.minExpected,
      maxExpected: kind == UdsValueKind.boostPressure ? 2.8 : p.maxExpected,
      decoder: p.decoder,
      rate: key == "BOOST" || key == "TARGET_BOOST" || key == "F_RAIL" ? PollRate.fast : PollRate.normal,
    );
  }

  /// Jednostka zapisana w tabeli producenta (przed mapowaniem) — do przeliczeń ciśnienia paliwa.
  static String rawUnitOf(ExtendedPid canonical) {
    for (final p in extendedPids) {
      if (p.requestCommand == canonical.requestCommand && p.profile == canonical.profile) return p.unit;
    }
    return canonical.unit;
  }

  /// Zebrana baza wszystkich rozszerzonych PIDów
  static final List<ExtendedPid> extendedPids = [
    ...VagPids.pids,
    ...BmwPids.pids,
    // Zadane doładowanie dla PSA (wartość już w bar nadciśnienia)
    ExtendedPid(
      profile: VehicleProfile.psa,
      requestCommand: "221010",
      canHeader: null,
      code: "221010",
      shortName: "TARGET_BOOST",
      name: "Doładowanie zadane (UDS PSA)",
      unit: "bar",
      category: PidCategory.turbo,
      colorValue: 0xFF80FFDB,
      minExpected: -0.8,
      maxExpected: 2.5,
      rate: PollRate.fast,
      decoder: (b) => b.length >= 2 ? (((b[0] * 256.0) + b[1]) / 1000.0 - 1.0) : double.nan,
    ),
  ];

  /// Zwraca listę rozszerzonych PIDów dla danego profilu pojazdu
  static List<ExtendedPid> getForProfile(VehicleProfile profile) => channelsFor(profile);
}
