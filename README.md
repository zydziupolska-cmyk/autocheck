# AutoCheck — Dokumentacja Architektury i Działania

AutoCheck to aplikacja diagnostyczna OBD-II (Flutter, Android). Cel: zamiast wymieniać części
w ciemno — twarda, inżynieryjna diagnoza oparta na danych. Łączy skaner błędów, szybki
datalogger (próby drogowe WOT) i asystenta, który automatycznie analizuje zebrane logi.
Aplikacja działa wyłącznie na danych z prawdziwego samochodu — nie ma trybu symulacji.

## 1. Połączenie i komunikacja (ELM327 / vLinker)

Transport (`lib/services/obd_service.dart`):

- **Bluetooth Classic (SPP)** — adapter sparowany w systemie (`flutter_bluetooth_serial`),
  z ponowieniem połączenia (do 3 prób).
- **Wi-Fi (TCP)** — domyślnie `192.168.0.10:35000`.
- **BLE** — usługi UART (vLinker `18F0`, klony `FFE0`/`FFF0`); odbiór przez
  `onValueReceived`, czyli wyłącznie dane z adaptera.

### Inicjalizacja (handshake)

| Komenda | Cel |
|---|---|
| `ATZ` | reset adaptera |
| `ATE0` | echo off (echo i tak jest dodatkowo odfiltrowywane) |
| `ATL0` | bez zbędnych znaków nowej linii |
| `ATS1` | spacje między bajtami — jednoznaczne parsowanie hexów |
| `ATH1` | **nagłówki ON** — każda odpowiedź jest przypisana do sterownika |
| `ATAT1` | adaptacyjny timeout |
| `ATSP0` | automatyczny wybór protokołu |

Następnie `0100` wykrywa protokół, a `ATDPN` określa magistralę: CAN 11-bit, CAN 29-bit
albo protokoły starsze (ISO 9141-2, KWP2000, J1850).

**Dlaczego nagłówki są włączone (ATH1, a nie ATH0):** w wielu autach na zapytanie odpowiada
kilka sterowników naraz (np. silnik 7E8 i skrzynia 7E9). Bez nagłówków ich odpowiedzi zlewają
się w jeden ciąg bajtów — to właśnie dawało fikcyjny kod C0300 (`43 00` + `43 00`) i dane
jednego ECU wymieszane z drugim. Parser (`lib/services/elm_parser.dart`) grupuje ramki według
nadawcy i składa wiadomości wieloramkowe ISO-TP osobno dla każdego sterownika.

Po wykryciu sterownika silnika (tego, który obsługuje RPM) zapytania o czujniki idą do niego
fizycznie (`ATSH 7E0` / `18DA10F1`), a kody błędów — do wszystkich sterowników (`7DF`).

### Kolejka komend (mutex)

Adapter ELM327 jest jednowątkowy. Każda komenda czeka w kolejce, aż poprzednia otrzyma pełną
odpowiedź (znak `>`). Po przekroczeniu czasu aplikacja czeka na zaległy `>`, zanim wyśle
kolejną komendę, a każda odpowiedź jest weryfikowana (usługa + numer PID). Dzięki temu
spóźniona odpowiedź nigdy nie trafi do innego czujnika. Komunikaty `NO DATA`, `SEARCHING...`,
`STOPPED`, `CAN ERROR` itp. są odfiltrowywane.

## 2. Rozpoznawanie pojazdu

Mode 09: VIN (`0902`), CALID (`0904`), nazwa ECU (`090A`) — tylko ze sterownika silnika.

- **WMI** (pozycje 1-3 VIN) — marka i kraj dla ponad 50 producentów; w razie braku
  dopasowania region z pierwszego znaku VIN.
- **Model VAG** — z pozycji 7-8 VIN (np. `1T` = Touran). Pozycje 4-6 w europejskich VIN-ach
  VAG to zwykle `ZZZ`, więc nie identyfikują silnika.
- **Silnik** — z numeru oprogramowania ECU (np. `03L906…` = TDI CR EA189).
- **Paliwo** — z PID `0151`, a gdy go brak, z numeru ECU. W trybie diesla Asystent wyłącza
  reguły benzynowe.

## 3. Datalogger

### Parametry: standard OBD-II i UDS producenta

Każdy kanał ma jedną nazwę (np. `BOOST`, `TARGET_BOOST`) niezależnie od źródła. Po połączeniu
aplikacja wybiera pierwsze źródło, które sterownik faktycznie obsługuje:

| Kanał | Źródła (w kolejności) |
|---|---|
| Doładowanie rzeczywiste `BOOST` | PID 70 (ta sama referencja co zadane) → 87 → 0B → UDS producenta |
| Doładowanie zadane `TARGET_BOOST` | PID 70 → UDS producenta (VAG `2029`, BMW, PSA) |
| Szyna paliwa `F_RAIL` / `RAIL_TGT` | PID 6D (zadane + rzeczywiste) → 23 → 59 → UDS |
| Turbina `VGT_CMD/ACT`, `WG_CMD/ACT` | PID 71, 72 |
| EGR `EGR_CMD/ACT` | PID 69 → 2C |
| Spaliny | `DPF_DP` (7A), `EXH_P` (73), `EGT` (78), `DPF_T` (7C) |
| Moment `TQ_DEMAND/ACT` | PID 61, 62 |

PID-y wielowartościowe (70, 6D, 71, 69…) mają bajt maski obsługi — przy połączeniu są
odczytywane raz, żeby sprawdzić, które wartości ECU naprawdę podaje. Parametry UDS (Mode 22)
są sprawdzane pod kątem pozytywnej odpowiedzi (`62`) i wiarygodności wartości. Jednostka
ciśnienia doładowania z UDS (kPa / hPa / bar) jest wykrywana automatycznie po wartości
atmosferycznej. Tabele producentów są generowane z plików CSV (`scripts/generate_pids.py`).

