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
      description: "Układ selektywnej redukcji katalitycznej (SCR/AdBlue) nie działa w zakresie oczekiwanym — problem z dozowaniem lub jakością reduktora.",
      commonCauses: [
        "Zła jakość / rozcieńczony AdBlue lub skrystalizowany reduktor",
        "Uszkodzona pompa lub wtryskiwacz AdBlue",
        "Uszkodzony czujnik NOx",
        "Zatkany / uszkodzony katalizator SCR",
      ],
      diagnosticsSteps: [
        "Sprawdź jakość i poziom AdBlue oraz ciśnienie w układzie dozowania.",
        "Odczytaj wartości czujników NOx przed i za SCR w danych bieżących.",
        "Skontroluj wtryskiwacz reduktora pod kątem krystalizacji.",
      ],
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
