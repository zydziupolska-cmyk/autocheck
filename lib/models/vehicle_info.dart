import 'extended_pid.dart';

enum FuelType { unknown, petrol, diesel, hybrid, electric, other }

extension FuelTypeExt on FuelType {
  String get label {
    switch (this) {
      case FuelType.petrol:
        return "Benzyna";
      case FuelType.diesel:
        return "Diesel";
      case FuelType.hybrid:
        return "Hybryda";
      case FuelType.electric:
        return "Elektryczny";
      case FuelType.other:
        return "Inne (LPG/CNG)";
      case FuelType.unknown:
        return "Nieznane";
    }
  }

  /// Dekoduje PID 0151 (Fuel Type) wg SAE J1979.
  static FuelType fromObdCode(int code) {
    switch (code) {
      case 1:
      case 9:
      case 12:
      case 15:
      case 17:
        return code == 17 ? FuelType.hybrid : FuelType.petrol;
      case 4:
      case 11:
      case 20:
      case 23:
        return FuelType.diesel;
      case 8:
        return FuelType.electric;
      case 16:
      case 18:
      case 19:
      case 21:
      case 22:
        return FuelType.hybrid;
      case 0:
        return FuelType.unknown;
      default:
        return FuelType.other;
    }
  }
}

class VehicleInfo {
  final String vin;
  final String manufacturer;
  final String modelName;
  final String year;
  final String countryOfOrigin;
  final String engineDescription;
  final String ecuName;
  final String calibrationId;
  final String obdProtocol;
  final double batteryVoltage;
  final int distanceSinceDtcClearedKm;
  final int distanceWithMilOnKm;
  final String obdStandard;
  final VehicleProfile profile;
  final FuelType fuelType;

  bool get isDiesel => fuelType == FuelType.diesel;

  const VehicleInfo({
    required this.vin,
    required this.manufacturer,
    required this.modelName,
    required this.year,
    required this.countryOfOrigin,
    required this.engineDescription,
    required this.ecuName,
    required this.calibrationId,
    required this.obdProtocol,
    required this.batteryVoltage,
    required this.distanceSinceDtcClearedKm,
    required this.distanceWithMilOnKm,
    required this.obdStandard,
    this.profile = VehicleProfile.generic,
    this.fuelType = FuelType.unknown,
  });

