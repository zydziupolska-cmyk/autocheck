import 'dart:convert';
import 'extended_pid.dart';

class DtcCode {
  final String code; // np. "P0087"
  final String title; // np. "Za niskie ciśnienie paliwa w układzie / na listwie wtryskowej"
  final String category; // np. "Układ paliwowy i zasilania"
  final String description; // Szczegółowy opis techniczny
  final List<String> commonCauses; // Typowe przyczyny (np. w silnikach TSI)
  final List<String> diagnosticsSteps; // Kroki sprawdzenia

  /// Sterownik, który zgłosił kod (np. "Silnik (7E8)"), null gdy nieznany.
  final String? ecuLabel;

  /// Kod oczekujący (Mode 07) — wykryty w bieżącym cyklu jazdy, jeszcze niepotwierdzony.
  final bool pending;

  const DtcCode({
    required this.code,
    required this.title,
    required this.category,
    required this.description,
    required this.commonCauses,
    required this.diagnosticsSteps,
    this.ecuLabel,
    this.pending = false,
  });

  DtcCode withSource({String? ecuLabel, bool pending = false}) => DtcCode(
        code: code,
        title: title,
        category: category,
        description: description,
        commonCauses: commonCauses,
        diagnosticsSteps: diagnosticsSteps,
        ecuLabel: ecuLabel,
        pending: pending,
      );

  /// Obszar układu na podstawie litery i pierwszych cyfr kodu (SAE J2012).
  static String systemAreaFor(String code) {
    if (code.length < 5) return "Ogólna diagnostyka ECU";
    final letter = code[0];
    final generic = code[1] == '0' || code[1] == '2';
    switch (letter) {
      case 'P':
        const areas = {
          '0': "Pomiar paliwa i powietrza / układ emisji",
          '1': "Pomiar paliwa i powietrza",
          '2': "Wtryskiwacze / układ wtryskowy",
          '3': "Układ zapłonowy / wypadanie zapłonów",
          '4': "Dodatkowa kontrola emisji (EGR, EVAP, katalizator, DPF)",
          '5': "Prędkość pojazdu / bieg jałowy / wejścia",
          '6': "Komputer sterujący / wyjścia",
          '7': "Skrzynia biegów",
          '8': "Skrzynia biegów",
          'A': "Napęd hybrydowy",
        };
        return "${areas[code[2]] ?? 'Układ napędowy'}${generic ? '' : ' (kod producenta)'}";
      case 'C':
        return "Podwozie (ABS, ESP, zawieszenie, układ kierowniczy)${generic ? '' : ' (kod producenta)'}";
      case 'B':
        return "Nadwozie (poduszki, klimatyzacja, komfort)${generic ? '' : ' (kod producenta)'}";
      case 'U':
        return "Komunikacja między sterownikami (CAN)${generic ? '' : ' (kod producenta)'}";
      default:
        return "Ogólna diagnostyka ECU";
    }
  }

