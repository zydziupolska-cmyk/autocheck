# AutoCheck

Aplikacja Flutter (Android) do diagnostyki samochodu przez OBD-II i adapter ELM327 / STN
(vLinker MC+): odczyt i kasowanie kodów błędów, identyfikacja pojazdu (VIN, sterownik),
rejestrator parametrów na żywo, wykresy oraz regułowa analiza usterek (doładowanie, DPF,
mieszanka, zapłon, bieg jałowy). Zawiera wbudowany symulator do testów bez samochodu.

## Połączenie z adapterem

Obsługiwane: BLE (vLinker MC+ / klony FFE0, FFF0), Classic Bluetooth (SPP, urządzenia
sparowane w systemie) oraz Wi-Fi (`192.168.0.10:35000`).

Inicjalizacja (`lib/services/obd_service.dart`):

1. `ATZ, ATE0, ATL0, ATS1, ATH1, ATAT1, ATSP0` — nagłówki CAN są **włączone**, dzięki czemu
   każdą odpowiedź przypisujemy do konkretnego sterownika (silnik 7E8, skrzynia 7E9 …).
2. `0100` wykrywa protokół, `ATDPN` określa typ magistrali (CAN 11/29-bit lub legacy).
3. Wybierany jest sterownik silnika (ten, który obsługuje RPM), a dalsze zapytania o czujniki
   idą do niego fizycznie (`ATSH 7E0`). Kody błędów czytane są ze wszystkich sterowników (`7DF`).
4. Maska obsługiwanych PID-ów (`0100/0120/0140/...`) decyduje, które czujniki są dostępne.
5. Każda odpowiedź jest weryfikowana (usługa + numer PID); nieudany odczyt to brak wartości,
   a nie 0.

Parser odpowiedzi (ISO-TP, CAN 11/29-bit, KWP/ISO 9141) jest w `lib/services/elm_parser.dart`.

## Testy

```bash
flutter test
```

`test/support/mock_elm327.dart` to emulator adaptera ELM327 na TCP udający VW Touran 2.0 TDI
z dwoma sterownikami na CAN — `test/obd_service_test.dart` sprawdza na nim cały proces
połączenia, odczyt VIN, kodów błędów i czujników.