  /// Dekoder numeru VIN zgodny ze standardem ISO 3779 / WMI
  static VehicleInfo decodeFromRawData({
    required String rawVin,
    String? rawCalId,
    String? rawEcuName,
    String? protocol,
    double? voltage,
    int? distSinceDtc,
    int? distMil,
    FuelType fuelType = FuelType.unknown,
  }) {
    final cleanVin = rawVin.replaceAll(RegExp(r'[^A-HJ-NPR-Z0-9]'), '').toUpperCase();

    String mfg = "Nieznany producent";
    String country = "Nieznany";
    String model = "Pojazd";
    String engine = "Dane silnika z ECU";  // nadpisywane niżej, jeśli rozpoznamy silnik
    VehicleProfile prof = VehicleProfile.generic;

    if (cleanVin.length >= 3) {
      final wmi = cleanVin.substring(0, 3);
      final wmi2 = cleanVin.substring(0, 2);

      // === GRUPA VAG ===
      if (wmi.startsWith("TMB")) {
        mfg = "Škoda Auto"; country = "Czechy"; model = "Octavia / Fabia / Rapid / Superb"; prof = VehicleProfile.vag;
      } else if (wmi.startsWith("TMP")) {
        mfg = "Škoda Auto"; country = "Czechy"; model = "Kodiaq / Karoq / Enyaq"; prof = VehicleProfile.vag;
      } else if (wmi == "WVW") {
        mfg = "Volkswagen"; country = "Niemcy"; model = "Golf / Passat / Polo / Arteon"; prof = VehicleProfile.vag;
      } else if (wmi == "WVG") {
        mfg = "Volkswagen"; country = "Niemcy"; model = "Touran / Tiguan / Sharan / T-Roc"; prof = VehicleProfile.vag;
      } else if (wmi == "WV1" || wmi == "WV2" || wmi == "WV3") {
        mfg = "Volkswagen (Użytkowe)"; country = "Niemcy"; model = "Caddy / Transporter / Crafter"; prof = VehicleProfile.vag;
      } else if (wmi == "3VW" || wmi == "3VV") {
        mfg = "Volkswagen"; country = "Meksyk"; model = "Jetta / Taos / Tiguan"; prof = VehicleProfile.vag;
      } else if (wmi == "WAU" || wmi == "WAG" || wmi == "TRU") {
        mfg = "Audi"; country = "Niemcy / Węgry"; model = "A3 / A4 / A6 / Q5 / Q7"; prof = VehicleProfile.vag;
      } else if (wmi == "VSS") {
        mfg = "SEAT / Cupra"; country = "Hiszpania"; model = "Leon / Ibiza / Ateca / Formentor"; prof = VehicleProfile.vag;
      // === BMW ===
      } else if (wmi == "WBA" || wmi == "WBS" || wmi == "WBY" || wmi == "WBX") {
        mfg = "BMW"; country = "Niemcy"; model = "Seria 1-7 / X1-X7 / M"; prof = VehicleProfile.bmw;
      } else if (wmi == "WMW") {
        mfg = "MINI (BMW)"; country = "Wielka Brytania"; model = "Cooper / Countryman / Clubman"; prof = VehicleProfile.bmw;
      // === MERCEDES ===
      } else if (wmi == "WDB" || wmi == "WDD" || wmi == "WDC" || wmi == "WDF" || wmi == "W1K" || wmi == "W1N") {
        mfg = "Mercedes-Benz"; country = "Niemcy"; model = "Klasa A-S / GLA-GLS / Vito";
      // === OPEL / VAUXHALL ===
      } else if (wmi == "W0L" || wmi == "W0V") {
        mfg = "Opel"; country = "Niemcy"; model = "Astra / Corsa / Insignia / Mokka";
      // === FORD ===
      } else if (wmi == "WF0" || wmi == "WF1") {
        mfg = "Ford"; country = "Europa"; model = "Focus / Fiesta / Mondeo / Kuga";
      } else if (wmi2 == "1F" || wmi2 == "3F") {
        mfg = "Ford"; country = "USA / Meksyk"; model = "Mustang / F-150 / Explorer";
      // === STELLANTIS (PSA + FCA) ===
      } else if (wmi == "VF3") {
        mfg = "Peugeot"; country = "Francja"; model = "208 / 308 / 3008 / 508"; prof = VehicleProfile.psa;
      } else if (wmi == "VF7" || wmi == "VF7") {
        mfg = "Citroën"; country = "Francja"; model = "C3 / C4 / C5 / Berlingo"; prof = VehicleProfile.psa;
      } else if (wmi == "VF1" || wmi == "VF6") {
        mfg = "Renault"; country = "Francja"; model = "Clio / Megane / Captur / Kadjar";
      } else if (wmi == "VF8") {
        mfg = "Maserati / DS"; country = "Francja / Włochy";
      } else if (wmi == "VNE" || wmi == "VN1") {
        mfg = "Renault / Dacia"; country = "Francja / Rumunia"; model = "Duster / Sandero / Logan";
      } else if (wmi == "UU1" || wmi == "UU6") {
        mfg = "Dacia"; country = "Rumunia"; model = "Duster / Sandero / Jogger";
      } else if (wmi == "ZAR") {
        mfg = "Alfa Romeo"; country = "Włochy"; model = "Giulia / Stelvio / Giulietta"; prof = VehicleProfile.fca;
      } else if (wmi == "ZFA") {
        mfg = "Fiat"; country = "Włochy / Polska"; model = "500 / Tipo / Panda / Ducato"; prof = VehicleProfile.fca;
      } else if (wmi == "ZLA") {
        mfg = "Lancia"; country = "Włochy"; prof = VehicleProfile.fca;
      } else if (wmi == "ZHW") {
        mfg = "Lamborghini"; country = "Włochy"; prof = VehicleProfile.vag;
      // === JAPONIA ===
      } else if (wmi2 == "JT" || wmi == "SB1" || wmi2 == "NM") {
        mfg = "Toyota"; country = "Japonia / Turcja / Wielka Brytania"; model = "Corolla / Yaris / RAV4 / Aygo";
      } else if (wmi2 == "JN" || wmi == "SJN" || wmi == "VNK") {
        mfg = "Nissan"; country = "Japonia / Wielka Brytania"; model = "Qashqai / Juke / X-Trail / Micra";
      } else if (wmi2 == "JM" || wmi == "MM8") {
        mfg = "Mazda"; country = "Japonia"; model = "3 / 6 / CX-5 / CX-30 / MX-5";
      } else if (wmi == "JHM" || wmi == "SHH" || wmi == "RLH") {
        mfg = "Honda"; country = "Japonia / Wielka Brytania"; model = "Civic / CR-V / HR-V / Jazz";
      } else if (wmi2 == "JS" || wmi == "TSM") {
        mfg = "Suzuki"; country = "Japonia / Węgry"; model = "Swift / Vitara / SX4 / Jimny";
      } else if (wmi == "JF1" || wmi == "JF2") {
        mfg = "Subaru"; country = "Japonia"; model = "Impreza / Forester / Outback / XV";
      } else if (wmi2 == "JA") {
        mfg = "Mitsubishi"; country = "Japonia"; model = "ASX / Outlander / Eclipse Cross";
      // === KOREA ===
      } else if (wmi2 == "KM" || wmi == "TMA" || wmi == "NLE") {
        mfg = "Hyundai"; country = "Korea Płd. / Czechy / Turcja"; model = "i20 / i30 / Tucson / Kona";
      } else if (wmi2 == "KN" || wmi == "U5Y" || wmi == "U6Y") {
        mfg = "Kia"; country = "Korea Płd. / Słowacja"; model = "Ceed / Sportage / Niro / Picanto";
      // === VOLVO ===
      } else if (wmi == "YV1" || wmi == "YV4") {
        mfg = "Volvo"; country = "Szwecja / Belgia"; model = "V40 / V60 / XC40 / XC60 / XC90";
      // === SAAB ===
      } else if (wmi == "YS3") {
        mfg = "Saab"; country = "Szwecja"; model = "9-3 / 9-5";
      // === LAND ROVER / JAGUAR ===
      } else if (wmi == "SAL" || wmi == "SAJ") {
        mfg = wmi == "SAL" ? "Land Rover" : "Jaguar"; country = "Wielka Brytania";
      // === PORSCHE ===
      } else if (wmi == "WP0" || wmi == "WP1") {
        mfg = "Porsche"; country = "Niemcy"; model = "Cayenne / Macan / 911 / Panamera"; prof = VehicleProfile.vag;
      // === TESLA ===
      } else if (wmi == "5YJ" || wmi == "7SA" || wmi == "LRW") {
        mfg = "Tesla"; country = "USA / Chiny"; model = "Model 3 / Model Y / Model S";
      // === USA ===
      } else if (wmi2 == "1G" || wmi2 == "2G" || wmi2 == "3G") {
        mfg = "General Motors"; country = "USA / Kanada"; model = "Chevrolet / GMC / Cadillac";
      // === Fallback: rozpoznaj kraj z pierwszego znaku VIN ===
      } else {
        final c1 = cleanVin[0];
        if ("12345".contains(c1)) country = "Ameryka Północna";
        else if (c1 == 'J') country = "Japonia";
        else if (c1 == 'K') country = "Korea Południowa";
        else if (c1 == 'L') country = "Chiny";
        else if (c1 == 'S') country = "Wielka Brytania";
        else if ("TVWXYZ".contains(c1)) country = "Europa";
        else if (c1 == '9') country = "Ameryka Południowa";
      }
    }

    // Grupa VAG: w europejskich VIN-ach pozycje 4-6 to "ZZZ", a kod modelu
    // (typ nadwozia) jest na pozycjach 7-8, np. WVGZZZ1TZFW... -> "1T" = Touran.
    if (prof == VehicleProfile.vag && cleanVin.length >= 8) {
      final vagModel = vagModelCodes[cleanVin.substring(6, 8)];
      if (vagModel != null) model = vagModel;
    }

    // Silnik rozpoznajemy po numerze oprogramowania sterownika (np. 03L906023PJ)
    final ecuEngine = engineFromEcuPart(rawCalId);
    if (ecuEngine != null) {
      engine = ecuEngine.$1;
      if (fuelType == FuelType.unknown) fuelType = ecuEngine.$2;
    }
    if (fuelType != FuelType.unknown) {
      engine = engine == "Dane silnika z ECU" ? fuelType.label : "$engine • ${fuelType.label}";
    }

    // Rok modelowy z 10. znaku numeru VIN
    String year = "Nieokreślony";
    if (cleanVin.length >= 10) {
      final char10 = cleanVin[9];
      const yearMap = {
        '1': '2001', '2': '2002', '3': '2003', '4': '2004', '5': '2005',
        '6': '2006', '7': '2007', '8': '2008', '9': '2009',
        'A': '2010', 'B': '2011', 'C': '2012', 'D': '2013', 'E': '2014',
        'F': '2015', 'G': '2016', 'H': '2017', 'J': '2018', 'K': '2019',
        'L': '2020', 'M': '2021', 'N': '2022', 'P': '2023', 'R': '2024',
        'S': '2025', 'T': '2026',
      };
      year = yearMap[char10] ?? "2010+";
    }

    return VehicleInfo(
      vin: cleanVin.isNotEmpty ? cleanVin : "BRAK ODCZYTU VIN",
      manufacturer: mfg,
      modelName: model,
      year: year,
      countryOfOrigin: country,
      engineDescription: engine,
      ecuName: rawEcuName ?? "Sterownik silnika ECU (Mode 09)",
      calibrationId: rawCalId ?? "Brak danych kalibracji",
      obdProtocol: protocol ?? "ISO 15765-4 (CAN 11bit 500k)",
      batteryVoltage: voltage ?? 12.6,
      distanceSinceDtcClearedKm: distSinceDtc ?? 0,
      distanceWithMilOnKm: distMil ?? 0,
      obdStandard: "EOBD / OBD-II (Zgodny)",
      profile: prof,
      fuelType: fuelType,
    );
  }