  /// Wbudowana baza popularnych kodów błędów (ze szczególnym uwzględnieniem grupy VAG / TSI)
  static final Map<String, DtcCode> database = {
    "P0087": const DtcCode(
      code: "P0087",
      title: "Ciśnienie paliwa na szynie / w układzie wtryskowym - za niskie (Fuel Rail Pressure Too Low)",
      category: "Układ wtryskowy wysokiego ciśnienia (TSI / FSI)",
      description: "Sterownik ECU zarejestrował spadek ciśnienia na listwie wysokiego ciśnienia (HPFP) poniżej wartości zadanej – szczególnie zauważalne na biegu jałowym lub pod obciążeniem.",
      commonCauses: [
        "Nieszczelny, lejący wtryskiwacz bezpośredni – paliwo ucieka z listwy do komory spalania, powodując spadek ciśnienia na jałowych obrotach i zalewanie cylindra (zwykle towarzyszy mu wypadanie zapłonu tego cylindra, P030x)",
        "Zużyta lub zacierająca się mechaniczna pompa wysokiego ciśnienia (HPFP) napędzana z wałka rozrządu",
        "Wytarta szklanka popychacza pompy wysokiego ciśnienia na wałku rozrządu",
        "Uszkodzony zawór regulacyjny ciśnienia paliwa (N276 na pompie HPFP)",
        "Spadek ciśnienia wstępnego z pompy w baku (LPFP) lub zapchany filtr paliwa",
        "Uszkodzony czujnik ciśnienia na listwie paliwowej (G247)",
      ],
      diagnosticsSteps: [
        "Nagraj log wolnych obrotów i przyspieszenia: spadek ciśnienia tylko na jałowym przy ujemnych korektach paliwa wskazuje na lejący wtryskiwacz, spadek pod obciążeniem — na zasilanie (filtr, pompy).",
        "Sprawdź korekty poszczególnych cylindrów w diagnostyce producenta i liczniki wypadania zapłonów — cylinder z lejącym wtryskiem wyraźnie odstaje.",
        "Wykręć świecę podejrzanego cylindra po postoju – jeśli czuć intensywny zapach benzyny lub świeca jest mokra, jego wtryskiwacz nie trzyma ciśnienia.",
        "Wykonaj próbę szczelności listwy paliwa: po zgaszeniu rozgrzanego silnika ciśnienie na listwie powinno powoli rosnąć od temperatury (do 60-100 bar), a nie gwałtownie spadać do zera.",
        "Skontroluj poziom oleju silnikowego – czy nie przybywa oleju i czy nie czuć w nim benzyny (lejący wtryskiwacz spłukuje film olejowy do miski).",
        "Zdejmij pompę wysokiego ciśnienia i skontroluj popychacz (szklankę) pod kątem przetarcia.",
      ],
    ),
    "P0301": const DtcCode(
      code: "P0301",
      title: "Wypadanie zapłonów na cylindrze 1 (Cylinder 1 Misfire Detected)",
      category: "Układ zapłonowy i cylindry",
      description: "Czujnik położenia wału korbowego wykrył brak przyspieszenia kątowego wału podczas suwu pracy na 1. cylindrze.",
      commonCauses: [
        "Lejący lub niedolewający wtryskiwacz paliwa na cylindrze 1",
        "Zalana lub zużyta świeca zapłonowa na cylindrze 1",
        "Uszkodzona cewka zapłonowa na cylindrze 1",
        "Zanieczyszczenie nagarem zaworów ssących (typowe w silnikach TSI z bezpośrednim wtryskiem)",
        "Spadek kompresji na cylindrze 1",
      ],
      diagnosticsSteps: [
        "Zamień cewkę zapłonową między cylindrem 1 a 2 – zobacz, czy błąd przejdzie na cylinder 2.",
        "Wykręć świecę zapłonową #1 i oceń kolor nagaru (czarna/mokra = lejący wtryskiwacz, biała = brak paliwa).",
        "Zmierz kompresję na zimnym i ciepłym silniku.",
      ],
    ),
    for (int cyl = 2; cyl <= 4; cyl++)
      "P030$cyl": DtcCode(
        code: "P030$cyl",
        title: "Wypadanie zapłonów na cylindrze $cyl (Cylinder $cyl Misfire Detected)",
        category: "Układ zapłonowy i cylindry",
        description: "Czujnik położenia wału korbowego wykrył nierówną pracę cylindra $cyl — mieszanka w tym cylindrze nie spala się prawidłowo.",
        commonCauses: [
          "Uszkodzona cewka zapłonowa lub świeca cylindra $cyl",
          "Lejący lub niedolewający wtryskiwacz cylindra $cyl",
          "Nieszczelność dolotu przy cylindrze $cyl",
          "Spadek kompresji na cylindrze $cyl",
        ],
        diagnosticsSteps: [
          "Zamień cewkę cylindra $cyl z sąsiednią — jeśli błąd przejdzie na inny cylinder, winna jest cewka.",
          "Wykręć świecę cylindra $cyl: mokra i czarna = nadmiar paliwa (wtryskiwacz), sucha = brak iskry lub paliwa.",
          "Zmierz kompresję.",
        ],
      ),
    "P0234": const DtcCode(
      code: "P0234",
      title: "Przeładowanie turbosprężarki (Turbocharger Overboost Condition)",
      category: "Układ doładowania",
      description: "Rzeczywiste ciśnienie doładowania przekroczyło zadane — sterownik zwykle przechodzi w tryb awaryjny.",
      commonCauses: [
        "Zapieczone nagarem kierownice turbiny VGT (zamknięte)",
        "Usterka siłownika turbiny lub zaworu sterującego (N75)",
        "Wastegate nie otwiera się (benzyna)",
      ],
      diagnosticsSteps: [
        "Nagraj przyspieszenie z doładowaniem zadanym i rzeczywistym — przeładowanie na niskich obrotach i brak doładowania na wysokich to typowy objaw zapieczonych kierownic.",
        "Sprawdź ruch siłownika turbiny w pełnym zakresie.",
      ],
    ),
    "P2002": const DtcCode(
      code: "P2002",
      title: "Sprawność filtra cząstek stałych poniżej progu (DPF Efficiency Below Threshold)",
      category: "Układ oczyszczania spalin (DPF)",
      description: "Sterownik ocenia, że filtr DPF nie działa prawidłowo — zbyt duży lub zbyt mały opór przepływu spalin.",
      commonCauses: [
        "Filtr zapchany sadzą lub popiołem",
        "Uszkodzony (pęknięty) lub usunięty wkład filtra",
        "Uszkodzone przewody czujnika różnicy ciśnień",
      ],
      diagnosticsSteps: [
        "Nagraj jazdę z różnicą ciśnień DPF i przepływem powietrza — Diagnoza oceni opór filtra względem przepływu.",
        "Sprawdź przewody czujnika różnicy ciśnień.",
      ],
    ),
    "P0093": const DtcCode(
      code: "P0093",
      title: "Wykryto duży wyciek paliwa w układzie wysokiego ciśnienia (Fuel System Large Leak Detected)",
      category: "Układ wtryskowy (Common Rail)",
      description: "Sterownik wykrył, że ciśnienie na szynie spada szybciej, niż wynika z dawki wtrysku.",
      commonCauses: [
        "Za duże przelewy wtryskiwaczy",
        "Nieszczelny przewód lub złącze wysokiego ciśnienia",
        "Nieszczelny zawór regulacji ciśnienia",
      ],
      diagnosticsSteps: [
        "Obejrzyj przewody wysokiego ciśnienia pod kątem wycieku (zapach oleju napędowego!).",
        "Wykonaj test przelewów wtryskiwaczy.",
      ],
    ),
    "P2563": const DtcCode(
      code: "P2563",
      title: "Czujnik położenia sterowania turbiną — zakres/działanie (Turbocharger Boost Control Position Sensor Range/Performance)",
      category: "Układ doładowania",
      description: "Położenie mechanizmu turbiny (VGT) nie zgadza się z oczekiwanym.",
      commonCauses: [
        "Zapieczone kierownice VGT",
        "Uszkodzony elektroniczny siłownik turbiny lub jego czujnik",
      ],
      diagnosticsSteps: [
        "Wykonaj test siłownika w diagnostyce producenta.",
        "Nagraj przyspieszenie z pozycją VGT zadaną i rzeczywistą (jeśli auto ją udostępnia).",
      ],
    ),
    "P0172": const DtcCode(
      code: "P0172",
      title: "Mieszanka zbyt bogata - Bank 1 (System Too Rich)",
      category: "Dawkowanie paliwa i korekty STFT/LTFT",
      description: "Sonda lambda rejestruje zbyt dużą ilość paliwa względem powietrza. Korekty paliwowe osiągnęły ujemny limit (-20% do -25%).",
      commonCauses: [
        "Lejący wtryskiwacz bezpośredni (np. cylinder 1)",
        "Przedostawanie się benzyny do oleju przez pompę HPFP lub nieszczelny wtrysk (odma zaciąga opary paliwa do dolotu)",
        "Uszkodzony lub stale otwarty elektrozawór pochłaniacza par paliwa EVAP",
        "Zabrudzony przepływomierz powietrza MAF / czujnik ciśnienia MAP",
      ],
      diagnosticsSteps: [
        "Sprawdź korekty krótko- i długoterminowe (STFT/LTFT).",
        "Odłącz odmę i sprawdź, czy korekty wrócą do zera (wyeliminuje opary paliwa z oleju).",
      ],
    ),
    "P0299": const DtcCode(
      code: "P0299",
      title: "Niedoładowanie turbosprężarki (Turbocharger Underboost)",
      category: "Układ doładowania",
      description: "Rzeczywiste ciśnienie doładowania jest niższe od ciśnienia wymaganego przez sterownik silnika.",
      commonCauses: [
        "Nieszczelność w układzie dolotowym (pęknięty wąż, intercooler)",
        "Zacięty lub uszkodzony zawór upustowy DV",
        "Luz na klapce wastegate w muszli wydechowej turbiny",
        "Nieszczelny wężyk podciśnienia do gruszki turbiny",
      ],
      diagnosticsSteps: [
        "Wykonaj próbę szczelności dolotu dymem.",
        "Sprawdź luz cięgna zaworu wastegate turbosprężarki.",
      ],
    ),
    "P0443": const DtcCode(
      code: "P0443",
      title: "Obwód zaworu oczyszczania pochłaniacza par paliwa (EVAP Purge Valve)",
      category: "Układ odpowietrzania zbiornika paliwa (EVAP)",
      description: "Elektrozawór EVAP odpowietrzający opary z baku zacina się lub ma przerwę w obwodzie. Powoduje niekontrolowane zasysanie par benzyny na wolnych obrotach, falowanie i drżenie silnika.",
      commonCauses: [
        "Mechanicznie zawieszony w pozycji otwartej zawór EVAP pod maską",
        "Uszkodzenie cewki elektrozaworu EVAP lub przetarta wiązka",
        "Przepełniony kanister węgla aktywnego w nadkolu",
      ],
      diagnosticsSteps: [
        "Zdejmij wężyk od zaworu EVAP idący do kolektora ssącego i zaślep go na próbę – jeśli falowanie na wolnych obrotach ustanie, zawór EVAP puszcza pary bez kontroli!",
        "Sprawdź oporność elektrozaworu miernikiem (powinna wynosić ok. 20-30 Ohm).",
      ],
    ),
    "P0106": const DtcCode(
      code: "P0106",
      title: "Czujnik ciśnienia w kolektorze MAP - sygnał poza zakresem (Manifold Absolute Pressure)",
      category: "Układ dolotowy i podciśnienie",
      description: "Wartość podciśnienia mierzona przez czujnik MAP nie odpowiada obrotom i pozycji przepustnicy. W silnikach 2.0 16V (EW10) bez przepływomierza powoduje to gwałtowne telepanie i gaśnięcie silnika.",
      commonCauses: [
        "Zaolejony lub zabrudzony nagarem czujnik MAP w kolektorze ssącym",
        "Nieszczelność kolektora dolotowego (sparciałe uszczelki oring pod kolektorem)",
        "Nieszczelny przewód serwa hamulcowego lub odmy olejowej",
      ],
      diagnosticsSteps: [
        "Wyjmij czujnik MAP z kolektora i umyj go zmywaczem do hamulców/elektroniki.",
        "Sprawdź podciśnienie na biegu jałowym – powinno wynosić 320-380 mbar.",
      ],
    ),
    "P0011": const DtcCode(
      code: "P0011",
      title: "Zmienne fazy rozrządu VVT - wałek ssący zbyt przyspieszony (Camshaft Position Timing Over-Advanced)",
      category: "Układ zmiennych faz rozrządu (VVT)",
      description: "Koło zmiennych faz rozrządu lub elektrozawór zaciął się w pozycji maksymalnego wyprzedzenia na wolnych obrotach, co powoduje silne falowanie, drżenie silnika i brak mocy do momentu 'przepalenia'.",
      commonCauses: [
        "Zacięty elektrozawór sterujący VVT z powodu zanieczyszczonego oleju",
        "Niskie ciśnienie oleju na rozgrzanym silniku na biegu jałowym",
        "Zużyte koło zmiennych faz rozrządu (wariator)",
      ],
      diagnosticsSteps: [
        "Wyjmij elektrozawór VVT i wyczyść jego sitko z opiłków i nagaru.",
        "Sprawdź poziom i stan oleju (zalecany świeży syntetyk 5W40).",
      ],
    ),
    "P0012": const DtcCode(
      code: "P0012",
      title: "Zmienne fazy rozrządu VVT - wałek ssący zbyt opóźniony (Camshaft Position Timing Over-Retarded)",
      category: "Układ zmiennych faz rozrządu (VVT)",
      description: "Wałek rozrządu nie osiąga zadanego wyprzedzenia kątowego lub wolno reaguje na polecenia ECU.",
      commonCauses: [
        "Zablokowany przepływ oleju do wariatora VVT (zanieczyszczone sitko elektrozaworu)",
        "Zbyt niskie ciśnienie w magistrali olejowej głowicy",
        "Mechaniczne zatarcie nastawnika faz rozrządu",
      ],
      diagnosticsSteps: [
        "Sprawdź działanie elektrozaworu VVT.",
        "Wykonaj płukanie układu olejowego i wymianę oleju wraz z filtrem.",
      ],
    ),
    "P0300": const DtcCode(
      code: "P0300",
      title: "Losowe / wielokrotne wypadanie zapłonów (Random/Multiple Cylinder Misfire)",
      category: "Układ zapłonowy",
      description: "Sterownik ECU rejestruje wypadanie zapłonów na różnych cylindrach. W silnikach Peugeot 2.0 (EW10) jest to typowy objaw uszkodzenia zintegrowanej listwy cewek zapłonowych.",
      commonCauses: [
        "Mikropęknięcia i przebicie iskry w zintegrowanej kasecie cewek zapłonowych (Sagem/Valeo)",
        "Zużyte świece zapłonowe ze zbyt dużą przerwą",
        "Podwieszające się popychacze hydrauliczne zaworów na wolnych obrotach",
      ],
      diagnosticsSteps: [
        "Wymień świece zapłonowe na nowe (np. NGK/Bosch).",
        "Obejrzyj fajki listwy cewek – jeśli są białe ślady przebicia lub pęknięcia gumy, cewka jest do wymiany.",
      ],
    ),
    "P0171": const DtcCode(
      code: "P0171",
      title: "Mieszanka zbyt uboga - Bank 1 (System Too Lean)",
      category: "Układ paliwowo-powietrzny",
      description: "Sterownik ECU dodał maksymalną dopuszczalną ilość paliwa (+25%), lecz sonda nadal widzi nadmiar tlenu. Uwaga: W 90% przypadków sonda lambda jest w 100% SPRAWNA, a przyczyną jest lewe powietrze!",
      commonCauses: [
        "Nieszczelność dolotu za przepływomierzem (fałszywe powietrze przez pęknięty przewód odmy, sparciałą uszczelkę kolektora)",
        "Nieszczelność wężyka podciśnienia do serwa hamulcowego",
        "Zabrudzony drucik przepływomierza MAF zaniżający odczyt masy powietrza",
        "Niskie ciśnienie paliwa (zapchany filtr paliwa lub zużyta pompa)",
      ],
      diagnosticsSteps: [
        "Nie wymieniaj sondy lambda w ciemno!",
        "Wykonaj próbę dymową dolotu, aby zlokalizować miejsce zasysania lewego powietrza.",
        "Przemyj drucik przepływomierza MAF dedykowanym preparatem.",
      ],
    ),
    "P0101": const DtcCode(
      code: "P0101",
      title: "Przepływomierz MAF - sygnał poza zakresem (Mass Air Flow Circuit Range/Performance)",
      category: "Układ dolotowy",
      description: "Ilość zmierzonego powietrza nie zgadza się z obrotami silnika i ciśnieniem w kolektorze. Uwaga: Zwykle to NIE jest uszkodzony przepływomierz, lecz dziura w dolocie za turbiną lub zacięty EGR!",
      commonCauses: [
        "Pęknięta rura dolotowa intercoolera (powietrze ucieka za przepływomierzem)",
        "Zacięty w pozycji otwartej zawór EGR (spaliny fałszują bilans powietrza)",
        "Zanieczyszczenie sensora MAF olejem z odmy lub kurzem",
      ],
      diagnosticsSteps: [
        "Sprawdź szczelność rur ciśnieniowych i intercoolera testem dymowym lub ciśnieniowym.",
        "Zweryfikuj pozycję zaworu EGR.",
      ],
    ),
    "P2463": const DtcCode(
      code: "P2463",
      title: "Filtr cząstek stałych (DPF) - nadmierne nagromadzenie sadzy (Soot Accumulation)",
      category: "Układ oczyszczania spalin (DPF / GPF)",
      description: "Ilość nagromadzonej sadzy w filtrze przekroczyła próg regeneracji pasywnej. Wysokie przeciwciśnienie spalin bezpośrednio blokuje obrót wirnika turbiny, powodując brak doładowania i mocny spadek dynamiki!",
      commonCauses: [
        "Częsta jazda na krótkich dystansach miejskich uniemożliwiająca wypalenie filtra",
        "Uszkodzony termostat (silnik nie osiąga temperatury 85°C wymaganej do procedury DPF)",
        "Uszkodzony czujnik różnicy ciśnień DPF lub przetarte wężyki silikonowe",
        "Lejące wtryskiwacze generujące nadmierną ilość sadzy",
      ],
      diagnosticsSteps: [
        "Sprawdź różnicę ciśnień DPF na wolnych obrotach (powinna być < 5-10 mbar, pod pełnym butem < 150-200 mbar).",
        "Sprawdź temperaturę płynu chłodzącego ECT – silnik musi mieć min. 80-85°C do wypalania.",
        "Wykonaj regenerację wymuszoną w trasie lub procedurę serwisową.",
      ],
    ),
    "P2452": const DtcCode(
      code: "P2452",
      title: "Czujnik różnicy ciśnień filtra cząstek stałych DPF - usterka obwodu (DPF Pressure Sensor Circuit)",
      category: "Układ oczyszczania spalin",
      description: "Sygnał z czujnika ciśnienia różnicowego spalin jest nielogiczny lub ma przerwę w obwodzie.",
      commonCauses: [
        "Przetarte, stopione lub zapchane sadzą gumowe wężyki łączące czujnik z wydechem",
        "Wewnętrzne uszkodzenie piezoelektrycznego czujnika ciśnienia",
        "Zaśniedziała wtyczka lub uszkodzona wiązka elektryczna",
      ],
      diagnosticsSteps: [
        "Obejrzyj metalowo-gumowe rurki idące od wydechu do czujnika pod kątem pęknięć i przetarć.",
        "Przedmuchaj rurki sprężonym powietrzem (w stronę wydechu, NIGDY w stronę czujnika!).",
      ],
    ),
    "P0401": const DtcCode(
      code: "P0401",
      title: "Układ recyrkulacji spalin EGR - wykryto zbyt mały przepływ (EGR Flow Insufficient)",
      category: "Układ recyrkulacji spalin EGR",
      description: "Przepływomierz MAF nie zanotował wymaganego spadku czystego powietrza po otwarciu zaworu EGR.",
      commonCauses: [
        "Kanały spalinowe w kolektorze ssącym lub chłodnicy EGR zarośnięte nagarem",
        "Zacięty mechanicznie zawór EGR lub uszkodzony silniczek krokowy",
        "Nieszczelność podciśnienia sterującego zaworem",
      ],
      diagnosticsSteps: [
        "Zdemontuj zawór EGR i rurkę doprowadzającą – usuń nagar.",
        "Sprawdź płynność ruchu grzybka zaworu.",
      ],
    ),

    // === Rozszerzona baza najczęstszych kodów (opisy własne, wiedza ogólna) ===
    "P0088": const DtcCode(
      code: "P0088",
      title: "Za wysokie ciśnienie paliwa na szynie (Fuel Rail Pressure Too High)",
      category: "Układ wtryskowy wysokiego ciśnienia",
      description: "Ciśnienie na listwie paliwowej przekroczyło wartość zadaną — regulacja ciśnienia nie utrzymuje zadanego poziomu.",
      commonCauses: [
        "Zacięty lub uszkodzony zawór regulacji ciśnienia (regulator na pompie lub na szynie)",
        "Zablokowany spływ paliwa / zawór nadmiarowy",
        "Błędny sygnał z czujnika ciśnienia szyny (zawyżony)",
        "Uszkodzone okablowanie zaworu regulacji",
      ],
      diagnosticsSteps: [
        "Porównaj ciśnienie zadane i rzeczywiste w danych bieżących pod obciążeniem.",
        "Sprawdź sterowanie zaworem regulacji (wypełnienie) i jego reakcję.",
        "Skontroluj okablowanie i wtyczki zaworu oraz czujnika ciśnienia.",
      ],
    ),
    "P0102": const DtcCode(
      code: "P0102",
      title: "Za niski sygnał przepływomierza powietrza (MAF Circuit Low)",
      category: "Pomiar powietrza dolotowego",
      description: "Sygnał z przepływomierza masowego powietrza jest niższy niż oczekiwany dla danych warunków pracy.",
      commonCauses: [
        "Zabrudzony element pomiarowy przepływomierza",
        "Nieszczelność dolotu za przepływomierzem (fałszywe powietrze)",
        "Zapchany filtr powietrza",
        "Uszkodzony przepływomierz lub jego okablowanie",
      ],
      diagnosticsSteps: [
        "Porównaj odczyt MAF (g/s) z wartością wzorcową dla obrotów jałowych i pełnego gazu.",
        "Sprawdź szczelność całego układu dolotowego i stan filtra powietrza.",
        "W razie potrzeby porównaj z nowym/sprawnym przepływomierzem.",
      ],
    ),
    "P0113": const DtcCode(
      code: "P0113",
      title: "Za wysoki sygnał czujnika temperatury powietrza dolotowego (IAT Circuit High)",
      category: "Pomiar powietrza dolotowego",
      description: "Sygnał czujnika temperatury powietrza wskazuje wartość odpowiadającą bardzo niskiej temperaturze / przerwie w obwodzie.",
      commonCauses: [
        "Przerwa w obwodzie lub skorodowana wtyczka czujnika IAT",
        "Uszkodzony czujnik (często zintegrowany z przepływomierzem)",
        "Uszkodzone okablowanie",
      ],
      diagnosticsSteps: [
        "Porównaj odczyt IAT z temperaturą otoczenia na zimnym silniku.",
        "Sprawdź ciągłość przewodów i stan wtyczki czujnika.",
      ],
    ),
    "P0128": const DtcCode(
      code: "P0128",
      title: "Temperatura płynu poniżej progu regulacji termostatu (Coolant Thermostat)",
      category: "Układ chłodzenia",
      description: "Silnik nie osiąga w wymaganym czasie temperatury roboczej — termostat prawdopodobnie nie domyka się poprawnie.",
      commonCauses: [
        "Zawieszony w pozycji otwartej termostat",
        "Uszkodzony czujnik temperatury płynu",
        "Zbyt niski poziom płynu lub problem z obiegiem",
      ],
      diagnosticsSteps: [
        "Obserwuj wzrost temperatury płynu po rozruchu — czy dochodzi do ~90°C w rozsądnym czasie.",
        "Dotykowo sprawdź, kiedy otwiera się obieg górny (chłodnica).",
        "Zweryfikuj wskazania czujnika temperatury z rzeczywistością.",
      ],
    ),
    "P0133": const DtcCode(
      code: "P0133",
      title: "Wolna reakcja sondy lambda 1 (O2 Sensor Slow Response B1S1)",
      category: "Układ paliwowy / sondy lambda",
      description: "Sonda lambda przed katalizatorem reaguje zbyt wolno na zmiany składu mieszanki — traci sprawność.",
      commonCauses: [
        "Zestarzona / zanieczyszczona sonda lambda przed katalizatorem",
        "Nieszczelność układu wydechowego przed sondą (zasysanie powietrza)",
        "Zanieczyszczenie sondy (olej, płyn, dodatki paliwowe)",
      ],
      diagnosticsSteps: [
        "Oceń przebieg napięcia/lambdy sondy przedniej — powinien szybko oscylować.",
        "Sprawdź szczelność wydechu przed sondą.",
        "Porównaj sondę przednią z tylną w danych bieżących.",
      ],
    ),
    "P0340": const DtcCode(
      code: "P0340",
      title: "Obwód czujnika położenia wałka rozrządu (Camshaft Position Sensor Circuit)",
      category: "Czujniki / synchronizacja",
      description: "Sterownik utracił lub odczytał nieprawidłowy sygnał czujnika położenia wałka rozrządu.",
      commonCauses: [
        "Uszkodzony czujnik położenia wałka",
        "Uszkodzone okablowanie lub wtyczka",
        "Zanieczyszczony/uszkodzony wieniec (koło impulsowe)",
        "Zakłócenia od źle poprowadzonych przewodów",
      ],
      diagnosticsSteps: [
        "Sprawdź sygnał czujnika przy rozruchu i pracy.",
        "Skontroluj wtyczkę i przewody czujnika.",
      ],
    ),
    "P0380": const DtcCode(
      code: "P0380",
      title: "Obwód świec żarowych (Glow Plug Circuit A)",
      category: "Układ rozruchu (diesel)",
      description: "Wykryto usterkę w obwodzie sterowania świec żarowych — częsty powód utrudnionego rozruchu na zimno i kontrolki żarzenia.",
      commonCauses: [
        "Przepalona jedna lub kilka świec żarowych",
        "Uszkodzony moduł sterujący świecami (przekaźnik/sterownik żarzenia)",
        "Uszkodzone okablowanie / korozja na szynie zasilającej świece",
      ],
      diagnosticsSteps: [
        "Zmierz rezystancję poszczególnych świec żarowych.",
        "Sprawdź napięcie zasilania na świecach podczas żarzenia.",
        "Odczytaj, które świece moduł zgłasza jako uszkodzone (dane bieżące).",
      ],
    ),
    "P0402": const DtcCode(
      code: "P0402",
      title: "Nadmierny przepływ recyrkulacji spalin (EGR Flow Excessive)",
      category: "Układ recyrkulacji spalin EGR",
      description: "Zawór EGR przepuszcza więcej spalin niż wynika z zadania — często zacięty w pozycji otwartej.",
      commonCauses: [
        "Zawór EGR zacięty w pozycji otwartej (nagar)",
        "Uszkodzony element wykonawczy / silniczek zaworu",
        "Błędny sygnał czujnika położenia zaworu",
      ],
      diagnosticsSteps: [
        "Sprawdź położenie zadane vs rzeczywiste zaworu EGR w danych bieżących.",
        "Zdemontuj i oczyść zawór, oceń swobodę ruchu grzybka.",
      ],
    ),
    "P0420": const DtcCode(
      code: "P0420",
      title: "Niska sprawność katalizatora (Catalyst Efficiency Below Threshold B1)",
      category: "Układ oczyszczania spalin",
      description: "Porównanie sond lambda przed i za katalizatorem wskazuje, że katalizator nie magazynuje tlenu tak jak powinien — spadek sprawności.",
      commonCauses: [
        "Zużyty / uszkodzony katalizator (przegrzany, zatkany, wypłukany)",
        "Nieszczelność wydechu w pobliżu sond",
        "Zestarzona tylna sonda lambda",
        "Długotrwała praca na bogatej/ubogiej mieszance lub spalanie oleju",
      ],
      diagnosticsSteps: [
        "Porównaj przebiegi sondy przedniej i tylnej — tylna nie powinna kopiować przedniej.",
        "Sprawdź szczelność wydechu przy sondach.",
        "Wyklucz przyczyny mieszanki (korekty, wypadanie) przed wymianą katalizatora.",
      ],
    ),
    "P0455": const DtcCode(
      code: "P0455",
      title: "Duża nieszczelność układu odprowadzania par paliwa (EVAP Large Leak)",
      category: "Układ EVAP (benzyna)",
      description: "System wykrył dużą nieszczelność w układzie odprowadzania par paliwa — najczęściej po stronie korka wlewu lub węży.",
      commonCauses: [
        "Niedokręcony lub nieszczelny korek wlewu paliwa",
        "Pęknięty / odłączony wąż układu EVAP",
        "Uszkodzony zawór odpowietrzania kanistra (przewietrzania)",
      ],
      diagnosticsSteps: [
        "Sprawdź i dokręć korek wlewu; skasuj kod i obserwuj powrót.",
        "Skontroluj węże EVAP pod kątem pęknięć i rozłączeń.",
        "W razie potrzeby wykonaj próbę szczelności (dymem) układu EVAP.",
      ],
    ),
    "P0562": const DtcCode(
      code: "P0562",
      title: "Za niskie napięcie zasilania (System Voltage Low)",
      category: "Zasilanie / ładowanie",
      description: "Napięcie pokładowe jest niższe od wymaganego — problem z ładowaniem lub akumulatorem.",
      commonCauses: [
        "Zużyty akumulator lub poluzowane/utlenione klemy",
        "Uszkodzony alternator lub regulator napięcia",
        "Rozciągnięty / ślizgający się pasek osprzętu",
        "Zwiększona rezystancja masy / przewodów zasilania",
      ],
      diagnosticsSteps: [
        "Zmierz napięcie na akumulatorze na postoju i przy pracy silnika (~14 V).",
        "Sprawdź stan i naciąg paska osprzętu.",
        "Skontroluj klemy i połączenia masy.",
      ],
    ),
    "P2015": const DtcCode(
      code: "P2015",
      title: "Klapy wirowe / czujnik położenia klap kolektora ssącego (Intake Runner Position)",
      category: "Kolektor dolotowy",
      description: "Sterownik wykrył niezgodność położenia klap wirowych kolektora ssącego z zadaniem — bardzo częsta usterka kolektorów z klapami wirowymi.",
      commonCauses: [
        "Wyłamana / poluzowana dźwignia klap wirowych w kolektorze",
        "Zużyty potencjometr położenia klap (często niewymienny osobno)",
        "Zablokowane nagarem klapy wirowe",
        "Uszkodzony silniczek sterujący klapami",
      ],
      diagnosticsSteps: [
        "Sprawdź w danych bieżących położenie zadane vs rzeczywiste klap.",
        "Oceń mechanicznie ruch dźwigni klap na kolektorze.",
        "Przy wyłamanej dźwigni zwykle konieczna wymiana kolektora / naprawa zestawem.",
      ],
    ),
    "P244A": const DtcCode(
      code: "P244A",
      title: "Za mała różnica ciśnień na filtrze DPF (DPF Differential Pressure Too Low)",
      category: "Filtr cząstek stałych DPF",
      description: "Różnica ciśnień na filtrze cząstek stałych jest niższa niż oczekiwana — sygnał możliwego uszkodzenia filtra lub układu pomiaru.",
      commonCauses: [
        "Uszkodzony / przepalony wkład DPF (utrata materiału filtrującego)",
        "Nieszczelność lub rozłączenie wężyków czujnika różnicy ciśnień",
        "Błędny odczyt czujnika różnicy ciśnień",
      ],
      diagnosticsSteps: [
        "Sprawdź odczyt różnicy ciśnień DPF w danych bieżących pod obciążeniem.",
        "Skontroluj wężyki pomiarowe pod kątem pęknięć i poprawnego podłączenia.",
        "Oceń stan wkładu DPF (możliwe wypalenie/uszkodzenie).",
      ],
    ),
    "P244B": const DtcCode(
      code: "P244B",
      title: "Za duża różnica ciśnień na filtrze DPF (DPF Differential Pressure Too High)",
      category: "Filtr cząstek stałych DPF",
      description: "Różnica ciśnień na DPF jest wyższa niż dopuszczalna — filtr jest mocno zapełniony sadzą/popiołem lub zatkany.",
      commonCauses: [
        "Zatkany filtr DPF (nadmiar sadzy — nieudane regeneracje) lub popiołu (przebieg)",
        "Częsta jazda miejska uniemożliwiająca regenerację",
        "Usterka obniżająca temperaturę spalin (EGR, wtryskiwacze) blokująca regenerację",
      ],
      diagnosticsSteps: [
        "Odczytaj poziom sadzy i popiołu oraz przebieg od ostatniej regeneracji.",
        "Sprawdź, czy regeneracje dochodzą do końca (temperatury spalin).",
        "Wyklucz usterki towarzyszące (EGR, ciśnienie doładowania, wtrysk) przed czyszczeniem/wymianą.",
      ],
    ),
    "P204F": const DtcCode(
      code: "P204F",
      title: "Nieprawidłowe działanie układu SCR / AdBlue (Reductant System Performance)",
      category: "Układ SCR (AdBlue)",
      description: "Układ AdBlue (płyn, który oczyszcza spaliny diesla z tlenków azotu) nie działa jak powinien. Auto może wejść w tryb awaryjny albo nie da się go odpalić po kolejnym rozruchu, dopóki usterka nie zniknie.",
      commonCauses: [
        "Zły lub rozcieńczony AdBlue albo zakrystalizowany płyn",
        "Uszkodzona pompka lub wtryskiwacz AdBlue",
        "Uszkodzony czujnik tlenków azotu (NOx)",
        "Zużyty katalizator SCR",
      ],
      diagnosticsSteps: [
        "Sprawdź jakość i poziom AdBlue oraz ciśnienie w układzie dozowania.",
        "Odczytaj wartości czujników NOx przed i za SCR w danych bieżących.",
        "Skontroluj wtryskiwacz reduktora pod kątem krystalizacji.",
      ],
    ),

    // === Uniwersalna baza kodów — opisy „dla Kowalskiego" (proste, każda marka, benzyna i diesel) ===
    "P0100": const DtcCode(
      code: "P0100",
      title: "Przepływomierz powietrza — usterka (Mass Air Flow Circuit)",
      category: "Pomiar powietrza dolotowego",
      description: "Czujnik, który mierzy ile powietrza wpada do silnika, wysyła błędne dane. Silnik może szarpać, gorzej ciągnąć i palić więcej.",
      commonCauses: [
        "Zabrudzony lub zużyty przepływomierz",
        "Poluzowana wtyczka lub uszkodzony przewód",
        "Zassane nieszczelności w dolocie (fałszywe powietrze)",
      ],
      diagnosticsSteps: [
        "Porównaj odczyt powietrza (g/s) z wartością wzorcową na jałowym i pełnym gazie.",
        "Sprawdź wtyczkę i przewody czujnika.",
        "Skontroluj szczelność dolotu i stan filtra powietrza.",
      ],
    ),
    "P0107": const DtcCode(
      code: "P0107",
      title: "Czujnik ciśnienia w dolocie (MAP) — za niski sygnał",
      category: "Pomiar powietrza dolotowego",
      description: "Czujnik ciśnienia w kolektorze dolotowym pokazuje nierealnie niską wartość. Silnik może źle pracować i mieć słabsze osiągi.",
      commonCauses: [
        "Uszkodzony czujnik MAP",
        "Przerwa w przewodzie lub skorodowana wtyczka",
        "Zapchany lub odłączony wężyk podciśnienia",
      ],
      diagnosticsSteps: [
        "Porównaj odczyt ciśnienia w dolocie z ciśnieniem atmosferycznym przy wyłączonym silniku.",
        "Sprawdź wtyczkę, przewody i wężyk czujnika.",
      ],
    ),
    "P0116": const DtcCode(
      code: "P0116",
      title: "Czujnik temperatury silnika — nieprawidłowy odczyt (ECT Range)",
      category: "Układ chłodzenia",
      description: "Czujnik temperatury płynu chłodzącego podaje dziwne wartości. Może to psuć spalanie i utrudniać rozruch na zimno.",
      commonCauses: [
        "Uszkodzony czujnik temperatury płynu",
        "Zawieszony termostat (silnik grzeje się nietypowo)",
        "Niski poziom płynu lub powietrze w układzie",
      ],
      diagnosticsSteps: [
        "Porównaj temperaturę z odczytu z rzeczywistą na zimnym silniku.",
        "Obserwuj wzrost temperatury po rozruchu.",
      ],
    ),
    "P0122": const DtcCode(
      code: "P0122",
      title: "Czujnik położenia przepustnicy — za niski sygnał (TPS Low)",
      category: "Przepustnica / sterowanie mocą",
      description: "Sterownik nie wie dokładnie, jak mocno wciśnięto gaz, bo czujnik przepustnicy daje zły sygnał. Auto może przejść w tryb awaryjny (ograniczona moc).",
      commonCauses: [
        "Uszkodzony potencjometr / moduł przepustnicy",
        "Uszkodzony przewód lub wtyczka",
        "Zabrudzona przepustnica",
      ],
      diagnosticsSteps: [
        "Obserwuj sygnał przepustnicy przy wciskaniu gazu w danych bieżących.",
        "Sprawdź wtyczkę i przewody przepustnicy.",
      ],
    ),
    "P0130": const DtcCode(
      code: "P0130",
      title: "Sonda lambda przed katalizatorem — usterka (O2 B1S1)",
      category: "Sondy lambda / spalanie",
      description: "Główna sonda mierząca skład spalin działa źle. Silnik może palić więcej i nierówno chodzić, świeci 'check engine'.",
      commonCauses: [
        "Zużyta lub zanieczyszczona sonda lambda",
        "Uszkodzone okablowanie lub grzałka sondy",
        "Nieszczelność wydechu przy sondzie",
      ],
      diagnosticsSteps: [
        "Sprawdź, czy sygnał sondy ładnie oscyluje po nagrzaniu.",
        "Skontroluj przewody i szczelność wydechu przy sondzie.",
      ],
    ),
    "P0135": const DtcCode(
      code: "P0135",
      title: "Grzałka sondy lambda przed katalizatorem — usterka (O2 Heater B1S1)",
      category: "Sondy lambda / spalanie",
      description: "Podgrzewanie sondy lambda nie działa, więc sonda za wolno zaczyna działać po odpaleniu. Zwiększone spalanie do czasu nagrzania.",
      commonCauses: [
        "Przepalona grzałka w sondzie",
        "Przepalony bezpiecznik lub uszkodzony przewód zasilania grzałki",
      ],
      diagnosticsSteps: [
        "Zmierz rezystancję grzałki sondy.",
        "Sprawdź zasilanie grzałki i bezpiecznik.",
      ],
    ),
    "P0137": const DtcCode(
      code: "P0137",
      title: "Sonda lambda za katalizatorem — za niski sygnał (O2 B1S2)",
      category: "Sondy lambda / spalanie",
      description: "Sonda kontrolna za katalizatorem pokazuje zaniżoną wartość. Zwykle nie czuć tego w jeździe, ale świeci kontrolka i może nie przejść badania.",
      commonCauses: [
        "Zużyta tylna sonda lambda",
        "Nieszczelność wydechu za katalizatorem",
        "Uszkodzone okablowanie",
      ],
      diagnosticsSteps: [
        "Porównaj sondę tylną z przednią w danych bieżących.",
        "Sprawdź szczelność wydechu za katalizatorem.",
      ],
    ),
    "P0201": const DtcCode(
      code: "P0201",
      title: "Obwód wtryskiwacza cylindra 1 (Injector Circuit Cyl. 1)",
      category: "Układ wtryskowy",
      description: "Sterownik zgłasza problem elektryczny z wtryskiwaczem 1. cylindra. Silnik może szarpać, gubić moc albo zapalać się na kontrolce.",
      commonCauses: [
        "Uszkodzony wtryskiwacz cylindra 1",
        "Przetarty przewód lub luźna wtyczka wtryskiwacza",
        "Uszkodzenie w sterowniku (rzadziej)",
      ],
      diagnosticsSteps: [
        "Zmierz rezystancję wtryskiwacza i sprawdź jego wtyczkę.",
        "Sprawdź sygnał sterujący wtryskiwaczem.",
      ],
    ),
    "P0327": const DtcCode(
      code: "P0327",
      title: "Czujnik spalania stukowego — za niski sygnał (Knock Sensor Low)",
      category: "Zapłon / spalanie stukowe",
      description: "Czujnik, który wykrywa 'stukanie' silnika, daje zły sygnał. Sterownik dla bezpieczeństwa zmniejsza zapłon, więc auto ma mniej mocy i pali więcej.",
      commonCauses: [
        "Uszkodzony czujnik stukowy",
        "Poluzowany czujnik (zły moment dokręcenia)",
        "Uszkodzone okablowanie / wtyczka",
      ],
      diagnosticsSteps: [
        "Sprawdź dokręcenie i stan czujnika stukowego.",
        "Skontroluj przewody i wtyczkę.",
      ],
    ),
    "P0335": const DtcCode(
      code: "P0335",
      title: "Czujnik położenia wału korbowego — usterka (Crankshaft Sensor)",
      category: "Czujniki / rozruch",
      description: "Sterownik gubi sygnał o położeniu wału korbowego. Auto może gasnąć, nie odpalać albo zapalać się z opóźnieniem.",
      commonCauses: [
        "Uszkodzony czujnik wału korbowego",
        "Uszkodzone okablowanie lub wtyczka",
        "Uszkodzony wieniec / koło impulsowe",
      ],
      diagnosticsSteps: [
        "Sprawdź sygnał czujnika przy próbie rozruchu.",
        "Skontroluj wtyczkę i przewody czujnika.",
      ],
    ),
    "P0351": const DtcCode(
      code: "P0351",
      title: "Obwód cewki zapłonowej cylindra 1 (Ignition Coil 1)",
      category: "Układ zapłonowy (benzyna)",
      description: "Problem z cewką zapłonową 1. cylindra. Silnik szarpie, traci moc, może 'kłuć' na kontrolce (mruga check engine).",
      commonCauses: [
        "Uszkodzona cewka zapłonowa cylindra 1",
        "Zużyta świeca zapłonowa",
        "Uszkodzony przewód / wtyczka cewki",
      ],
      diagnosticsSteps: [
        "Zamień cewkę z sąsiednim cylindrem i sprawdź, czy błąd wędruje.",
        "Sprawdź świecę i wtyczkę cewki.",
      ],
    ),
    "P0404": const DtcCode(
      code: "P0404",
      title: "Zawór EGR — nieprawidłowe działanie (EGR Range/Performance)",
      category: "Recyrkulacja spalin EGR",
      description: "Zawór zawracający część spalin (EGR) nie ustawia się tak, jak każe sterownik — często zakleja go nagar. Może być większe spalanie, dymienie lub tryb awaryjny.",
      commonCauses: [
        "Zawór EGR zakoksowany / zacięty",
        "Uszkodzony silniczek lub czujnik położenia zaworu",
        "Zabrudzone kanały EGR w kolektorze",
      ],
      diagnosticsSteps: [
        "Porównaj położenie zadane i rzeczywiste zaworu EGR.",
        "Zdemontuj i oczyść zawór, oceń ruch grzybka.",
      ],
    ),
    "P0411": const DtcCode(
      code: "P0411",
      title: "Układ wtórnego powietrza — zły przepływ (Secondary Air Injection)",
      category: "Układ oczyszczania spalin (benzyna)",
      description: "Układ dodmuchujący powietrze do wydechu po zimnym rozruchu (dla szybszego oczyszczania spalin) nie działa prawidłowo. Zwykle tylko świeci kontrolka.",
      commonCauses: [
        "Uszkodzona pompa wtórnego powietrza",
        "Zapchane kanały lub zawór (nagar/kondensat)",
        "Uszkodzony zawór odcinający lub jego sterowanie",
      ],
      diagnosticsSteps: [
        "Sprawdź działanie pompy wtórnego powietrza po zimnym rozruchu.",
        "Skontroluj drożność kanałów i zawór odcinający.",
      ],
    ),
    "P0442": const DtcCode(
      code: "P0442",
      title: "Mała nieszczelność układu par paliwa (EVAP Small Leak)",
      category: "Układ EVAP (benzyna)",
      description: "Układ, który zbiera opary paliwa z baku, ma małą nieszczelność. Auto jeździ normalnie — najczęściej winny jest źle dokręcony korek wlewu.",
      commonCauses: [
        "Niedokręcony lub zużyty korek wlewu paliwa",
        "Drobne pęknięcie węża EVAP",
        "Nieszczelny zawór odpowietrzania",
      ],
      diagnosticsSteps: [
        "Dokręć/wymień korek wlewu i skasuj kod.",
        "Sprawdź węże EVAP; w razie potrzeby próba dymowa.",
      ],
    ),
    "P0480": const DtcCode(
      code: "P0480",
      title: "Sterowanie wentylatorem chłodnicy — usterka (Cooling Fan 1)",
      category: "Układ chłodzenia",
      description: "Problem ze sterowaniem wentylatorem chłodnicy. Grozi przegrzaniem w korku lub na postoju z klimatyzacją.",
      commonCauses: [
        "Uszkodzony wentylator lub jego przekaźnik / sterownik",
        "Przepalony bezpiecznik",
        "Uszkodzone okablowanie",
      ],
      diagnosticsSteps: [
        "Sprawdź, czy wentylator załącza się przy wysokiej temperaturze / włączonej klimie.",
        "Skontroluj bezpiecznik, przekaźnik i przewody.",
      ],
    ),
    "P0500": const DtcCode(
      code: "P0500",
      title: "Czujnik prędkości pojazdu — brak sygnału (Vehicle Speed Sensor)",
      category: "Czujniki / sterowanie",
      description: "Sterownik nie wie, jak szybko jedzie auto. Może nie działać prędkościomierz, tempomat, a skrzynia automatyczna może dziwnie zmieniać biegi.",
      commonCauses: [
        "Uszkodzony czujnik prędkości / ABS",
        "Uszkodzone okablowanie",
        "Problem w sieci danych między sterownikami",
      ],
      diagnosticsSteps: [
        "Porównaj prędkość z odczytu z rzeczywistą podczas jazdy.",
        "Sprawdź czujniki prędkości i ich przewody.",
      ],
    ),
    "P0505": const DtcCode(
      code: "P0505",
      title: "Sterowanie biegiem jałowym — usterka (Idle Air Control)",
      category: "Bieg jałowy",
      description: "Silnik nie trzyma równych obrotów na jałowym — może gasnąć albo 'pływać' obrotami na postoju.",
      commonCauses: [
        "Zabrudzona przepustnica lub kanał obejścia powietrza",
        "Nieszczelności podciśnienia (fałszywe powietrze)",
        "Uszkodzony silniczek/krok biegu jałowego (starsze auta)",
      ],
      diagnosticsSteps: [
        "Oczyść przepustnicę i wykonaj adaptację przepustnicy.",
        "Sprawdź szczelność układu dolotowego.",
      ],
    ),
    "P0521": const DtcCode(
      code: "P0521",
      title: "Czujnik ciśnienia oleju — nieprawidłowy odczyt (Oil Pressure Range)",
      category: "Układ smarowania",
      description: "Czujnik ciśnienia oleju podaje dziwne wartości. UWAGA: jeśli ciśnienie oleju naprawdę jest za niskie, grozi to zatarciem silnika — traktuj poważnie.",
      commonCauses: [
        "Uszkodzony czujnik ciśnienia oleju",
        "Naprawdę niskie ciśnienie oleju (zużyta pompa, niski poziom, zły olej)",
        "Uszkodzone okablowanie",
      ],
      diagnosticsSteps: [
        "Sprawdź poziom i stan oleju.",
        "Zmierz rzeczywiste ciśnienie oleju manometrem, zanim wymienisz czujnik.",
      ],
    ),
    "P0606": const DtcCode(
      code: "P0606",
      title: "Usterka wewnętrzna sterownika silnika (ECM/PCM Processor)",
      category: "Sterownik silnika",
      description: "Komputer sterujący silnikiem zgłasza swój wewnętrzny błąd. Auto może wpaść w tryb awaryjny lub źle pracować.",
      commonCauses: [
        "Uszkodzony sterownik silnika (ECU)",
        "Problem z zasilaniem/masą sterownika",
        "Skutek zalania, korozji lub złego rozruchu z pomocą",
      ],
      diagnosticsSteps: [
        "Sprawdź zasilanie i masy sterownika oraz stan złączy.",
        "Zweryfikuj wersję oprogramowania; w razie potrzeby aktualizacja/naprawa ECU.",
      ],
    ),
    "P0627": const DtcCode(
      code: "P0627",
      title: "Sterowanie pompą paliwa — usterka (Fuel Pump Control Circuit)",
      category: "Zasilanie paliwem",
      description: "Problem ze sterowaniem pompą paliwa. Auto może gasnąć, nie odpalać albo tracić moc przy przyspieszaniu.",
      commonCauses: [
        "Uszkodzona pompa paliwa lub jej moduł sterujący",
        "Przekaźnik lub bezpiecznik pompy",
        "Uszkodzone okablowanie",
      ],
      diagnosticsSteps: [
        "Sprawdź zasilanie i sterowanie pompy paliwa.",
        "Zmierz ciśnienie paliwa.",
      ],
    ),
    "P0700": const DtcCode(
      code: "P0700",
      title: "Żądanie kontrolki od sterownika skrzyni (TCM Request MIL)",
      category: "Skrzynia biegów",
      description: "To nie jest sama usterka, tylko informacja, że sterownik skrzyni biegów wykrył problem i zapalił kontrolkę. Trzeba odczytać dokładne kody skrzyni.",
      commonCauses: [
        "Usterka zapisana w sterowniku skrzyni (osobny kod)",
        "Problemy z czujnikami lub elektrozaworami skrzyni",
        "Zły stan/poziom oleju w skrzyni automatycznej",
      ],
      diagnosticsSteps: [
        "Odczytaj kody bezpośrednio ze sterownika skrzyni biegów.",
        "Sprawdź poziom i stan oleju w skrzyni.",
      ],
    ),
    "P0741": const DtcCode(
      code: "P0741",
      title: "Sprzęgło blokady konwertera — poślizg (Torque Converter Clutch)",
      category: "Skrzynia automatyczna",
      description: "W skrzyni automatycznej sprzęgło blokujące przemiennik momentu ślizga się. Może być szarpanie przy stałej prędkości i większe spalanie.",
      commonCauses: [
        "Zużyty olej lub zapchany filtr skrzyni",
        "Uszkodzony elektrozawór (solenoid) blokady",
        "Zużyte sprzęgło blokady / przemiennik momentu",
      ],
      diagnosticsSteps: [
        "Sprawdź stan i poziom oleju w skrzyni; rozważ wymianę oleju i filtra.",
        "Odczytaj parametry pracy skrzyni w danych bieżących.",
      ],
    ),
    "U0101": const DtcCode(
      code: "U0101",
      title: "Brak komunikacji ze sterownikiem skrzyni (Lost Comm. with TCM)",
      category: "Sieć pokładowa (CAN)",
      description: "Sterownik silnika stracił kontakt ze sterownikiem skrzyni biegów przez sieć w aucie. Skrzynia może przejść w tryb awaryjny (jeden bieg).",
      commonCauses: [
        "Uszkodzone okablowanie / złącza sieci CAN",
        "Uszkodzony sterownik skrzyni lub jego zasilanie/masa",
        "Korozja lub zalanie złączy",
      ],
      diagnosticsSteps: [
        "Sprawdź zasilanie i masy sterownika skrzyni.",
        "Skontroluj przewody magistrali CAN i złącza.",
      ],
    ),
    "U0121": const DtcCode(
      code: "U0121",
      title: "Brak komunikacji ze sterownikiem ABS (Lost Comm. with ABS)",
      category: "Sieć pokładowa (CAN)",
      description: "Auto straciło łączność ze sterownikiem ABS. Zwykle gasną wtedy lampki ABS/ESP i te systemy nie działają, choć zwykłe hamulce hamują normalnie.",
      commonCauses: [
        "Uszkodzone okablowanie / złącza do modułu ABS",
        "Uszkodzony moduł ABS lub jego zasilanie",
        "Problem w magistrali CAN",
      ],
      diagnosticsSteps: [
        "Sprawdź zasilanie, masy i złącza modułu ABS.",
        "Skontroluj przewody magistrali CAN.",
      ],
    ),

    // === Uniwersalna baza — partia 2 (warianty low/high, cylindry 2-4, druga strona) ===
    "P0103": const DtcCode(
      code: "P0103",
      title: "Przepływomierz powietrza — za wysoki sygnał (MAF High)",
      category: "Pomiar powietrza dolotowego",
      description: "Czujnik ilości powietrza pokazuje za dużo powietrza. Silnik może nierówno pracować i palić więcej.",
      commonCauses: ["Uszkodzony przepływomierz", "Zwarcie w okablowaniu", "Błędne wskazanie po zabrudzeniu czujnika"],
      diagnosticsSteps: ["Porównaj odczyt powietrza z wartością wzorcową.", "Sprawdź przewody i wtyczkę czujnika."],
    ),
    "P0108": const DtcCode(
      code: "P0108",
      title: "Czujnik ciśnienia w dolocie (MAP) — za wysoki sygnał",
      category: "Pomiar powietrza dolotowego",
      description: "Czujnik ciśnienia w dolocie pokazuje za wysoką wartość. Może pogarszać pracę silnika i osiągi.",
      commonCauses: ["Uszkodzony czujnik MAP", "Zwarcie w okablowaniu", "Zapchany wężyk podciśnienia"],
      diagnosticsSteps: ["Porównaj odczyt ciśnienia z atmosferycznym przy zgaszonym silniku.", "Sprawdź wężyk i wtyczkę."],
    ),
    "P0112": const DtcCode(
      code: "P0112",
      title: "Czujnik temperatury powietrza — za niski sygnał (IAT Low)",
      category: "Pomiar powietrza dolotowego",
      description: "Czujnik temperatury zasysanego powietrza pokazuje nierealnie wysoką temperaturę (zwarcie). Drobny wpływ na spalanie.",
      commonCauses: ["Zwarcie w obwodzie czujnika", "Uszkodzony czujnik IAT"],
      diagnosticsSteps: ["Porównaj odczyt z temperaturą otoczenia.", "Sprawdź przewody czujnika."],
    ),
    "P0117": const DtcCode(
      code: "P0117",
      title: "Czujnik temperatury silnika — za niski sygnał (ECT Low)",
      category: "Układ chłodzenia",
      description: "Czujnik temperatury płynu pokazuje nierealnie wysoką temperaturę (zwarcie). Może psuć spalanie i włączać wentylator bez potrzeby.",
      commonCauses: ["Zwarcie w obwodzie", "Uszkodzony czujnik temperatury"],
      diagnosticsSteps: ["Porównaj odczyt z rzeczywistą temperaturą na zimno.", "Sprawdź przewody i wtyczkę."],
    ),
    "P0118": const DtcCode(
      code: "P0118",
      title: "Czujnik temperatury silnika — za wysoki sygnał (ECT High)",
      category: "Układ chłodzenia",
      description: "Czujnik temperatury płynu pokazuje nierealnie niską temperaturę (przerwa). Silnik może dłużej się grzać i palić więcej na zimno.",
      commonCauses: ["Przerwa w obwodzie", "Uszkodzony czujnik", "Skorodowana wtyczka"],
      diagnosticsSteps: ["Porównaj odczyt z rzeczywistą temperaturą.", "Sprawdź ciągłość przewodów."],
    ),
    "P0131": const DtcCode(
      code: "P0131",
      title: "Sonda lambda przed katalizatorem — za niski sygnał (O2 B1S1 Low)",
      category: "Sondy lambda / spalanie",
      description: "Główna sonda spalin pokazuje stale ubogą/zaniżoną wartość. Silnik może dorzucać paliwa i palić więcej.",
      commonCauses: ["Zużyta sonda lambda", "Nieszczelność wydechu przy sondzie", "Zwarcie w okablowaniu sondy"],
      diagnosticsSteps: ["Oceń przebieg sondy w danych bieżących.", "Sprawdź szczelność wydechu i przewody."],
    ),
    "P0134": const DtcCode(
      code: "P0134",
      title: "Sonda lambda przed katalizatorem — brak aktywności (O2 B1S1 No Activity)",
      category: "Sondy lambda / spalanie",
      description: "Główna sonda spalin nie reaguje — jakby jej nie było. Silnik pracuje na wartościach zastępczych, pali więcej.",
      commonCauses: ["Zużyta/martwa sonda lambda", "Uszkodzona grzałka sondy", "Przerwa w okablowaniu"],
      diagnosticsSteps: ["Sprawdź, czy sonda w ogóle daje sygnał po nagrzaniu.", "Zmierz grzałkę i zasilanie sondy."],
    ),
    "P0141": const DtcCode(
      code: "P0141",
      title: "Grzałka sondy za katalizatorem — usterka (O2 Heater B1S2)",
      category: "Sondy lambda / spalanie",
      description: "Nie działa podgrzewanie tylnej sondy lambda. Zwykle tylko świeci kontrolka i może nie przejść badania.",
      commonCauses: ["Przepalona grzałka tylnej sondy", "Bezpiecznik/okablowanie grzałki"],
      diagnosticsSteps: ["Zmierz rezystancję grzałki tylnej sondy.", "Sprawdź zasilanie i bezpiecznik."],
    ),
    "P0174": const DtcCode(
      code: "P0174",
      title: "Zbyt uboga mieszanka — strona 2 (System Too Lean B2)",
      category: "Spalanie / mieszanka",
      description: "Do drugiej połowy silnika trafia za dużo powietrza lub za mało paliwa. Objawy: nierówna praca, szarpanie, słabsze osiągi.",
      commonCauses: ["Nieszczelności dolotu (fałszywe powietrze)", "Słaby przepływomierz", "Za niskie ciśnienie paliwa", "Zabrudzone wtryskiwacze"],
      diagnosticsSteps: ["Sprawdź korekty paliwa w danych bieżących.", "Poszukaj nieszczelności dolotu.", "Zmierz ciśnienie paliwa."],
    ),
    "P0202": const DtcCode(
      code: "P0202",
      title: "Obwód wtryskiwacza cylindra 2 (Injector Circuit Cyl. 2)",
      category: "Układ wtryskowy",
      description: "Problem elektryczny z wtryskiwaczem 2. cylindra. Silnik może szarpać i gubić moc.",
      commonCauses: ["Uszkodzony wtryskiwacz cyl. 2", "Przetarty przewód / luźna wtyczka"],
      diagnosticsSteps: ["Zmierz rezystancję wtryskiwacza i sprawdź wtyczkę.", "Sprawdź sygnał sterujący."],
    ),
    "P0203": const DtcCode(
      code: "P0203",
      title: "Obwód wtryskiwacza cylindra 3 (Injector Circuit Cyl. 3)",
      category: "Układ wtryskowy",
      description: "Problem elektryczny z wtryskiwaczem 3. cylindra. Silnik może szarpać i gubić moc.",
      commonCauses: ["Uszkodzony wtryskiwacz cyl. 3", "Przetarty przewód / luźna wtyczka"],
      diagnosticsSteps: ["Zmierz rezystancję wtryskiwacza i sprawdź wtyczkę.", "Sprawdź sygnał sterujący."],
    ),
    "P0204": const DtcCode(
      code: "P0204",
      title: "Obwód wtryskiwacza cylindra 4 (Injector Circuit Cyl. 4)",
      category: "Układ wtryskowy",
      description: "Problem elektryczny z wtryskiwaczem 4. cylindra. Silnik może szarpać i gubić moc.",
      commonCauses: ["Uszkodzony wtryskiwacz cyl. 4", "Przetarty przewód / luźna wtyczka"],
      diagnosticsSteps: ["Zmierz rezystancję wtryskiwacza i sprawdź wtyczkę.", "Sprawdź sygnał sterujący."],
    ),
    "P0341": const DtcCode(
      code: "P0341",
      title: "Czujnik położenia wałka rozrządu — zły zakres (Camshaft Sensor Range)",
      category: "Czujniki / synchronizacja",
      description: "Sygnał czujnika wałka rozrządu jest niespójny z położeniem wału. Auto może gorzej odpalać i szarpać.",
      commonCauses: ["Uszkodzony czujnik wałka", "Rozciągnięty łańcuch / przesunięty rozrząd", "Uszkodzone koło impulsowe"],
      diagnosticsSteps: ["Porównaj sygnały wału i wałka.", "Sprawdź stan czujnika i okablowania."],
    ),
    "P0352": const DtcCode(
      code: "P0352",
      title: "Obwód cewki zapłonowej cylindra 2 (Ignition Coil 2)",
      category: "Układ zapłonowy (benzyna)",
      description: "Problem z cewką zapłonową 2. cylindra. Silnik szarpie i traci moc.",
      commonCauses: ["Uszkodzona cewka cyl. 2", "Zużyta świeca", "Uszkodzony przewód / wtyczka"],
      diagnosticsSteps: ["Zamień cewkę z sąsiednim cylindrem.", "Sprawdź świecę i wtyczkę."],
    ),
    "P0403": const DtcCode(
      code: "P0403",
      title: "Obwód sterowania zaworem EGR (EGR Control Circuit)",
      category: "Recyrkulacja spalin EGR",
      description: "Problem elektryczny ze sterowaniem zaworu EGR. Może rosnąć spalanie, dymienie lub tryb awaryjny.",
      commonCauses: ["Uszkodzony zawór/silniczek EGR", "Uszkodzone okablowanie / wtyczka"],
      diagnosticsSteps: ["Sprawdź sterowanie i sygnał położenia zaworu.", "Skontroluj przewody i wtyczkę."],
    ),
    "P0430": const DtcCode(
      code: "P0430",
      title: "Niska sprawność katalizatora — strona 2 (Catalyst B2)",
      category: "Układ oczyszczania spalin",
      description: "Katalizator po drugiej stronie silnika (w V6/V8) słabo oczyszcza spaliny. Auto zwykle jeździ normalnie, ale świeci kontrolka i nie przejdzie badania.",
      commonCauses: ["Zużyty katalizator", "Nieszczelność wydechu przy sondach", "Zestarzała tylna sonda"],
      diagnosticsSteps: ["Porównaj sondy przed i za katalizatorem.", "Wyklucz przyczyny mieszanki przed wymianą."],
    ),
    "P0506": const DtcCode(
      code: "P0506",
      title: "Obroty jałowe za niskie (Idle Speed Low)",
      category: "Bieg jałowy",
      description: "Silnik na jałowym kręci wolniej niż powinien — może gasnąć na postoju, zwłaszcza z włączoną klimą.",
      commonCauses: ["Zabrudzona przepustnica", "Nieszczelności dolotu", "Obciążenie od osprzętu / słabe zasilanie"],
      diagnosticsSteps: ["Oczyść przepustnicę i wykonaj adaptację.", "Sprawdź szczelność dolotu."],
    ),
    "P0563": const DtcCode(
      code: "P0563",
      title: "Za wysokie napięcie zasilania (System Voltage High)",
      category: "Zasilanie / ładowanie",
      description: "Napięcie w instalacji jest za wysokie — winny zwykle alternator/regulator. Grozi to szybszym zużyciem żarówek i elektroniki.",
      commonCauses: ["Uszkodzony regulator napięcia alternatora", "Zły styk na masie/pomiarze napięcia"],
      diagnosticsSteps: ["Zmierz napięcie na akumulatorze przy pracy silnika (powinno ~14 V).", "Sprawdź alternator i masy."],
    ),
    "P0601": const DtcCode(
      code: "P0601",
      title: "Błąd pamięci sterownika silnika (ECM Memory Checksum)",
      category: "Sterownik silnika",
      description: "Komputer silnika wykrył błąd w swojej pamięci/oprogramowaniu. Auto może źle pracować lub nie odpalać.",
      commonCauses: ["Uszkodzony sterownik", "Nieudana lub przerwana aktualizacja oprogramowania", "Problem zasilania sterownika"],
      diagnosticsSteps: ["Sprawdź zasilanie i masy sterownika.", "Zweryfikuj/wgraj poprawne oprogramowanie."],
    ),
    "P0715": const DtcCode(
      code: "P0715",
      title: "Czujnik obrotów wejściowych skrzyni — brak sygnału (Input Speed Sensor)",
      category: "Skrzynia automatyczna",
      description: "Skrzynia automatyczna nie wie, jak szybko kręci się jej wał wejściowy. Biegi mogą zmieniać się szarpiąc lub skrzynia wchodzi w tryb awaryjny.",
      commonCauses: ["Uszkodzony czujnik obrotów w skrzyni", "Uszkodzone okablowanie", "Zły stan/poziom oleju w skrzyni"],
      diagnosticsSteps: ["Odczytaj obroty wejściowe/wyjściowe skrzyni w danych bieżących.", "Sprawdź czujniki i okablowanie skrzyni."],
    ),
    "P0730": const DtcCode(
      code: "P0730",
      title: "Nieprawidłowe przełożenie skrzyni (Incorrect Gear Ratio)",
      category: "Skrzynia automatyczna",
      description: "Skrzynia automatyczna nie trzyma prawidłowych przełożeń — może ślizgać się, szarpać przy zmianie biegów albo wpaść w tryb awaryjny.",
      commonCauses: ["Zużyty olej / zapchany filtr skrzyni", "Uszkodzone elektrozawory (solenoidy)", "Zużyte sprzęgła/pasek (CVT)"],
      diagnosticsSteps: ["Sprawdź stan i poziom oleju w skrzyni.", "Odczytaj parametry pracy skrzyni i pozostałe kody."],
    ),
    "U0155": const DtcCode(
      code: "U0155",
      title: "Brak komunikacji z zegarami / zestawem wskaźników (Lost Comm. with Cluster)",
      category: "Sieć pokładowa (CAN)",
      description: "Auto straciło łączność z licznikami na desce. Wskazówki i kontrolki mogą działać dziwnie lub gasnąć.",
      commonCauses: ["Uszkodzone okablowanie / złącza do zestawu wskaźników", "Uszkodzony zestaw wskaźników lub jego zasilanie", "Problem w magistrali CAN"],
      diagnosticsSteps: ["Sprawdź zasilanie, masy i złącza zestawu wskaźników.", "Skontroluj przewody magistrali CAN."],
    ),
  };

