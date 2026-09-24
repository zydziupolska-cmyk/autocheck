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

Sekwencyjna pętla odpytuje tylko czujniki, które sterownik zgłosił w masce obsługiwanych
PID-ów (`0100/0120/…`). Każdy wybrany PID jest wysyłany dopiero po otrzymaniu odpowiedzi na
poprzedni. Jeśli adapter to obsługuje, zapytania mają dopisaną liczbę odpowiedzi (`010C1`) —
adapter wtedy nie czeka na timeout magistrali. Nieudany odczyt oznacza brak wartości (a nie 0).
Logi zapisywane są na telefonie (JSON) i można je eksportować do CSV.

Liczniki wypadania zapłonów cylindrów 1-4 pochodzą z **Mode 06** (monitory `$A2-$A5`,
licznik bieżącego cyklu jazdy). Są dostępne w autach benzynowych na CAN.

## 4. Asystent diagnostyczny (`AnomalyEngine`)

Analiza osi czasu po próbie drogowej: cofanie zapłonu (knock), spadki i odchyłki doładowania,
niedoładowanie skorelowane z DPF, skład mieszanki, MAF, nagrzewanie dolotu, korekty paliwa,
ciśnienie na listwie, falowanie obrotów na biegu jałowym, VVT, leniwa sonda lambda,
wypadanie zapłonów (przyrost licznika Mode 06 + korekty paliwa → brak paliwa vs brak iskry)
oraz wykrywanie wyłączonego DPF/EGR. Pełny gaz wykrywany jest z pedału gazu (w dieslach
przepustnica to klapa dławiąca), a gdy go brak — z TPS (benzyna) lub obciążenia.

## 5. Kody błędów

Mode 03 (zapisane) i Mode 07 (oczekujące) ze wszystkich sterowników, z oznaczeniem źródła
(np. „Silnik (7E8)”). Na CAN po bajcie `43` pomijany jest licznik kodów, w protokołach
starszych — nie. Mode 04 kasuje kody po potwierdzeniu; aplikacja sprawdza odpowiedź `44`.

## Testy

```bash
flutter test
```

`test/support/mock_elm327.dart` emuluje adapter ELM327 na TCP z samochodem z dwoma
sterownikami. Warianty: diesel CAN 11-bit (VW Touran 2.0 TDI), benzyna z Mode 06,
CAN 29-bit i KWP2000. `test/obd_service_test.dart` testuje na nich cały proces:
połączenie, VIN, kody błędów i odczyt czujników.
`test/support/synthetic_logs.dart` to syntetyczne logi z usterkami do testów reguł Asystenta
(tylko testy, nie są częścią aplikacji).
