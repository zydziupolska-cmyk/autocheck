import csv
import re
import sys

# Słownik tłumaczeń (zamienia surowe, inżynieryjne nazwy z UDS na czytelne, polskie terminy)
TRANSLATIONS = {
    "charge pressure actual": "Rzeczywiste Ciśnienie Doładowania",
    "charge pressure specified": "Zadane Ciśnienie Doładowania (Target)",
    "fuel rail pressure mqb": "Ciśnienie Paliwa (Rail/HPFP)",
    "lambda actual": "Rzeczywisty AFR (Lambda)",
    "lambda specified": "Zadany AFR (Target Lambda)",
    "timing correction cyl 1": "Korekta Zapłonu (Stuk) Cyl. 1",
    "timing correction cyl 2": "Korekta Zapłonu (Stuk) Cyl. 2",
    "timing correction cyl 3": "Korekta Zapłonu (Stuk) Cyl. 3",
    "timing correction cyl 4": "Korekta Zapłonu (Stuk) Cyl. 4",
    "timing cyl 1": "Kąt Wyprzedzenia Zapłonu Cyl. 1",
    "torque actual": "Aktualny Moment Obrotowy",
    "wastegate position actual": "Fizyczna Pozycja Wastegate",
    "wastegate position specified": "Zadana Pozycja Wastegate (Target)",
    "engine speed": "Obroty Silnika (RPM)",
    "engine oil temperature": "Temperatura Oleju Silnikowego",
    "transmission fluid temperature": "Temperatura Oleju Skrzyni",
    "exhaust gas temperature": "Temperatura Spalin (EGT)",
    "state of charge": "Poziom Naładowania Baterii (SoC)",
}

def translate_name(raw_name):
    lower_name = raw_name.lower().strip()
    for key, translated in TRANSLATIONS.items():
        if key in lower_name:
            return translated
    # Jeśli nie znaleziono tłumaczenia, zwracamy ładniej sformatowany oryginał
    return raw_name.title().replace("_", " ")

def determine_category(name):
    name = name.lower()
    if 'charge' in name or 'boost' in name or 'wastegate' in name or 'turbo' in name:
        return 'PidCategory.turbo'
    if 'lambda' in name or 'afr' in name or 'fuel' in name or 'injection' in name:
        return 'PidCategory.fuel'
    if 'timing' in name or 'ignition' in name or 'knock' in name or 'torque' in name:
        return 'PidCategory.engine'
    if 'temp' in name:
        return 'PidCategory.temperature'
    if 'soc' in name or 'battery' in name:
        return 'PidCategory.ev'
    return 'PidCategory.engine'

def convert_equation(eq_str):
    """
    Konwertuje równanie w formacie Torque Pro, np. '(A*256+B)*0.1' 
    na poprawny kod Dart obsługujący tablicę bajtów 'b'.
    Np. A -> b[0], B -> b[1], C -> b[2].
    Obsługuje również signed(A).
    """
    if not eq_str or eq_str.strip() == "":
        return "0.0"
        
    eq = eq_str.upper()
    
    # Obsługa signed() funkcji (U2)
    eq = re.sub(r'SIGNED\((A)\)', r'(b[0] > 127 ? b[0] - 256 : b[0])', eq)
    eq = re.sub(r'SIGNED\((B)\)', r'(b[1] > 127 ? b[1] - 256 : b[1])', eq)
    eq = re.sub(r'SIGNED\((C)\)', r'(b[2] > 127 ? b[2] - 256 : b[2])', eq)
    
    # Zamiana liter na bajty
    eq = re.sub(r'\bA\b', 'b[0]', eq)
    eq = re.sub(r'\bB\b', 'b[1]', eq)
    eq = re.sub(r'\bC\b', 'b[2]', eq)
    eq = re.sub(r'\bD\b', 'b[3]', eq)
    eq = re.sub(r'\bE\b', 'b[4]', eq)
    eq = re.sub(r'\bF\b', 'b[5]', eq)
    eq = re.sub(r'\bG\b', 'b[6]', eq)
    eq = re.sub(r'\bH\b', 'b[7]', eq)
    
    # Dart lubi double, wymuszamy konwersję by uniknąć problemów int/double
    # Dla bezpieczeństwa całość zawijamy we wrappera, który rzutuje liczby całkowite
    return f"({eq}).toDouble()"