  /// Kody modeli VAG z pozycji 7-8 numeru VIN.
  static const Map<String, String> vagModelCodes = {
    // Volkswagen
    "1T": "Touran (1T)", "5T": "Touran II (5T)", "5N": "Tiguan (5N)", "AD": "Tiguan II (AD)",
    "BW": "Tiguan II (BW)", "7N": "Sharan (7N)", "A1": "T-Roc (A1)", "C1": "T-Cross (C1)",
    "1K": "Golf V / Jetta (1K)", "5K": "Golf VI (5K)", "AJ": "Golf VI (AJ)", "5G": "Golf VII (5G)",
    "AU": "Golf VII (AU)", "BQ": "Golf VIII (BQ)", "CD": "Golf VIII (CD)", "1Y": "Golf Plus (1Y)",
    "5M": "Golf Plus (5M)", "3C": "Passat B6/B7 (3C)", "36": "Passat B7 (36)", "3G": "Passat B8 (3G)",
    "6R": "Polo V (6R)", "AW": "Polo VI (AW)", "13": "Scirocco (13)", "16": "Jetta VI (16)",
    "3H": "Arteon (3H)", "7P": "Touareg II (7P)", "CR": "Touareg III (CR)", "2K": "Caddy (2K)",
    "SA": "Caddy V (SA)", "7H": "Transporter T5 (7H)", "7J": "Transporter T5 (7J)",
    "SG": "Transporter T6 (SG)", "SH": "Transporter T6 (SH)", "2E": "Crafter (2E)",
    "SY": "Crafter II (SY)", "2H": "Amarok (2H)", "1Z": "Octavia II / Up! (1Z)",
    // Škoda
    "5E": "Octavia III (5E)", "NX": "Octavia IV (NX)", "NH": "Rapid (NH)", "NJ": "Fabia III (NJ)",
    "5J": "Fabia II / Roomster (5J)", "3T": "Superb II (3T)", "3V": "Superb III (3V)",
    "NS": "Kodiaq (NS)", "NU": "Karoq (NU)", "5L": "Yeti (5L)", "KJ": "Kamiq / Ibiza (KJ)",
    // Audi
    "8P": "A3 (8P)", "8V": "A3 (8V)", "8Y": "A3 (8Y)", "8K": "A4 (8K)", "8W": "A4 (8W)",
    "4G": "A6 (4G)", "4A": "A6 (4A)", "8U": "Q3 (8U)", "F3": "Q3 (F3)", "8R": "Q5 (8R)",
    "FY": "Q5 (FY)", "4L": "Q7 (4L)", "4M": "Q7 (4M)", "8X": "A1 (8X)",
    // SEAT
    "1P": "Leon II (1P)", "5F": "Leon III (5F)", "6J": "Ibiza IV (6J)", "5P": "Altea / Toledo (5P)",
    "KH": "Ateca (KH)",
  };

