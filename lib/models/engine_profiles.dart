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
      EngineFault({FaultArea.timing, FaultArea.oil}, "Wycierający się sześciokąt napędu pompy oleju (BKD/AZV)",
          "Klasyk 2.0 PD: wyciera się imbus napędu pompy oleju — spadek ciśnienia i zatarcie. Kontrola ciśnienia oleju."),
      EngineFault({FaultArea.cooling}, "Pękające głowice cylindrów",
          "2.0 PD bywają podatne na pęknięcia głowicy — ubytek płynu, przedmuchy."),
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
      EngineFault({FaultArea.oil}, "Pęknięte tłoki (wersja Twincharger CAVD/CTHD)",
          "1.4 TSI z turbo i kompresorem: pękające tłoki i mostki między pierścieniami — spadek kompresji, dym, wysokie zużycie oleju."),
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
      EngineFault({FaultArea.oil}, "Napęd pompy oleju (łańcuszek) i zużycie oleju",
          "Poluzowany napęd pompy oleju grozi spadkiem smarowania i zatarciem; do tego podwyższone zużycie oleju."),
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
      EngineFault({FaultArea.timing, FaultArea.oil}, "Przeskok cienkiego łańcucha, zużycie oleju (gen. 1)",
          "1.3 MultiJet 1. generacji: cienki łańcuch potrafi przeskoczyć, do tego podwyższone zużycie oleju."),
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
      EngineFault({FaultArea.cooling}, "Erozja bloku i uszczelka głowicy (2AD)",
          "Mikroerozja materiału bloku wokół tulei prowadzi do wypalenia uszczelki głowicy."),
    ]),
    EngineProfile("TSI_EA211_GTE", "Hybrydy VAG 1.4 TSI (GTE/plug-in)", ["GTE", "DGEA", "PLUG-IN"], [
      EngineFault({FaultArea.mixture}, "Nagar od częstej jazdy elektrycznej",
          "Rzadka praca silnika sprzyja zarastaniu — okresowe „przepalenie” pomaga."),
    ]),
    // ================= NAJPOPULARNIEJSZE BENZYNY (wolnossące) =================
    EngineProfile("VW_16_MPI", "VW 1.6 MPI 8V (BSE/BGU/CCSA)", [
      "1.6 MPI", "BSE", "BGU", "BSF", "BFQ", "CCSA", "CHGA", "ALZ",
    ], [
      EngineFault({FaultArea.mixture}, "Wypalanie gniazd zaworowych na LPG",
          "Wytrzymały pod gaz, ale przy złej regulacji instalacji LPG cofają się gniazda zaworów — spadek kompresji."),
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewka/przewody i przepustnica",
          "Nierówna praca zwykle od cewki, przewodów lub zabrudzonej przepustnicy."),
    ]),
    EngineProfile("TOY_ZR", "Toyota 1.6/1.8 VVT-i (2ZR/1ZR)", [
      "2ZR", "1ZR", "1.8 VVT-I", "1.6 VVT-I", "VALVEMATIC",
    ], [
      EngineFault({FaultArea.oil}, "Zużycie oleju (wczesne 2ZR)",
          "Część wczesnych 2ZR-FE zużywała olej przez pierścienie — kontrola poziomu."),
      EngineFault({FaultArea.timing}, "Grzechot rozrządu VVT-i na zimno",
          "Zużyte koło/napinacz VVT-i daje krótki grzechot przy rozruchu."),
    ]),
    EngineProfile("TOY_1ZZ", "Toyota 1.8 VVT-i (1ZZ-FE, wczesny)", ["1ZZ", "1ZZ-FE"], [
      EngineFault({FaultArea.oil}, "Blokujące się pierścienie zgarniające",
          "Wada tłoków/pierścieni wczesnego 1ZZ: bardzo duże zużycie oleju, zakoksowane pierścienie."),
    ]),
    EngineProfile("HON_R18", "Honda 1.8 i-VTEC (R18)", ["R18", "1.8 I-VTEC"], [
      EngineFault({FaultArea.egr, FaultArea.mixture}, "Zapchany EGR — falująca praca",
          "Nagar w EGR daje nierówny bieg jałowy i szarpanie; czyszczenie EGR i przepustnicy."),
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewki i świece",
          "Wypadanie zapłonu zwykle od cewek/świec."),
    ]),
    EngineProfile("OPEL_16_ECOTEC", "Opel 1.6 Ecotec (Z16XER/A16XER)", [
      "Z16XER", "A16XER", "Z16XEP", "1.6 ECOTEC",
    ], [
      EngineFault({FaultArea.timing}, "Rozciągnięty łańcuch rozrządu (Z16XER)",
          "Łańcuch i napinacz do kontroli — grzechot na zimno, błędy korelacji wałków."),
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Moduł/cewki zapłonowe",
          "Typowe źródło wypadania zapłonu."),
    ]),
    EngineProfile("FIAT_FIRE", "Fiat 1.2/1.4 FIRE 8V", ["FIRE", "1.2 8V", "1.4 8V", "188A", "350A", "169A"], [
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewka i przewody zapłonowe",
          "Tania w naprawie jednostka; nierówna praca zwykle od cewki/przewodów."),
      EngineFault({FaultArea.oil}, "Wycieki oleju (uszczelniacze)",
          "Drobne wycieki spod pokrywy i uszczelniaczy — kontrola poziomu."),
    ]),
    EngineProfile("HK_GAMMA", "Hyundai/Kia 1.4/1.6 MPI (Gamma G4F)", ["G4FA", "G4FC", "G4FG", "GAMMA"], [
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewki i świece",
          "Prosty łańcuchowy silnik; wypadanie zwykle od zapłonu."),
    ]),
    EngineProfile("REN_K4M", "Renault 1.6 16V (K4M)", ["K4M", "1.6 16V"], [
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewka (COP) i świece",
          "Trwały i pod LPG; nierówna praca zwykle od cewek."),
      EngineFault({FaultArea.mixture}, "Gniazda zaworowe przy LPG",
          "Przy zaniedbanej instalacji LPG — cofanie gniazd zaworów."),
    ]),
    EngineProfile("FORD_SIGMA", "Ford 1.4/1.6 Sigma/Duratec (Ti-VCT)", [
      "SIGMA", "DURATEC 16", "1.6 TI-VCT", "1.6 DURATEC",
    ], [
      EngineFault({FaultArea.timing}, "Fazatory zmiennych faz (Ti-VCT)",
          "Awarie kół zmiennych faz rozrządu — grzechot, błędy korelacji."),
      EngineFault({FaultArea.cooling}, "Termostat i układ chłodzenia",
          "Zawieszony termostat i wycieki — kontrola temperatury."),
    ]),
    EngineProfile("MAZDA_SKYG", "Mazda 2.0/2.5 SkyActiv-G", ["SKYACTIV", "SKYACTIV-G", "PE-VPS", "PY-VPS"], [
      EngineFault({FaultArea.intake, FaultArea.mixture}, "Nagar na zaworach ssących (wtrysk bezpośredni)",
          "Wysoka kompresja i DI — zarastanie zaworów nagarem, nierówna praca."),
      EngineFault({FaultArea.timing}, "Zmienne fazy rozrządu",
          "Kontrola elektrozaworów i kół faz przy błędach korelacji."),
    ]),
    EngineProfile("VAG_20_ALT", "Audi/VW 2.0 20V (ALT)", ["ALT", "2.0 20V"], [
      EngineFault({FaultArea.oil}, "Zużycie oleju",
          "Znane podwyższone zużycie oleju; kontrola poziomu i pierścieni."),
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewki zapłonowe",
          "Typowe wypadanie od cewek."),
    ]),
    // ================= POPULARNE BENZYNY TURBO =================
    EngineProfile("FIAT_TJET", "Fiat 1.4 T-Jet / MultiAir Turbo", ["T-JET", "TJET", "MULTIAIR", "1.4 TURBO 16V", "198A", "940A"], [
      EngineFault({FaultArea.turbo}, "Zawór upustowy i sterowanie doładowaniem",
          "Trwały pod gaz, ale membrana/sterowanie doładowania potrafi spadać ciśnienie."),
      EngineFault({FaultArea.timing}, "Moduł MultiAir (wersje MultiAir)",
          "Wczesny MultiAir: awarie modułu elektrohydraulicznego sterowania zaworami."),
    ]),
    EngineProfile("OPEL_14T", "Opel 1.4 Turbo Ecotec (A14NET/B14)", ["A14NET", "A14NEL", "B14NET", "1.4 TURBO"], [
      EngineFault({FaultArea.timing}, "Rozciągnięty łańcuch rozrządu",
          "Łańcuch i napinacz do kontroli — grzechot na zimno."),
      EngineFault({FaultArea.cooling}, "Termostat i przewody chłodzenia",
          "Wycieki i zawieszony termostat; kontrola temperatury."),
      EngineFault({FaultArea.intake, FaultArea.mixture}, "Zawór PCV odmy",
          "Membrana odmy w pokrywie zaworów — lewe powietrze, dławienie."),
    ]),
    EngineProfile("REN_TCE_09", "Renault 0.9/1.0 TCe (3 cyl.)", ["TCE 90", "0.9 TCE", "1.0 TCE", "H4B", "H4D"], [
      EngineFault({FaultArea.oil}, "Podwyższone zużycie oleju",
          "Małe turbo 3-cyl.: kontrola poziomu oleju."),
      EngineFault({FaultArea.turbo, FaultArea.ignition}, "Doładowanie i cewka",
          "Spadki doładowania od sterowania; nierówna praca od cewki."),
    ]),
    EngineProfile("VW_10_TSI", "VW 1.0 TSI (EA211, 3 cyl.)", ["1.0 TSI", "CHZ", "DKR", "DKL"], [
      EngineFault({FaultArea.turbo}, "Sterowanie doładowaniem",
          "Spadki doładowania zwykle od sterowania/uszczelnień, nie samej turbiny."),
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewki i świece",
          "Typowe wypadanie od zapłonu."),
    ]),
    EngineProfile("PSA_PURETECH", "PSA 1.0/1.2 PureTech (EB2)", ["PURETECH", "EB2", "1.2 PURETECH", "HN01", "HN05", "HNZ"], [
      EngineFault({FaultArea.timing, FaultArea.oil}, "Pasek rozrządu w kąpieli olejowej",
          "Sztandarowa wada: pasek w oleju łuszczy się, resztki zapychają smok oleju — spadek ciśnienia i zatarcie. Kontrola stanu paska i ciśnienia oleju, wymiana wg skróconego planu."),
      EngineFault({FaultArea.oil}, "Nadmierne zużycie oleju",
          "Podwyższone zużycie oleju — pilnuj poziomu."),
    ]),
    EngineProfile("BMW_B48", "BMW 2.0 Turbo (B48)", ["B48", "B46"], [
      EngineFault({FaultArea.oil}, "Wycieki oleju (uszczelka pokrywy/obudowa filtra)",
          "Nowoczesny i udany; głównie drobne wycieki oleju z czasem."),
      EngineFault({FaultArea.cooling}, "Pompa wody / termostat",
          "Elektryczna pompa wody i termostat do kontroli przy wahaniach temperatury."),
    ]),
    EngineProfile("BMW_N13_PRINCE", "BMW/Mini/PSA 1.4/1.6 THP (Prince/EP6)", ["N13", "N18", "EP6", "PRINCE", "THP", "5FV", "5G0"], [
      EngineFault({FaultArea.timing}, "Rozciągnięty łańcuch rozrządu",
          "Prince/EP6: łańcuch i prowadnice — grzechot na zimno, ryzyko przeskoku."),
      EngineFault({FaultArea.intake, FaultArea.mixture}, "Nagar na zaworach ssących (DI)",
          "Bezpośredni wtrysk: mocne zarastanie zaworów nagarem."),
      EngineFault({FaultArea.oil}, "Wysokie zużycie oleju",
          "Znany apetyt na olej — kontrola poziomu."),
    ]),
    EngineProfile("BMW_N63", "BMW 4.4 V8 Biturbo (N63)", ["N63"], [
      EngineFault({FaultArea.cooling, FaultArea.oil}, "Przegrzewanie układu Hot-V",
          "Turbiny w rozwidleniu V: przegrzewanie, rozciąganie łańcuchów, wysokie zużycie oleju."),
      EngineFault({FaultArea.injectors, FaultArea.misfire}, "Wtryskiwacze i cewki",
          "Awarie wtrysków i cewek — wypadanie zapłonu."),
    ]),
    EngineProfile("BMW_N45_N46", "BMW 1.6/2.0 (N45/N46)", ["N45", "N46", "N42"], [
      EngineFault({FaultArea.timing}, "Ślizgi/prowadnice łańcucha i Valvetronic",
          "Pękające ślizgi łańcucha oraz problemy z Valvetronic (silniczek, łożyskowanie)."),
    ]),
    EngineProfile("ALFA_TS", "Alfa Romeo 1.6/2.0 Twin Spark", ["TWIN SPARK", "TWINSPARK", "AR32", "AR671"], [
      EngineFault({FaultArea.oil}, "Wrażliwość na poziom oleju — panewki",
          "Skrajnie czuły na poziom/jakość oleju: niedobór szybko zaciera panewki. Pilnuj poziomu i wymian."),
      EngineFault({FaultArea.timing}, "Zmienne fazy (wariator) i rozrząd",
          "Wariator faz i pasek do kontroli."),
    ]),
    EngineProfile("OPEL_22_DIRECT", "Opel 2.2 Direct (Z22YH)", ["Z22YH", "2.2 DIRECT"], [
      EngineFault({FaultArea.railPressure, FaultArea.injectors}, "Pompa wysokiego ciśnienia",
          "Awaryjna pompa HP wtrysku bezpośredniego — spadki ciśnienia, trudny rozruch."),
      EngineFault({FaultArea.timing}, "Nietrwały układ rozrządu",
          "Łańcuch/prowadnice do kontroli."),
    ]),
    EngineProfile("HK_THETA_GDI", "Hyundai/Kia 2.0/2.4 GDI (Theta II)", ["THETA", "G4KD", "G4KE", "2.0 GDI", "2.4 GDI"], [
      EngineFault({FaultArea.oil, FaultArea.misfire}, "Obracanie panewek / zatarcie (wada wału)",
          "Opiłki z obróbki wału w kanałach oleju: obracające się panewki, stuki, nagłe zatarcie. Objęte akcjami serwisowymi."),
    ]),
    EngineProfile("HON_10VTEC", "Honda 1.0 VTEC Turbo", ["1.0 VTEC TURBO", "P10A"], [
      EngineFault({FaultArea.timing, FaultArea.oil}, "Pasek rozrządu w oleju",
          "Pasek pracujący w oleju łuszczy się i może zapchać smok — kontrola i wymiana wg planu."),
    ]),
    EngineProfile("SMART_TURBO", "Smart 0.6/0.7 Turbo (3 cyl.)", ["0.6 TURBO", "0.7 TURBO", "M160", "M160E6"], [
      EngineFault({FaultArea.mixture, FaultArea.cooling}, "Wypalanie zaworów i przegrzewanie",
          "Krótka żywotność: wypalanie zaworów, przegrzewanie."),
      EngineFault({FaultArea.turbo}, "Pękające turbosprężarki",
          "Małe turbo pod dużym obciążeniem — awarie."),
    ]),
    EngineProfile("MAZDA_WANKEL", "Mazda 1.3 Renesis (Wankel, RX-8)", ["RENESIS", "13B", "WANKEL", "RX-8", "RX8"], [
      EngineFault({FaultArea.mixture}, "Zużyte uszczelnienia wierzchołkowe rotorów",
          "Utrata kompresji rotorów już po ~100 tys. km: trudny gorący rozruch, spadek mocy."),
    ]),
    // ================= KLASYCZNE / R6 / V6 =================
    EngineProfile("BMW_M54_M52", "BMW R6 2.0-3.0 (M52/M54)", ["M54", "M52", "M52TU", "256S", "306S"], [
      EngineFault({FaultArea.cooling}, "Pompa wody i termostat",
          "Plastikowa pompa i termostat to typowe źródło przegrzania — kontrola temperatury."),
      EngineFault({FaultArea.timing}, "Grzechot VANOS",
          "Zużyte uszczelnienia VANOS: grzechot, spadek elastyczności."),
      EngineFault({FaultArea.intake, FaultArea.mixture}, "Odma (CCV) i klapa DISA",
          "Zamarzająca/nieszczelna odma i pękająca klapa DISA — lewe powietrze, nierówna praca."),
    ]),
    EngineProfile("AUDI_24_V6", "Audi 2.4/2.8 V6 30V", ["2.4 V6", "2.8 V6", "30V", "AML", "APS", "BDV", "ACK"], [
      EngineFault({FaultArea.timing}, "Napinacze łańcucha rozrządu",
          "Łańcuchy z przodu silnika i napinacze — grzechot, błędy korelacji."),
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewki zapłonowe",
          "Typowe wypadanie od cewek."),
    ]),
    EngineProfile("AUDI_18T", "Audi/VW 1.8T 20V", ["1.8T", "1.8 T", "AGU", "AEB", "APX", "AMK", "BAM", "AUM", "ARY"], [
      EngineFault({FaultArea.oil}, "Zaszlamienie kanałów oleju",
          "Znane zaszlamienie przy zaniedbanych wymianach — spadek smarowania, turbina."),
      EngineFault({FaultArea.turbo, FaultArea.intake}, "Zawór N75 i przecieki doładowania",
          "N75 i nieszczelności dolotu — wahania doładowania."),
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewki zapłonowe",
          "Częste wypadanie od cewek."),
    ]),
    EngineProfile("VOLVO_5T", "Volvo 2.0-2.5 Turbo R5 (benzyna)", ["B5254T", "B5244T", "2.5T", "2.4T"], [
      EngineFault({FaultArea.oil, FaultArea.intake}, "Zapchany separator oleju (odma)",
          "Zatkany separator/odma podnosi zużycie oleju i psuje bieg jałowy — czyszczenie/wymiana."),
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewki i przepustnica ETM",
          "Cewki oraz elektroniczna przepustnica ETM to typowe usterki."),
    ]),
    EngineProfile("REN_F4RT", "Renault 2.0 Turbo (F4RT)", ["F4RT", "2.0 TURBO"], [
      EngineFault({FaultArea.ignition, FaultArea.misfire}, "Cewki zapłonowe",
          "Mocny i trwały; nierówna praca zwykle od cewek."),
      EngineFault({FaultArea.turbo}, "Sterowanie doładowaniem",
          "Wahania doładowania od zaworu sterującego."),
    ]),
    EngineProfile("VAG_25_TDI_V6", "VW/Audi 2.5 TDI V6", ["2.5 TDI", "AKN", "AFB", "BDG", "BAU", "BDH", "AKE"], [
      EngineFault({FaultArea.timing}, "Wycieranie wałków rozrządu",
          "Przedwczesne zużycie wałków — spadek mocy, hałas."),
      EngineFault({FaultArea.injectors, FaultArea.railPressure}, "Pompa wtryskowa (VP44)",
          "Awarie pompy VP44 — wahania ciśnienia, trudny rozruch."),
    ]),
    EngineProfile("VAG_30_TDI", "Audi/VW 3.0 TDI V6", ["3.0 TDI", "ASB", "BMK", "CASA", "CDYA", "CDUC", "CLAB"], [
      EngineFault({FaultArea.intake, FaultArea.egr}, "Nagar w kolektorach i klapy zawirowujące",
          "Zarastanie kolektorów i klap dolotu; do tego chłodnica EGR."),
      EngineFault({FaultArea.timing}, "Łańcuch rozrządu (wczesne)",
          "Wczesne 3.0 TDI: łańcuch/koła do kontroli."),
      EngineFault({FaultArea.oil}, "Wyciek z chłodnicy oleju",
          "Znane wycieki spod chłodnicy oleju."),
    ]),
    EngineProfile("VW_12_TSI_HTP", "VW 1.2 HTP / 1.2 TSI (3 cyl.)", ["1.2 HTP", "AWY", "BME", "BBM", "CHFA", "CGPA", "1.2 TSI", "CBZ"], [
      EngineFault({FaultArea.timing}, "Przeskok łańcucha rozrządu",
          "Szybko rozciągający się łańcuch i napinacz — grzechot, ryzyko przeskoku."),
      EngineFault({FaultArea.mixture, FaultArea.cooling}, "Wypalanie zaworów i przegrzewanie (HTP)",
          "1.2 HTP: wypalanie zaworów, przegrzewanie — spadek kompresji."),
      EngineFault({FaultArea.oil}, "Zużycie oleju (1.2 TSI)",
          "Podwyższone zużycie oleju — kontrola poziomu."),
    ]),
    EngineProfile("VAG_FSI", "VW/Audi 1.4/1.6 FSI", ["1.4 FSI", "1.6 FSI", "BKG", "BLF", "BAG", "BLP", "BLN"], [
      EngineFault({FaultArea.intake, FaultArea.mixture}, "Nagar na zaworach ssących",
          "Wtrysk bezpośredni FSI: silne zarastanie zaworów nagarem — spadek mocy, nierówna praca."),
      EngineFault({FaultArea.timing}, "Łańcuch/osprzęt rozrządu",
          "Nietrwały osprzęt rozrządu do kontroli."),
    ]),
    // ================= DIESLE =================
    EngineProfile("VW_19_TDI", "VW/Audi 1.9 TDI", ["1.9 TDI", "AHF", "ALH", "AGR", "ASV", "AVF", "AWX", "ATD", "AXR", "BXE", "BLS", "1Z", "AHU", "AFN"], [
      EngineFault({FaultArea.turbo}, "Zapieczona geometria turbiny (VNT)",
          "Klasyk 1.9 TDI: nagar w geometrii — brak pełnego doładowania, tryb awaryjny. Zwykle do wyczyszczenia."),
      EngineFault({FaultArea.egr, FaultArea.intake}, "Zapchany EGR i kolektor",
          "Zarastanie EGR i kolektora sadzą — spadek mocy."),
      EngineFault({FaultArea.injectors}, "Zużyte pompowtryskiwacze (PD)",
          "Wersje PD: rosnąca korekta pojedynczego wtrysku, stukanie, dymienie."),
    ]),
    EngineProfile("VW_16_TDI", "VW/Audi 1.6 TDI (CAYC/CLHA)", ["1.6 TDI", "CAYC", "CAYB", "CLHA", "CXXB", "DGTE"], [
      EngineFault({FaultArea.injectors, FaultArea.railPressure}, "Wtryskiwacze i ciśnienie szyny",
          "Lejący wtrysk na jałowym: korekta cylindra; spadek ciśnienia pod obciążeniem: regulator/pompa."),
      EngineFault({FaultArea.dpf, FaultArea.egr}, "DPF i EGR",
          "Zapychanie DPF na krótkich trasach i zarastanie EGR."),
    ]),
    EngineProfile("FIAT_JTD_MJET", "Fiat 1.9 JTD / 1.9-2.0 MultiJet", ["1.9 JTD", "1.9 MULTIJET", "2.0 MULTIJET", "192A", "199B", "223A", "939A", "844A"], [
      EngineFault({FaultArea.turbo}, "Geometria turbiny i sterowanie",
          "Zapiekanie geometrii, sterowanie podciśnieniem — spadek doładowania."),
      EngineFault({FaultArea.injectors, FaultArea.railPressure}, "Wtryskiwacze i regulator ciśnienia",
          "Zużyte wtryski i regulator na pompie — wahania ciśnienia szyny."),
      EngineFault({FaultArea.egr}, "Zawór EGR",
          "Zarastanie EGR nagarem — nierówna praca, spadek mocy."),
    ]),
    EngineProfile("OPEL_20_CDTI", "Opel 2.0 CDTI (A20DT)", ["A20DT", "A20DTH", "2.0 CDTI"], [
      EngineFault({FaultArea.injectors, FaultArea.railPressure}, "Wtryskiwacze i ciśnienie szyny",
          "Zużycie wtrysków i wahania ciśnienia pod obciążeniem."),
      EngineFault({FaultArea.dpf, FaultArea.egr}, "DPF i EGR",
          "Zapychanie DPF i zarastanie EGR — spadek mocy, tryb awaryjny."),
    ]),
    EngineProfile("BMW_M47", "BMW 2.0d (M47)", ["M47", "204D4"], [
      EngineFault({FaultArea.intake}, "Klapy zawirowujące (swirl flaps)",
          "Urywające się klapki dolotu — ryzyko zassania do cylindra."),
      EngineFault({FaultArea.turbo}, "Geometria turbiny",
          "Zapiekanie geometrii przy jeździe miejskiej."),
      EngineFault({FaultArea.egr}, "EGR i nagar w kolektorze",
          "Zarastanie EGR i kolektora."),
    ]),
    EngineProfile("REN_20_DCI", "Renault/Nissan 2.0 dCi (M9R)", ["M9R", "2.0 DCI"], [
      EngineFault({FaultArea.injectors}, "Wtryskiwacze",
          "Zużyte wtryski — przelewy, nierówna praca; do tego dwumas."),
      EngineFault({FaultArea.turbo, FaultArea.egr}, "Turbo i EGR",
          "Sterowanie doładowaniem i zarastanie EGR."),
    ]),
    EngineProfile("REN_19_DCI", "Renault 1.9 dCi (F9Q)", ["F9Q", "1.9 DCI"], [
      EngineFault({FaultArea.turbo, FaultArea.oil}, "Głodzenie olejowe turbiny",
          "Wadliwe smarowanie potrafi zatrzeć turbinę i panewki — kontrola przewodu i ciśnienia oleju."),
      EngineFault({FaultArea.injectors}, "Wtryskiwacze (Delphi)",
          "Zużyte wtryski — przelewy."),
    ]),
    EngineProfile("REN_22_DCI", "Renault 2.2/2.5 dCi (G9T/G9U)", ["G9T", "G9U", "2.2 DCI", "2.5 DCI"], [
      EngineFault({FaultArea.injectors, FaultArea.railPressure}, "Wtryskiwacze i ciśnienie",
          "Zużycie wtrysków, wahania ciśnienia; problemy elektroniki sterującej."),
      EngineFault({FaultArea.cooling}, "Uszczelka pod głowicą",
          "Pękające uszczelki głowicy — ubytek płynu, przedmuchy."),
    ]),
    EngineProfile("HK_CRDI", "Hyundai/Kia 1.6/2.0 CRDi", ["CRDI", "D4FB", "D4EA", "D4HA", "U2", "1.6 CRDI", "2.0 CRDI"], [
      EngineFault({FaultArea.turbo}, "Geometria turbiny",
          "Zapiekanie geometrii — spadek doładowania."),
      EngineFault({FaultArea.injectors, FaultArea.egr}, "Wtryskiwacze i EGR",
          "Zużycie wtrysków i zarastanie EGR."),
      EngineFault({FaultArea.dpf}, "DPF na krótkich trasach",
          "Niedopalony filtr — kontrola różnicy ciśnień."),
    ]),
    EngineProfile("FORD_20_TDCI_MK3", "Ford 2.0 TDCi Duratorq (wczesne Mondeo Mk3)", ["2.0 TDCI", "DURATORQ", "N7BA", "FMBA", "HJBB"], [
      EngineFault({FaultArea.injectors, FaultArea.railPressure}, "Łuszcząca się pompa Delphi",
          "Opiłki z pompy Delphi niszczą wtryskiwacze i szynę — wahania ciśnienia, ścinki w układzie."),
      EngineFault({FaultArea.turbo}, "Geometria turbiny",
          "Zapiekanie geometrii — spadek doładowania."),
    ]),
    EngineProfile("VOLVO_D5", "Volvo 2.4 D5 (R5)", ["D5", "2.4 D5", "D5244"], [
      EngineFault({FaultArea.turbo}, "Geometria turbiny",
          "Zapiekanie geometrii — spadek doładowania na wyższych obrotach."),
      EngineFault({FaultArea.intake, FaultArea.egr}, "Klapy zawirowujące i EGR",
          "Urywane klapki dolotu i zarastanie EGR."),
      EngineFault({FaultArea.injectors}, "Wtryskiwacze (wczesne serie)",
          "Zużycie wtrysków w starszych wersjach."),
    ]),
    EngineProfile("SUBARU_EE20", "Subaru 2.0 D (EE20)", ["EE20"], [
      EngineFault({FaultArea.oil, FaultArea.cooling}, "Pękające wały i zatarcia panewek",
          "Pierwszy diesel Subaru: pękający wał korbowy, zatarcia panewek — pilnuj oleju i unikaj przeciążeń na zimno."),
    ]),
    EngineProfile("SUBARU_EJ25T", "Subaru 2.5 Turbo (EJ25)", ["EJ25", "EJ255", "EJ257"], [
      EngineFault({FaultArea.cooling}, "Wypalanie uszczelki głowicy i przegrzewanie",
          "Boxer EJ25: przegrzewanie i wypalanie uszczelek głowicy (UPG)."),
      EngineFault({FaultArea.misfire, FaultArea.oil}, "Pękające tłoki (ringland)",
          "Pod obciążeniem/stukiem pękają mostki tłoków — wypadanie, dym."),
    ]),
    EngineProfile("MB_M271", "Mercedes 1.8 Kompressor/CGI (M271)", ["M271"], [
      EngineFault({FaultArea.timing}, "Przeskok łańcucha rozrządu",
          "Łańcuch potrafi przeskoczyć bez ostrzeżenia i zniszczyć koła zębate — kontrola przy grzechocie."),
    ]),
    EngineProfile("MB_M272_M273", "Mercedes V6/V8 (M272/M273)", ["M272", "M273"], [
      EngineFault({FaultArea.timing}, "Ścieranie zębatki wałka wyrównoważającego",
          "Zużyta zębatka wałka pośredniego — błędy korelacji, kosztowna naprawa."),
    ]),
    EngineProfile("MAZDA_MZRCD", "Mazda 2.0/2.2 MZR-CD (diesel)", ["MZR-CD", "MZR CD", "R2AA", "RF7J", "2.2 MZR"], [
      EngineFault({FaultArea.injectors, FaultArea.oil}, "Podkładki wtrysków i rozcieńczenie oleju",
          "Nieszczelne podkładki wtrysków, nagar i rozcieńczony olej zapychają smok — ryzyko zatarcia. Kontrola poziomu i podkładek."),
      EngineFault({FaultArea.turbo}, "Geometria turbiny",
          "Zapiekanie geometrii — spadek doładowania."),
    ]),
    EngineProfile("ISUZU_30_DTI", "Isuzu 3.0 DTI V6 (Opel/Saab/Renault)", ["3.0 DTI", "6DE1", "3.0 CDTI", "Y30DT"], [
      EngineFault({FaultArea.cooling}, "Opadające tuleje i przegrzewanie",
          "Opadające tuleje cylindrowe i przegrzewanie — utrata kompresji, przedmuchy."),
    ]),
  ];
}