def process_csv(input_file, profile_enum, class_name):
    pids = []
    
    with open(input_file, mode='r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for raw_row in reader:
            row = {}
            for k, v in raw_row.items():
                if k is not None:
                    clean_k = k.strip().replace('"', '')
                    clean_v = v.strip().replace('"', '') if isinstance(v, str) else v
                    row[clean_k] = clean_v
                    
            if not row.get("Name"):
                continue
                
            raw_name = row.get("Name", "").strip()
            if not raw_name:
                continue
                
            short_name = row.get("ShortName", "").strip().upper()
            if not short_name:
                short_name = raw_name[:6].upper().replace(" ", "_")
                
            mode_pid = row.get("ModeAndPID", "").strip().replace("0x", "")
            if not mode_pid:
                continue
                
            header = row.get("Header", "").strip()
            header_dart = f'"{header}"' if header else "null"
            
            eq_raw = row.get("Equation", "").strip()
            dart_eq = convert_equation(eq_raw)
            
            unit = row.get("Units", "").strip()
            min_val = row.get("Min Value", "0")
            max_val = row.get("Max Value", "100")
            
            clean_name = translate_name(raw_name)
            category = determine_category(raw_name)
            
            # Wymagane bajty na podstawie najwyższej użytej litery
            req_bytes = 1
            if 'b[1]' in dart_eq: req_bytes = 2
            if 'b[2]' in dart_eq: req_bytes = 3
            if 'b[3]' in dart_eq: req_bytes = 4
            
            decoder = f"(b) => b.length >= {req_bytes} ? {dart_eq} : 0.0"
            
            # Jeśli ciśnienie (kPa), spróbujmy zamienić na Bar (względem atmosfery, uproszczone 100 kPa ~ 1 Bar. Odejmujemy atmosferyczne jeśli to Absolute Charge)
            # W Torque Pro Charge Pressure (Absolute) to np. kPa. Bar relative to kPa/100 - 1.0. 
            # W kodzie poniżej użyjemy oryginału z Torque
            
            pids.append(f"""    ExtendedPid(
      profile: VehicleProfile.{profile_enum},
      requestCommand: "{mode_pid.upper()}",
      canHeader: {header_dart},
      code: "{mode_pid.upper()}",
      shortName: "{short_name}",
      name: "{clean_name}",
      unit: "{unit}",
      category: {category},
      colorValue: 0xFF2196F3,
      minExpected: {min_val},
      maxExpected: {max_val},
      decoder: {decoder},
    ),""")

    return pids

def main():
    # Pobierzmy CSV z MQB podany przez użytkownika
    import urllib.request
    url = "https://raw.githubusercontent.com/bri3d/MQBSimosLogVariables/master/exportedPIDs.csv"
    try:
        urllib.request.urlretrieve(url, "mqb_pids.csv")
        pids = process_csv("mqb_pids.csv", "vag", "VagPids")
        
        output = f"""// AUTO-GENERATED FILE. DO NOT EDIT.
import '../extended_pid.dart';
import '../obd_pid.dart';

class VagPids {{
  static final List<ExtendedPid> pids = [
{chr(10).join(pids)}
  ];
}}
"""
        with open("C:/Users/zydan/autocheck/lib/models/pids_db/vag_pids.dart", "w", encoding='utf-8') as f:
            f.write(output)
        print("Generated vag_pids.dart successfully!")
        
        # Generuj BMW
        bmw_pids = process_csv("C:/Users/zydan/autocheck/bmw_pids.csv", "bmw", "BmwPids")
        bmw_output = f"""// AUTO-GENERATED FILE. DO NOT EDIT.
import '../extended_pid.dart';
import '../obd_pid.dart';

class BmwPids {{
  static final List<ExtendedPid> pids = [
{chr(10).join(bmw_pids)}
  ];
}}
"""
        with open("C:/Users/zydan/autocheck/lib/models/pids_db/bmw_pids.dart", "w", encoding='utf-8') as f:
            f.write(bmw_output)
        print("Generated bmw_pids.dart successfully!")
        
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    main()