  /// Opisy kodów (angielskie) z pliku danych — wczytywane przy starcie aplikacji.
  static Map<String, String> _descriptions = {};

  static int get descriptionCount => _descriptions.length;

  /// Opisy 5-cyfrowych kodów VAG (KWP1281/KWP2000) — np. „00532” → „Supply Voltage B+”.
  static Map<String, String> _vagDescriptions = {};

  static void loadVagDescriptions(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    final codes = (data["codes"] ?? data) as Map<String, dynamic>;
    _vagDescriptions = {for (final e in codes.entries) if (!e.key.startsWith("_")) e.key: e.value.toString()};
  }

  /// Kod usterki VAG z modułu KWP2000 (TP2.0). Kody 16384+ to zakodowane kody P
  /// (np. 16684 = P0300) — wtedy używany jest opis kodu P.
  static DtcCode fromVagFault(int code, {String? obdCode}) {
    final five = code.toString().padLeft(5, '0');
    if (obdCode != null) {
      final base = getByCode(obdCode, profile: VehicleProfile.vag);
      return DtcCode(
        code: "$five / $obdCode",
        title: base.title,
        category: base.category,
        description: base.description,
        commonCauses: base.commonCauses,
        diagnosticsSteps: base.diagnosticsSteps,
      );
    }
    final desc = _vagDescriptions[five];
    return DtcCode(
      code: five,
      title: desc ?? "Kod usterki VAG $five",
      category: "Kod producenta VAG",
      description: desc != null
          ? "Opis kodu VAG (EN): $desc."
          : "Kod usterki VAG spoza wbudowanej bazy — sprawdź jego znaczenie w dokumentacji serwisowej.",
      commonCauses: const ["Usterka elementu wskazanego w opisie kodu lub jego instalacji elektrycznej"],
      diagnosticsSteps: const ["Sprawdź wtyczki i przewody elementu wskazanego w opisie kodu."],
    );
  }

