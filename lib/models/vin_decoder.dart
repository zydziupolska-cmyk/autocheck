/// Prosty dekoder VIN: marka (z WMI) i rok modelowy. Nie dekoduje kodu silnika
/// (VIN nie niesie go w sposób pewny dla większości marek), ale pozwala sprawdzić,
/// czy rozpoznany silnik pasuje do marki, i zawęzić wybór.
library;

class VinInfo {
  final String vin;
  final String? make; // marka wg WMI (np. "Volkswagen")
  final int? year; // rok modelowy z pozycji 10
  const VinInfo(this.vin, {this.make, this.year});

  bool get valid => vin.length == 17;
}

class VinDecoder {
  /// WMI (pierwsze 3 znaki, część marek rozpoznaje się po 2) → marka.
  static const Map<String, String> _wmi = {
    "WVW": "Volkswagen", "WVG": "Volkswagen", "1VW": "Volkswagen", "3VW": "Volkswagen", "WV1": "Volkswagen", "WV2": "Volkswagen",
    "WAU": "Audi", "TRU": "Audi", "WUA": "Audi", "93U": "Audi",
    "TMB": "Škoda",
    "VSS": "Seat",
    "WBA": "BMW", "WBS": "BMW", "WBY": "BMW", "4US": "BMW", "5UX": "BMW",
    "WDB": "Mercedes-Benz", "WDD": "Mercedes-Benz", "WDC": "Mercedes-Benz", "W1K": "Mercedes-Benz", "W1N": "Mercedes-Benz",
    "VF7": "Citroën", "VF3": "Peugeot", "VR3": "Peugeot", "VR7": "Citroën", "VR1": "DS",
    "VF1": "Renault", "VF6": "Renault", "VNV": "Renault", "UU1": "Dacia", "UU6": "Dacia",
    "VF9": "różne (VF9)",
    "WF0": "Ford", "1FA": "Ford", "3FA": "Ford", "WF3": "Ford",
    "W0L": "Opel", "W0V": "Opel", "VXK": "Opel", "W0S": "Opel",
    "ZFA": "Fiat", "ZFC": "Fiat", "ZAR": "Alfa Romeo", "ZFF": "Ferrari", "ZLA": "Lancia",
    "JMZ": "Mazda", "JM1": "Mazda", "JM3": "Mazda",
    "JT": "Toyota", "SB1": "Toyota", "VNK": "Toyota", "NMT": "Toyota", "JTD": "Toyota", "JTM": "Toyota", "JTN": "Toyota",
    "JHM": "Honda", "SHH": "Honda", "JHL": "Honda", "NLA": "Honda",
    "KMH": "Hyundai", "TMA": "Hyundai", "KMF": "Hyundai", "NLH": "Hyundai",
    "KNA": "Kia", "KNB": "Kia", "KND": "Kia", "U5Y": "Kia", "U6Y": "Kia",
    "YV1": "Volvo", "YV4": "Volvo", "YS3": "Saab",
    "SJN": "Nissan", "JN1": "Nissan", "VSK": "Nissan", "VWA": "Nissan",
    "JF1": "Subaru", "JF2": "Subaru",
    "WME": "Smart", "WME1": "Smart",
  };

  /// Kod roku z 10. pozycji VIN (bez I,O,Q,U,Z i 0). Cykl 30-letni.
  static int? _yearFromCode(String c) {
    const codes = "ABCDEFGHJKLMNPRSTVWXY123456789";
    final idx = codes.indexOf(c.toUpperCase());
    if (idx < 0) return null;
    // 1980+idx dla A=1980; 2010+idx dla A=2010. Wybieramy okno realistyczne.
    final y1 = 1980 + idx;
    final y2 = 2010 + idx;
    final now = DateTime.now().year;
    // Preferuj rok z okna 2010..teraz+1, inaczej starszy
    if (y2 <= now + 1) return y2;
    return y1;
  }

  /// Oczyszcza zapis VIN (spacje, myślniki, małe litery) i poprawia typowe pomyłki
  /// odczytu: O/Q → 0, I → 1 (tych liter nie ma w VIN).
  static String normalize(String raw) => raw
      .toUpperCase()
      .replaceAll(RegExp(r'[\s\-\.]'), '')
      .replaceAll('O', '0')
      .replaceAll('Q', '0')
      .replaceAll('I', '1');

  /// Czy tekst jest poprawnym numerem VIN (17 znaków, bez I/O/Q).
  static bool isValid(String vin) => RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(vin);

  /// Cyfra kontrolna (poz. 9) wg ISO 3779 — obowiązkowa w USA/Kanadzie, w Europie
  /// często nieużywana. Poprawna = mocne potwierdzenie odczytu.
  static bool hasValidCheckDigit(String vin) {
    if (!isValid(vin)) return false;
    const map = {
      'A': 1, 'B': 2, 'C': 3, 'D': 4, 'E': 5, 'F': 6, 'G': 7, 'H': 8, 'J': 1, 'K': 2, 'L': 3, 'M': 4,
      'N': 5, 'P': 7, 'R': 9, 'S': 2, 'T': 3, 'U': 4, 'V': 5, 'W': 6, 'X': 7, 'Y': 8, 'Z': 9,
    };
    const weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];
    int sum = 0;
    for (int i = 0; i < 17; i++) {
      final c = vin[i];
      final v = int.tryParse(c) ?? map[c] ?? 0;
      sum += v * weights[i];
    }
    final r = sum % 11;
    return vin[8] == (r == 10 ? 'X' : r.toString());
  }

  /// PSA (Peugeot/Citroën/DS): znaki 6–8 VIN to zwykle typ silnika z tabliczki
  /// (np. „RFN” = 2.0 16V EW10J4, „9HZ” = 1.6 HDi). Null dla innych marek.
  static String? psaEngineType(String rawVin) {
    final vin = rawVin.trim().toUpperCase();
    if (!isValid(vin)) return null;
    const psa = {"VF3", "VF7", "VR3", "VR7", "VR1"};
    if (!psa.contains(vin.substring(0, 3))) return null;
    return vin.substring(5, 8);
  }

  static VinInfo decode(String rawVin) {
    final vin = rawVin.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (vin.length != 17) return VinInfo(vin);
    String? make;
    // Najpierw pełne 3 znaki, potem 2-znakowe prefiksy (np. "JT" Toyota)
    make = _wmi[vin.substring(0, 3)];
    make ??= _wmi[vin.substring(0, 2)];
    final year = _yearFromCode(vin[9]);
    return VinInfo(vin, make: make, year: year);
  }
}
