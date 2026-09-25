/// Kody odmowy UDS (Negative Response Code, ISO 14229) z czytelnym opisem PL.
///
/// Gdy sterownik odrzuca żądanie, odpowiada ramką `0x7F <usługa> <NRC>`. Ta tablica
/// tłumaczy NRC na język zrozumiały dla mechanika i podpowiada, co zrobić.
/// Zakres wzorowany na implementacji ISO 14229 z python-udsoncan (MIT).
library;

class UdsNrc {
  /// Krótka nazwa techniczna kodu (jak w ISO 14229).
  static String name(int nrc) => _names[nrc] ?? "reserved/OEM (0x${_h(nrc)})";

  /// Opis po polsku — co ten kod oznacza dla naprawy.
  static String describePl(int? nrc) {
    if (nrc == null) return "brak odpowiedzi modułu";
    return _pl[nrc] ?? "odmowa 0x${_h(nrc)}";
  }

  /// Czy odmowa wynika z braku dostępu zabezpieczonego (Security Access).
  static bool isSecurity(int? nrc) => nrc == 0x33 || nrc == 0x35 || nrc == 0x36 || nrc == 0x37;

  /// Czy to „zajętość/warunki chwilowe" — warto ponowić lub spełnić warunek.
  static bool isTransient(int? nrc) =>
      nrc == 0x21 || nrc == 0x22 || nrc == 0x78 || nrc == 0x81 || nrc == 0x83 || nrc == 0x84;

  static String _h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

  static const Map<int, String> _names = {
    0x10: "generalReject",
    0x11: "serviceNotSupported",
    0x12: "subFunctionNotSupported",
    0x13: "incorrectMessageLengthOrInvalidFormat",
    0x14: "responseTooLong",
    0x21: "busyRepeatRequest",
    0x22: "conditionsNotCorrect",
    0x24: "requestSequenceError",
    0x25: "noResponseFromSubnetComponent",
    0x26: "failurePreventsExecutionOfRequestedAction",
    0x31: "requestOutOfRange",
    0x33: "securityAccessDenied",
    0x34: "authenticationRequired",
    0x35: "invalidKey",
    0x36: "exceedNumberOfAttempts",
    0x37: "requiredTimeDelayNotExpired",
    0x38: "secureDataTransmissionRequired",
    0x70: "uploadDownloadNotAccepted",
    0x71: "transferDataSuspended",
    0x72: "generalProgrammingFailure",
    0x73: "wrongBlockSequenceCounter",
    0x78: "requestCorrectlyReceived-ResponsePending",
    0x7E: "subFunctionNotSupportedInActiveSession",
    0x7F: "serviceNotSupportedInActiveSession",
    0x81: "rpmTooHigh",
    0x82: "rpmTooLow",
    0x83: "engineIsRunning",
    0x84: "engineIsNotRunning",
    0x85: "engineRunTimeTooLow",
    0x86: "temperatureTooHigh",
    0x87: "temperatureTooLow",
    0x88: "vehicleSpeedTooHigh",
    0x89: "vehicleSpeedTooLow",
    0x8A: "throttle/PedalTooHigh",
    0x8B: "throttle/PedalTooLow",
    0x8C: "transmissionRangeNotInNeutral",
    0x8D: "transmissionRangeNotInGear",
    0x8F: "brakeSwitch(es)NotClosed",
    0x90: "shifterLeverNotInPark",
    0x91: "torqueConverterClutchLocked",
    0x92: "voltageTooHigh",
    0x93: "voltageTooLow",
  };

  static const Map<int, String> _pl = {
    0x10: "ogólna odmowa sterownika",
    0x11: "usługa nieobsługiwana przez ten sterownik",
    0x12: "podfunkcja nieobsługiwana",
    0x13: "zła długość lub format żądania",
    0x14: "odpowiedź za długa",
    0x21: "sterownik zajęty — ponów żądanie",
    0x22: "warunki niespełnione (np. zła sesja albo silnik pracuje)",
    0x24: "zły porządek żądań (najpierw otwórz właściwą sesję)",
    0x25: "brak odpowiedzi z komponentu podsieci",
    0x26: "usterka blokuje wykonanie żądania",
    0x31: "wartość poza zakresem / nieznany identyfikator (DID)",
    0x33: "wymaga dostępu zabezpieczonego (Security Access) — nie da się samą aplikacją",
    0x34: "wymaga uwierzytelnienia (Authentication)",
    0x35: "błędny klucz (Security Access)",
    0x36: "przekroczono liczbę prób — sterownik zablokowany na jakiś czas",
    0x37: "trwa blokada czasowa po nieudanych próbach — odczekaj",
    0x38: "wymagana bezpieczna transmisja danych",
    0x70: "sterownik nie przyjął zapisu/odczytu bloku",
    0x71: "transfer danych wstrzymany",
    0x72: "błąd programowania (zapisu) w sterowniku",
    0x73: "zły licznik kolejności bloków",
    0x78: "przyjęto — odpowiedź w toku (sterownik pracuje, poczekaj)",
    0x7E: "podfunkcja nieobsługiwana w tej sesji",
    0x7F: "usługa nieobsługiwana w tej sesji (otwórz sesję diagnostyczną)",
    0x81: "obroty za wysokie — zmniejsz obroty",
    0x82: "obroty za niskie — podnieś obroty",
    0x83: "silnik pracuje — wyłącz silnik (zapłon on)",
    0x84: "silnik nie pracuje — uruchom silnik",
    0x85: "za krótki czas pracy silnika",
    0x86: "temperatura za wysoka",
    0x87: "temperatura za niska",
    0x88: "prędkość pojazdu za wysoka",
    0x89: "prędkość pojazdu za niska",
    0x8A: "za mocno wciśnięty pedał gazu",
    0x8B: "pedał gazu wciśnięty — puść gaz",
    0x8C: "skrzynia nie na luzie (neutral)",
    0x8D: "skrzynia nie na biegu",
    0x8F: "hamulec niewciśnięty",
    0x90: "dźwignia nie w pozycji P (park)",
    0x91: "sprzęgło konwertera zablokowane",
    0x92: "napięcie za wysokie",
    0x93: "napięcie za niskie (naładuj akumulator)",
  };
}