  /// Wczytuje opisy z JSON: {"codes": {"P0087": "...", ...}}.
  static void loadDescriptions(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    final codes = (data["codes"] ?? data) as Map<String, dynamic>;
    _descriptions = {
      for (final e in codes.entries)
        if (!e.key.startsWith("_")) e.key.toUpperCase(): e.value.toString(),
    };
  }

  /// Kod zdefiniowany przez normę SAE J2012 (to samo znaczenie w każdym aucie).
  /// Pozostałe (np. P1xxx, U1xxx) mają znaczenie zależne od producenta.
  static bool isGenericCode(String code) {
    if (code.length < 5) return false;
    final letter = code[0];
    final d1 = code[1];
    if (letter == "P") {
      if (d1 == "0" || d1 == "2") return true;
      if (d1 == "3") return code.substring(2, 3) == "4"; // P34xx — wyłączanie cylindrów
      return false;
    }
    return d1 == "0" || d1 == "3";
  }

  /// Opis angielski dopuszczalny dla danego auta: kody standardowe zawsze
  /// (bez numerów części VAG w innych markach), kody producenta tylko w VAG.
  static String? descriptionFor(String code, {VehicleProfile? profile}) {
    final d = _descriptions[code];
    if (d == null) return null;
    final isVag = profile == VehicleProfile.vag;
    if (!isGenericCode(code) && !isVag) return null;
    if (isVag) return d;
    // Numery części VAG (np. „(G28)”, „(N75)”) w innych markach wprowadzałyby w błąd
    return d.replaceAll(RegExp(r'\s*\((?:[GNJVFZ]\d{1,4}[a-z]?(?:\s*/\s*[GNJVFZ]\d{1,4}[a-z]?)*)\)'), "").trim();
  }

  static DtcCode getByCode(String code, {VehicleProfile? profile}) {
    final upper = code.toUpperCase().trim();
    if (database.containsKey(upper)) {
      return database[upper]!;
    }
    final area = systemAreaFor(upper);
    final desc = descriptionFor(upper, profile: profile);
    return DtcCode(
      code: upper,
      title: desc ?? "Kod błędu OBD-II $upper",
      category: area,
      description: desc != null
          ? "Opis kodu (EN): $desc. Obszar: $area."
          : "Zarejestrowano kod usterki w pamięci sterownika. Obszar: $area. "
              "${isGenericCode(upper) ? 'Tego kodu nie ma we wbudowanej bazie' : 'To kod producenta — jego znaczenie zależy od marki'} — sprawdź jego dokładne znaczenie dla swojego modelu.",
      commonCauses: [
        "Usterka czujnika, osprzętu silnika lub instalacji elektrycznej",
        "Wartość pomiarowa poza zakresem tolerancji sterownika",
      ],
      diagnosticsSteps: [
        "Zweryfikuj parametry bieżące w zakładce Rejestrator i Wykres.",
        "Skontroluj stan przewodów elektrycznych i wtyczek.",
      ],
    );
  }
}
