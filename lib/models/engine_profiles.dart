/// Baza najpopularniejszych silników i ich typowych usterek.
///
/// Diagnoza z danych (analizator) zostaje dopełniona wiedzą o konkretnym silniku:
/// gdy wykryta anomalia pasuje do znanej, częstej przypadłości danej jednostki,
/// aplikacja dodaje krótką notatkę „typowe dla tego silnika…”. To wiedza
/// warsztatowa/ogólnodostępna o powtarzalnych wadach, nie diagnoza sama w sobie —
/// najpierw liczą się dane z auta, potem dopasowanie do silnika.
library;

/// Obszar usterki — do łączenia anomalii z danych z wiedzą o silniku.
enum FaultArea {
  turbo, // doładowanie, geometria VGT, wastegate
  intake, // nieszczelność dolotu, zawirowywacze
  dpf, // filtr cząstek stałych
  egr, // recyrkulacja spalin
  railPressure, // ciśnienie na szynie, pompa/regulator
  injectors, // wtryskiwacze
  misfire, // wypadanie zapłonu
  timing, // rozrząd (łańcuch/pasek), zmienne fazy
  ignition, // zapłon, cewki, świece (benzyna)
  mixture, // skład mieszanki, lewe powietrze (benzyna)
  oil, // olej, zużycie, rozcieńczenie
  cooling, // układ chłodzenia
}

/// Jedna znana, częsta usterka danego silnika.
class EngineFault {
  final Set<FaultArea> areas;
  final String title;
  final String note; // krótki opis dla mechanika
  const EngineFault(this.areas, this.title, this.note);
}

/// Profil silnika: dopasowanie po danych pojazdu + lista typowych usterek.
class EngineProfile {
  final String code; // np. "EA189", "N47"
  final String name; // czytelna nazwa
  final List<String> aliases; // wzorce do wykrycia (kody, pojemności, ECU)
  final List<EngineFault> faults;
  const EngineProfile(this.code, this.name, this.aliases, this.faults);

  EngineFault? faultFor(FaultArea area) {
    for (final f in faults) {
      if (f.areas.contains(area)) return f;
    }
    return null;
  }
}

class EngineProfiles {
  /// Wykrywa silnik na podstawie tekstu złożonego z danych pojazdu
  /// (producent, opis silnika, CALID/numer części, model, VIN).
  static EngineProfile? detect(String haystack) {
    final s = haystack.toUpperCase();
    for (final p in all) {
      for (final a in p.aliases) {
        if (s.contains(a.toUpperCase())) return p;
      }
    }
    return null;
  }

