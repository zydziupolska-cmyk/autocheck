# Kostka Dynomic OBD — prototyp (XIAO ESP32-C6)

Własny adapter OBD dla aplikacji Dynomic Diag. Firmware udaje ELM327 v2.2 z rozszerzeniami
STN (STI, STPX, STMA), więc aplikacja działa z kostką bez zmian: łączy się przez Bluetooth LE
jak z vLinkerem.

Co już działa w firmware v0.1.0 (sprawdzone testami aplikacji na symulatorze auta):

- CAN 11/29-bit, 500/250 kb/s, automatyczny wybór protokołu,
- zapytania OBD i UDS z długimi odpowiedziami (ISO-TP, ramki sterowania przepływem),
- szybkie zapytania STPX i liczba odpowiedzi (`010C1`), kilka PID-ów w zapytaniu,
- surowy CAN (protokół użytkownika B) — skan modułów VW TP2.0,
- cichy podsłuch (ATMA/STMA, tryb bez nadawania i bez ACK) — nauka od Autela na kablu Y,
- pomiar napięcia akumulatora (ATRV),
- samoczynne uśpienie po 5 min bezczynności przy wyłączonym silniku, budzenie ruchem na CAN.

Czego jeszcze nie ma: K-Line (auta mniej więcej sprzed 2008 r.), CAN-FD, parowanie BLE z PIN-em.

## Części

| # | Część | Uwagi | Cena orient. |
|---|-------|-------|--------------|
| 1 | Seeed Studio XIAO ESP32-C6 | procesor, Bluetooth LE, kontroler CAN (TWAI) | ~30 zł |
| 2 | Moduł transceivera CAN SN65HVD230 (np. „VP230”, zasilanie 3,3 V) | **zdejmij z modułu rezystor 120 Ω** (terminator) — auto ma własne | ~10 zł |
| 3 | Przetwornica Pololu D36V6F5 (5 V, 600 mA, wejście do 50 V) | ma zabezpieczenie przed odwrotną polaryzacją | ~35 zł |
| 4 | Dioda TVS SMBJ24A | tłumi przepięcia z instalacji (np. przy rozruchu) | ~2 zł |
| 5 | Bezpiecznik polimerowy (PTC) 0,5 A | w linii +12 V | ~2 zł |
| 6 | Dioda Schottky SS14 | między przetwornicą a pinem 5V XIAO — pozwala podłączyć USB, gdy kostka jest w aucie | ~1 zł |
| 7 | Rezystory 100 kΩ i 22 kΩ, kondensator 100 nF | dzielnik do pomiaru napięcia akumulatora | ~1 zł |
| 8 | Wtyk OBD-II męski 16-pin z obudową (albo przewód OBD z wtykiem) | | ~15–25 zł |
| 9 | Kabel Y OBD (rozdzielacz) | tylko do nauki od Autela | ~20 zł |

## Połączenia

Gniazdo OBD w aucie: **16** = +12 V (akumulator, stale), **4** = masa nadwozia, **5** = masa
sygnałowa, **6** = CAN-H, **14** = CAN-L.

```
 OBD 16 (+12V) ──[PTC 0,5A]──┬───────────────┬──────────────► VIN  Pololu D36V6F5
                             │               │                       VOUT 5V ──►|── SS14 ──► 5V  XIAO
                          TVS SMBJ24A     100 kΩ                     GND ─────────────────► GND XIAO
                             │               ├──────────────────────────────────────────► D0  XIAO (GPIO0, pomiar)
                             │             22 kΩ ║ 100 nF
 OBD 4, OBD 5 (masa) ────────┴───────────────┴─────────── GND (wspólna dla wszystkiego)

 SN65HVD230                       XIAO ESP32-C6
   3V3  ◄──────────────────────── 3V3
   GND  ◄──────────────────────── GND
   D / TX ◄────────────────────── D3 (GPIO21)  CAN TX
   R / RX ───────────────────────► D1 (GPIO1)   CAN RX (budzi z uśpienia)
   Rs / S ◄────────────────────── D2 (GPIO2)   0 = praca, 1 = czuwanie
   CANH ─────────────────────────► OBD 6
   CANL ─────────────────────────► OBD 14
```

Numery GPIO dla wyprowadzeń XIAO są w `firmware/main/board.h` — przed lutowaniem porównaj je
z opisem na płytce. Antena: domyślnie ceramiczna na płytce (`BOARD_USE_EXTERNAL_ANTENNA`).

Pobór prądu w uśpieniu (szacunkowo): przetwornica i XIAO kilkadziesiąt µA, transceiver
w czuwaniu ok. 0,4 mA, dzielnik ok. 0,1 mA — poniżej 1 mA, czyli miesiące na postoju.

## Wgranie firmware

**Bez instalowania czegokolwiek (Chrome/Edge na komputerze):**

1. Odłącz kostkę od auta. Podłącz XIAO kablem USB-C do komputera.
2. Wejdź na https://espressif.github.io/esptool-js/ → **Connect** → wybierz port XIAO.
   Jeśli port się nie pojawia: przytrzymaj przycisk **B** (BOOT), podłącz USB, puść.
3. Adres **0x0**, plik `firmware/prebuilt/dynomic_obd_v0.1.0_full.bin` → **Program**.
4. Po wgraniu naciśnij **R** (RESET). Kostka pojawi się w Bluetooth jako **Dynomic OBD**.

**Z ESP-IDF 5.4 (do rozwijania firmware):**

```
cd hardware/dongle/firmware
idf.py set-target esp32c6
idf.py build flash monitor
```

## Pierwsze uruchomienie

1. Na stole: zasilacz 12 V na pin 16/4 wtyku. Dioda na XIAO zapala się po połączeniu z aplikacją.
2. W aplikacji: Połączenie → Bluetooth LE → Wyszukaj adapter → **Dynomic OBD**.
   Bez auta aplikacja zgłosi, że nie wykryła protokołu — to poprawne.
3. W aucie (zapłon włączony): połączenie, VIN, kody usterek, Rejestrator.
   W „Adapter i możliwości” powinno być „Kostka Dynomic OBD (DX1 v0.1.0)” i „Szybkie zapytania STPX: tak”.

## Testy bez sprzętu

Rdzeń firmware (`firmware/components/elm_core`) to przenośny C. W `host/` jest ten sam kod
skompilowany na PC z symulatorem auta (silnik OBD/UDS, skrzynia, moduł VW TP2.0, ruch w tle),
dostępny przez TCP jak adapter Wi-Fi:

```
make -C hardware/dongle/host && hardware/dongle/host/build/dx_host 35000
```

Test aplikacji z firmware: `flutter test test/dongle_firmware_test.dart`.

## Droga do produktu

- własna płytka w obudowie wtyku OBD (bez modułów), K-Line (L9637D), opcjonalnie CAN-FD,
- parowanie BLE z kodem PIN i szyfrowaniem (dziś każdy w zasięgu może się połączyć),
- aktualizacje firmware przez aplikację (OTA),
- tryb natywny: binarne ramki ze znacznikami czasu zamiast tekstu ELM — kilkukrotnie
  gęstsze logowanie i odczyt bloków TP2.0 na żywo,
- certyfikacja: moduł XIAO ma własne dopuszczenia radiowe, ale gotowy wyrób wymaga oceny
  CE (RED, EMC) — przy własnej płytce z anteną cała procedura.
