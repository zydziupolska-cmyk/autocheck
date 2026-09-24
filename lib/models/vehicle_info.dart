import 'extended_pid.dart';

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
  }) {
    final cleanVin = rawVin.replaceAll(RegExp(r'[^A-HJ-NPR-Z0-9]'), '').toUpperCase();

    String mfg = "Nieznany producent";
    String country = "Nieznany";
    String model = "Pojazd";
    String engine = "Dane silnika z ECU";
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

    // Doprecyzowanie silnika na podstawie VDS (pozycje 4-6 VIN) — dotyczy grupy VAG
    if (prof == VehicleProfile.vag && cleanVin.length >= 6) {
      final vds = cleanVin.substring(3, 6);
      // Popularne kody silników VAG:
      if (vds == "EW0" || vds == "EW1") {
        engine = "1.6 TDI CR CAYC/CLHA (Common Rail / 105 KM)";
      } else if (vds == "AZ0" || vds == "AZZ") {
        engine = "2.0 TDI CR CFHC/CJAA (Common Rail / 140-170 KM)";
      } else if (vds == "BZ0" || vds == "BZZ") {
        engine = "1.4 TSI CAXA/CZCA (Turbo benzyna / 122-150 KM)";
      } else if (vds == "6R0") {
        engine = "1.2 TSI CBZB/CJZC (Turbo benzyna / 86-110 KM)";
      }
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
    );
  }

  /// Przykładowy profil dla symulatora Skoda Rapid 2017 TSI
  static final VehicleInfo skodaRapidSample = VehicleInfo(
    vin: "TMBEP6NH4H4019283",
    manufacturer: "Škoda Auto",
    modelName: "Rapid Spaceback",
    year: "2017",
    countryOfOrigin: "Czechy (Mladá Boleslav)",
    engineDescription: "1.2 TSI 16V EA211 (Bezpośredni wtrysk / HPFP)",
    ecuName: "Bosch MED17.5.25",
    calibrationId: "04C906024D_9821",
    obdProtocol: "ISO 15765-4 (CAN 11bit 500kbaud)",
    batteryVoltage: 12.4,
    distanceSinceDtcClearedKm: 42,
    distanceWithMilOnKm: 18,
    obdStandard: "EOBD + OBD-II Europa",
    profile: VehicleProfile.vag,
  );

  /// Przykładowy profil dla symulatora Peugeot 307 CC 2.0 16V
  static final VehicleInfo peugeot307Sample = VehicleInfo(
    vin: "VF33BRFNC83921094",
    manufacturer: "Peugeot (Stellantis)",
    modelName: "307 CC Coupé-Cabriolet",
    year: "2006",
    countryOfOrigin: "Francja (Sochaux)",
    engineDescription: "2.0 16V EW10A (140 KM / Wariator VVT)",
    ecuName: "Magneti Marelli IAW 6LP / Sagem",
    calibrationId: "9664539880_01",
    obdProtocol: "ISO 14230-4 (KWP FAST / CAN)",
    batteryVoltage: 12.5,
    distanceSinceDtcClearedKm: 115,
    distanceWithMilOnKm: 0,
    obdStandard: "EOBD Europa",
    profile: VehicleProfile.psa,
  );

  /// Domyślny profil wzorcowy
  static final VehicleInfo genericSample = VehicleInfo(
    vin: "WVWZZZ3CZHE102948",
    manufacturer: "Volkswagen AG",
    modelName: "Passat / Golf",
    year: "2018",
    countryOfOrigin: "Niemcy (Wolfsburg)",
    engineDescription: "2.0 TDI / TSI Common Rail",
    ecuName: "Bosch EDC17 / MED17",
    calibrationId: "03L906018BR",
    obdProtocol: "ISO 15765-4 (CAN 11bit 500kbaud)",
    batteryVoltage: 12.7,
    distanceSinceDtcClearedKm: 320,
    distanceWithMilOnKm: 0,
    obdStandard: "EOBD / OBD-II Zgodny",
    profile: VehicleProfile.vag,
  );
}