  static const List<EngineProfile> all = [
    // ---------------------------------------------------------------- VAG diesle
    EngineProfile("EA189", "VW/Audi/Škoda/Seat 1.6/2.0 TDI (EA189)", [
      "EA189", "03L906", "CFFB", "CFHC", "CAYC", "CAYB", "CLCA", "CFWA",
    ], [
      EngineFault({FaultArea.turbo}, "Zapieczona geometria turbiny (VNT)",
          "Bardzo częste: cięgno i łopatki geometrii zapiekają się nagarem, turbo nie buduje pełnego ciśnienia. Zwykle da się wyczyścić bez wymiany."),
      EngineFault({FaultArea.egr, FaultArea.intake}, "Zapchany EGR i kolektor ssący",
          "Chłodnica i zawór EGR oraz kolektor zarastają nagarem z sadzą — spadek mocy, tryb awaryjny."),
      EngineFault({FaultArea.dpf}, "Zapychanie DPF od krótkich tras",
          "Filtr nie dopala się na krótkich dystansach; sprawdź różnicę ciśnień i przebieg od ostatniej regeneracji."),
    ]),
    EngineProfile("EA288", "VW/Audi 1.6/2.0 TDI (EA288)", [
      "EA288", "04L906", "DFCA", "DFGA", "CRLB", "CRBC", "DBGA",
    ], [
      EngineFault({FaultArea.egr, FaultArea.dpf}, "Moduł chłodnicy EGR i AGR",
          "Nowszy układ z dwoma EGR; częste błędy chłodnicy AGR i czujników różnicy ciśnień DPF."),
      EngineFault({FaultArea.turbo}, "Czujnik/elektrozawór sterowania turbiną",
          "Niedoładowanie bywa od sterowania geometrią, nie od samej turbiny."),
    ]),
    EngineProfile("PD_TDI", "VW/Audi 1.9/2.0 TDI pompowtryski (PD)", [
      "BXE", "BKC", "BLS", "BKD", "AZV", "BMM", "ASZ", "ARL", "PD TDI", "POMPOWTRYSK",
    ], [
      EngineFault({FaultArea.injectors}, "Zużyte pompowtryskiwacze",
          "Charakterystyczne dla PD: rosnące korekty pojedynczego wtrysku, stukanie, dymienie. Diagnoza z korekt równomierności."),
      EngineFault({FaultArea.turbo}, "Zacięta geometria turbiny",
          "Jak w innych TDI: nagar w geometrii, brak pełnego doładowania."),
      EngineFault({FaultArea.timing}, "Wada wałka i pompy oleju (BKD/AZV)",
          "Znane wycieranie wałka napędu pompy oleju — kontrola ciśnienia oleju."),
    ]),
    EngineProfile("CR_TDI_20", "VW/Audi 2.0 TDI Common Rail (CR)", [
      "CBAB", "CBAA", "CBBB", "CFGB", "CFGC", "CLLA", "CGLC", "CSHA",
    ], [
      EngineFault({FaultArea.railPressure, FaultArea.injectors}, "Regulator ciśnienia i wtryskiwacze CR",
          "Spadek ciśnienia szyny pod obciążeniem: regulator/pompa; lejący wtrysk na jałowym: korekta pojedynczego cylindra."),
      EngineFault({FaultArea.timing}, "Rozciągnięty łańcuch rozrządu (wczesne CR)",
          "Wczesne 2.0 CR miały problem z łańcuchem — kontrola przy błędach korelacji wałków."),
    ]),
    // ---------------------------------------------------------------- VAG benzyny
    EngineProfile("EA888", "VW/Audi 1.8/2.0 TSI/TFSI (EA888)", [
      "EA888", "06K906", "06J906", "CDAB", "CCZA", "CJSA", "CNCD", "CPMA", "TSI", "TFSI",
    ], [
      EngineFault({FaultArea.oil, FaultArea.mixture}, "Nadmierne zużycie oleju (gen. 2)",
          "Tłoki i pierścienie gen. 2 (do ~2013): duże zużycie oleju, zaolejone świece, dymienie."),
      EngineFault({FaultArea.timing}, "Rozciągnięty łańcuch rozrządu",
          "Napinacz łańcucha gen. 1/2 — grzechot na zimnym rozruchu, ryzyko przeskoku."),
      EngineFault({FaultArea.intake, FaultArea.mixture}, "Nagar na zaworach ssących (wtrysk bezpośredni)",
          "Bezpośredni wtrysk: zawory zarastają nagarem — nierówna praca, spadek mocy."),
    ]),
    EngineProfile("EA111", "VW/Audi 1.2/1.4 TSI (EA111)", [
      "EA111", "03C906", "CAXA", "CAVD", "CBZB", "CTHD", "CAVA",
    ], [
      EngineFault({FaultArea.timing}, "Przeskok/zerwanie łańcucha rozrządu",
          "Sztandarowa wada 1.4 TSI (CAXA/CAVD): napinacz łańcucha — grzechot na zimno, ryzyko zgięcia zaworów."),
      EngineFault({FaultArea.turbo, FaultArea.intake}, "Zawór upustowy i uszczelnienia doładowania",
          "Membrana zaworu upustowego, przecieki w dolocie — spadek doładowania."),
    ]),
    EngineProfile("EA211", "VW/Audi 1.0/1.4/1.5 TSI (EA211)", [
      "EA211", "04E906", "CZCA", "CZEA", "DADA", "CHZ", "DPCA",
    ], [
      EngineFault({FaultArea.turbo}, "Szarpanie 1.5 TSI (EVO) na częściowym gazie",
          "Znane szarpanie/zawahania przy stałej prędkości — aktualizacje software i sterowanie doładowaniem."),
      EngineFault({FaultArea.timing}, "Łańcuch/napinacz (starsze 1.4)",
          "Kontrola napinacza przy grzechocie na rozruchu."),
    ]),
    // ---------------------------------------------------------------- BMW
    EngineProfile("N47", "BMW 2.0d (N47)", ["N47", "204D"], [
      EngineFault({FaultArea.timing}, "Rozciągnięty łańcuch rozrządu (od strony koła zamachowego)",
          "Sztandarowa wada N47: łańcuch z tyłu silnika, kosztowna wymiana. Grzechot z tyłu jednostki."),
      EngineFault({FaultArea.egr, FaultArea.intake}, "EGR i zawirowywacze w kolektorze",
          "Nagar w kolektorze, urwane klapki zawirowywaczy zassane do cylindra."),
      EngineFault({FaultArea.turbo}, "Geometria turbiny",
          "Zapiekanie geometrii przy jeździe miejskiej."),
    ]),
    EngineProfile("N57", "BMW 3.0d (N57)", ["N57", "306D"], [
      EngineFault({FaultArea.intake}, "Urwane klapki zawirowywaczy (swirl flaps)",
          "Klapki dolotu potrafią się urwać i trafić do cylindra — częsta, kosztowna usterka."),
      EngineFault({FaultArea.egr}, "Chłodnica EGR (akcje serwisowe)",
          "Nieszczelna/pękająca chłodnica EGR — była objęta akcjami."),
    ]),
    EngineProfile("N54_N55", "BMW 3.0 benzyna twin/single turbo (N54/N55)", ["N54", "N55", "306KH", "335I", "135I"], [
      EngineFault({FaultArea.injectors, FaultArea.misfire}, "Wtryskiwacze piezo i cewki (N54)",
          "N54: wtryskiwacze i cewki to typowe źródło wypadania i szarpania."),
      EngineFault({FaultArea.turbo}, "Zawory upustowe turbin (wastegate rattle)",
          "Grzechot siłowników wastegate, spadek doładowania — znana wada."),
      EngineFault({FaultArea.oil}, "Pompa i uszczelnienia oleju",
          "Wycieki (uszczelka pokrywy, obudowa filtra) i zużycie oleju."),
    ]),
    EngineProfile("N20", "BMW 2.0 benzyna turbo (N20)", ["N20", "N26", "228I", "328I", "428I"], [
      EngineFault({FaultArea.timing}, "Rozciągnięty łańcuch rozrządu",
          "N20: łańcuch i prowadnice do kontroli, grzechot na zimno."),
      EngineFault({FaultArea.oil}, "Zużycie oleju / uszczelnienia",
          "Podwyższone zużycie oleju i wycieki."),
    ]),
    EngineProfile("B47_B57", "BMW 2.0d/3.0d (B47/B57)", ["B47", "B57"], [
      EngineFault({FaultArea.egr, FaultArea.dpf}, "Chłodnica EGR i DPF",
          "Nowsze diesle: nieszczelności EGR, zapychanie DPF przy krótkich trasach."),
    ]),
    // ---------------------------------------------------------------- PSA / Ford
    EngineProfile("DV6", "PSA/Ford 1.6 HDi/TDCi (DV6)", [
      "DV6", "1.6 HDI", "1.6 TDCI", "9HZ", "9HP", "9H0", "T1DA", "T3DA",
    ], [
      EngineFault({FaultArea.turbo, FaultArea.oil}, "Zatarcie turbiny od zatkanego sitka oleju",
          "Klasyk DV6: sitko poboru oleju do turbiny zarasta szlamem — głodzenie i zatarcie turbo. Wymieniać sitko przy turbinie."),
      EngineFault({FaultArea.dpf}, "Zapychanie FAP i dodatek Eolys",
          "System FAP z dodatkiem; kontrola poziomu dodatku i różnicy ciśnień."),
      EngineFault({FaultArea.injectors}, "Wtryskiwacze (Siemens/Continental)",
          "Rosnące korekty i przelewy — typowe zużycie wtrysków."),
    ]),
    EngineProfile("DW10", "PSA/Ford 2.0 HDi/TDCi (DW10)", [
      "DW10", "2.0 HDI", "2.0 TDCI", "RHR", "RHF", "RHH", "AHX",
    ], [
      EngineFault({FaultArea.turbo}, "Geometria turbiny i sterowanie",
          "Zapiekanie geometrii, sterowanie podciśnieniem — spadek doładowania."),
      EngineFault({FaultArea.injectors, FaultArea.railPressure}, "Wtryskiwacze i regulator ciśnienia",
          "Zużyte wtryski i regulator na pompie — wahania ciśnienia szyny."),
    ]),
    EngineProfile("ECOBOOST_10", "Ford 1.0 EcoBoost", ["ECOBOOST", "1.0 ECOBOOST", "SFDA", "SFJA"], [
      EngineFault({FaultArea.cooling}, "Pęknięcia układu chłodzenia / przegrzanie",
          "Wczesne 1.0 EcoBoost: problemy z chłodzeniem (przewody, degas) grożące przegrzaniem."),
      EngineFault({FaultArea.timing}, "Pasek rozrządu w oleju",
          "Pasek pracujący w oleju — wymiana wg planu, kontrola stanu."),
    ]),
    // ---------------------------------------------------------------- Renault / Fiat / Opel
    EngineProfile("K9K", "Renault/Nissan/Dacia 1.5 dCi (K9K)", ["K9K", "1.5 DCI"], [
      EngineFault({FaultArea.turbo, FaultArea.oil}, "Zatarcie turbiny od oleju/sitka",
          "Podobnie jak DV6: głodzenie olejowe turbiny; kontrola przewodu i sitka oleju."),
      EngineFault({FaultArea.injectors}, "Wtryskiwacze (Delphi/Bosch)",
          "Częste zużycie wtrysków, duże przelewy."),
    ]),
    EngineProfile("MULTIJET_13", "Fiat/Opel 1.3 MultiJet/CDTI", ["1.3 MULTIJET", "1.3 CDTI", "199A", "Z13DT", "A13DT"], [
      EngineFault({FaultArea.turbo}, "Mała turbina i sterowanie doładowaniem",
          "Spadki doładowania od sterowania i geometrii; częste w miejskiej eksploatacji."),
      EngineFault({FaultArea.dpf}, "Zapychanie DPF (wersje z filtrem)",
          "Krótkie trasy = niedopalony filtr."),
    ]),
    EngineProfile("CDTI_17_19", "Opel 1.7/1.9 CDTI (Isuzu/Fiat)", ["1.7 CDTI", "1.9 CDTI", "Z17DT", "Z19DT", "A17DT"], [
      EngineFault({FaultArea.egr, FaultArea.intake}, "EGR i kolektor",
          "Zarastanie EGR i kolektora nagarem — spadek mocy, tryb awaryjny."),
      EngineFault({FaultArea.turbo}, "Geometria turbiny",
          "Zapiekanie geometrii przy krótkich trasach."),
    ]),
    // ---------------------------------------------------------------- Mercedes / Toyota / Honda
    EngineProfile("OM651", "Mercedes 2.1 CDI (OM651)", ["OM651", "651"], [
      EngineFault({FaultArea.injectors}, "Wtryskiwacze (Delphi, wczesne serie)",
          "Wczesne OM651 z wtryskami Delphi — przelewy i zużycie."),
      EngineFault({FaultArea.timing}, "Rozciągnięty łańcuch rozrządu",
          "Kontrola łańcucha i kół zębatych przy grzechocie."),
    ]),
    EngineProfile("OM642", "Mercedes 3.0 V6 CDI (OM642)", ["OM642", "642"], [
      EngineFault({FaultArea.intake, FaultArea.egr}, "Kolektory ssące i EGR (nagar)",
          "Zarastanie kolektorów i klap zawirowujących nagarem."),
      EngineFault({FaultArea.oil}, "Wyciek z chłodnicy oleju (uszczelki)",
          "Znany wyciek spod chłodnicy oleju w widłach V."),
    ]),
    EngineProfile("D4D_22", "Toyota 2.0/2.2 D-4D", ["D-4D", "D4D", "1AD", "2AD", "1CD"], [
      EngineFault({FaultArea.dpf, FaultArea.injectors}, "DPF i wtryskiwacze (2AD)",
          "2AD-FTV: znane problemy z DPF i uszczelnieniem wtrysków (przedmuchy)."),
    ]),
    EngineProfile("TSI_EA211_GTE", "Hybrydy VAG 1.4 TSI (GTE/plug-in)", ["GTE", "DGEA", "PLUG-IN"], [
      EngineFault({FaultArea.mixture}, "Nagar od częstej jazdy elektrycznej",
          "Rzadka praca silnika sprzyja zarastaniu — okresowe „przepalenie” pomaga."),
    ]),
  ];
}