### Harmonogram odpytywania

Kanały z tego samego zapytania (np. zadane i rzeczywiste doładowanie z PID 70) kosztują jedno
zapytanie. Szybkie kanały (obroty, pedał, doładowanie, MAF, szyna) są odczytywane w każdym
cyklu, normalne co 2 cykle, wolne (temperatury, liczniki wypadania zapłonów) co 8 cykli, a
podczas przyspieszenia wolne kanały czekają. Jeśli adapter to obsługuje, zapytania mają
dopisaną liczbę odpowiedzi (`010C1`), więc adapter nie czeka na timeout magistrali.

### Dwa tryby pomiaru

- **Przyspieszenie** — rejestrator uzbraja się i sam łapie moment wciśnięcia gazu do końca
  (pedał ≥ 80%, bez pedału obciążenie ≥ 85%). Pomiar kończy się po zdjęciu gazu, spadku
  obrotów (zmiana biegu / odcięcie) lub po 30 s. Zapisuje się samo przyspieszenie z 1 s
  zapasu przed startem. Za krótkie próby (< 1,5 s lub < 1000 obr/min przyrostu) są odrzucane
  z podpowiedzią dla kierowcy.
- **Jazda diagnostyczna** — dowolnie długi log (np. 30 min) z autozapisem co minutę.
  Na żywo widać czas, dystans, liczbę wykrytych przyspieszeń, czas na biegu jałowym oraz
  podpowiedzi, czego jeszcze brakuje do pełnej diagnozy.

Nieudany odczyt oznacza brak wartości (a nie 0). Logi zapisywane są na telefonie (JSON)
i można je eksportować do CSV.

## 4. Asystent diagnostyczny

`lib/services/analysis/drive_analyzer.dart` analizuje całą jazdę: wyszukuje przyspieszenia,
grupuje dane w przedziały obrotów i porównuje czujniki ze sobą w tych samych warunkach.

**Diagnoza różnicowa braku doładowania.** Gdy turbo nie osiąga zadanego ciśnienia, analizator
zbiera dowody dla każdej przyczyny i wskazuje najbardziej prawdopodobną:

| Przyczyna | Dowody |
|---|---|
| Zapchany DPF | duża różnica ciśnień na DPF względem przepływu, wysokie ciśnienie/temperatura spalin, spadek napełnienia cylindrów |
| Nieszczelność dolotu | przepływomierz mierzy więcej powietrza, niż pasuje do ciśnienia; DPF drożny |
| Geometria VGT / wastegate | pozycja rzeczywista ≠ zadana |
| Zawór EGR otwarty | EGR otwarty pod pełnym gazem |
| Ograniczony dolot | spadek napełnienia przy drożnym DPF |
| Tryb awaryjny | sterownik sam nie żąda doładowania |

Napełnienie cylindrów liczone jest jako `MAF / (obroty × ciśnienie bezwzględne)` i porównywane
z tym samym silnikiem w chwilach, gdy doładowanie było prawidłowe — bez znajomości pojemności
silnika. Każdy wniosek ma krótkie podsumowanie prostym językiem („co to znaczy”), odczyty
pozostałych czujników, wykluczone przyczyny i zalecenia.

Pozostałe analizy: ciśnienie paliwa zadane vs rzeczywiste (zasilanie pod obciążeniem vs
nieszczelność/przelewy), nadążanie VGT/wastegate/EGR za sterownikiem, zapełnienie DPF z całej
jazdy (różnica ciśnień względem przepływu), ograniczanie momentu, przeładowanie turbo,
a także reguły z `AnomalyEngine`: cofanie zapłonu, skład mieszanki, leniwa sonda lambda,
wypadanie zapłonów (przyrost licznika Mode 06 + korekty paliwa → brak paliwa vs brak iskry),
falowanie obrotów, VVT, wyłączony DPF/EGR (EGR oceniany przy częściowym obciążeniu, bo pod
pełnym gazem każdy sprawny silnik go zamyka). Asystent pokazuje też, czego log nie pozwolił
ocenić (np. brak przyspieszenia, brak zadanego doładowania).

## 5. Kody błędów

Mode 03 (zapisane) i Mode 07 (oczekujące) ze wszystkich sterowników, z oznaczeniem źródła
(np. „Silnik (7E8)”). Na CAN po bajcie `43` pomijany jest licznik kodów, w protokołach
starszych — nie. Mode 04 kasuje kody po potwierdzeniu; aplikacja sprawdza odpowiedź `44`.

## Testy

```bash
flutter test
```

`test/support/mock_elm327.dart` emuluje adapter ELM327 na TCP z samochodem z dwoma
sterownikami. Warianty: diesel CAN 11-bit (VW Touran 2.0 TDI, PID 70/6D/71/69), benzyna
z Mode 06 i UDS VAG, CAN 29-bit i KWP2000. Stan silnika można zmieniać w trakcie testu, więc
`test/obd_service_test.dart` testuje cały proces — od połączenia, przez automatyczne złapanie
przyspieszenia, po wskazanie przyczyny przez Asystenta.
`test/drive_analyzer_test.dart` sprawdza diagnozę różnicową na fizycznie spójnym modelu
diesla (DPF, nieszczelność, VGT, EGR, tryb awaryjny, szyna paliwa) i brak fałszywych alarmów
w 30-minutowej sprawnej jeździe.
`test/support/synthetic_logs.dart` to syntetyczne logi z usterkami do testów reguł Asystenta
(tylko testy, nie są częścią aplikacji).