  /// Rozpoznaje rodzinę silnika VAG po numerze części oprogramowania ECU.
  static (String, FuelType)? engineFromEcuPart(String? calId) {
    if (calId == null) return null;
    final s = calId.toUpperCase().replaceAll(' ', '');
    const families = <String, (String, FuelType)>{
      "03L906": ("TDI CR EA189 (1.6 / 2.0 TDI Common Rail)", FuelType.diesel),
      "03L907": ("TDI CR EA189 (1.6 / 2.0 TDI Common Rail)", FuelType.diesel),
      "04L906": ("TDI EA288 (1.6 / 2.0 TDI Common Rail)", FuelType.diesel),
      "04L907": ("TDI EA288 (1.6 / 2.0 TDI Common Rail)", FuelType.diesel),
      "03P906": ("1.2 TDI CR EA189", FuelType.diesel),
      "03G906": ("TDI PD (1.9 / 2.0 Pompowtryskiwacze)", FuelType.diesel),
      "038906": ("TDI PD (1.9 Pompowtryskiwacze)", FuelType.diesel),
      "045906": ("1.4 TDI PD", FuelType.diesel),
      "059906": ("V6 TDI (2.7 / 3.0)", FuelType.diesel),
      "03C906": ("1.4 TSI / FSI EA111", FuelType.petrol),
      "03F906": ("1.2 TSI EA111", FuelType.petrol),
      "04E906": ("1.0-1.5 TSI EA211", FuelType.petrol),
      "04E907": ("1.0-1.5 TSI EA211", FuelType.petrol),
      "04C906": ("1.0 / 1.2 TSI/MPI EA211", FuelType.petrol),
      "04C907": ("1.0 TSI/MPI EA211", FuelType.petrol),
      "06J906": ("1.8 / 2.0 TSI EA888", FuelType.petrol),
      "06K906": ("1.8 / 2.0 TSI EA888 gen3", FuelType.petrol),
      "06K907": ("1.8 / 2.0 TSI EA888 gen3", FuelType.petrol),
      "8V0906": ("1.8 / 2.0 TSI EA888 gen3", FuelType.petrol),
      "5G0906": ("1.8 / 2.0 TSI EA888 gen3", FuelType.petrol),
      "06A906": ("1.6 / 1.8 / 2.0 MPI / 1.8T", FuelType.petrol),
    };
    for (final entry in families.entries) {
      if (s.contains(entry.key)) return entry.value;
    }
    return null;
  }
}
