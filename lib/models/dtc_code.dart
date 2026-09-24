class DtcCode {
  final String code; // np. "P0087"
  final String title; // np. "Za niskie ciśnienie paliwa w układzie / na listwie wtryskowej"
  final String category; // np. "Układ paliwowy i zasilania"
  final String description; // Szczegółowy opis techniczny
  final List<String> commonCauses; // Typowe przyczyny (np. w silnikach TSI)
  final List<String> diagnosticsSteps; // Kroki sprawdzenia

  const DtcCode({
    required this.code,
    required this.title,
    required this.category,
    required this.description,
    required this.commonCauses,
    required this.diagnosticsSteps,
  });

  /// Wbudowana baza popularnych kodów błędów (ze szczególnym uwzględnieniem grupy VAG / TSI)
  static final Map<String, DtcCode> database = {
    "P0087": const DtcCode(
      code: "P0087",
      title: "Ciśnienie paliwa na szynie / w układzie wtryskowym - za niskie (Fuel Rail Pressure Too Low)",
      category: "Układ wtryskowy wysokiego ciśnienia (TSI / FSI)",
      description: "Sterownik ECU zarejestrował spadek ciśnienia na listwie wysokiego ciśnienia (HPFP) poniżej wartości zadanej – szczególnie zauważalne na biegu jałowym lub pod obciążeniem.",
      commonCauses: [
        "Nieszczelny, lejący wtryskiwacz bezpośredni (np. cylinder 1) – paliwo ucieka z listwy do komory spalania, powodując spadek ciśnienia na jałowych obrotach i zalewanie cylindra",
        "Zużyta lub zacierająca się mechaniczna pompa wysokiego ciśnienia (HPFP) napędzana z wałka rozrządu",
        "Wytarta szklanka popychacza pompy wysokiego ciśnienia na wałku rozrządu",
        "Uszkodzony zawór regulacyjny ciśnienia paliwa (N276 na pompie HPFP)",
        "Spadek ciśnienia wstępnego z pompy w baku (LPFP) lub zapchany filtr paliwa",
        "Uszkodzony czujnik ciśnienia na listwie paliwowej (G247)",
      ],
      diagnosticsSteps: [
        "Sprawdź korektę wtrysku i wypadanie zapłonów na 1. cylindrze (jeśli wtrysk leje, cylinder 1 będzie miał mocno ujemną korektę i okopconą świecę).",
        "Wykręć świecę na 1. cylindrze po postoju – jeśli czuć intensywny zapach benzyny lub świeca jest mokra, wtryskiwacz #1 nie trzyma ciśnienia.",
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
  };

  static DtcCode getByCode(String code) {
    final upper = code.toUpperCase().trim();
    if (database.containsKey(upper)) {
      return database[upper]!;
    }
    return DtcCode(
      code: upper,
      title: "Kod błędu OBD-II $upper",
      category: "Ogólna diagnostyka ECU",
      description: "Zarejestrowano kod usterki w pamięci sterownika silnika.",
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
