import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/obd_pid.dart';
import 'package:autocheck/models/vehicle_info.dart';
import 'package:autocheck/models/extended_pid.dart';
import 'package:autocheck/services/elm_parser.dart';

void main() {
  group('ElmParser — rozdzielanie odpowiedzi sterowników', () {
    test('dwa sterowniki bez błędów NIE dają fikcyjnego kodu C0300', () {
      // Dokładnie ten przypadek dawał wcześniej "C0300": silnik i skrzynia
      // odpowiadają "43 00", a sklejone bajty 43 00 43 00 były dekodowane jako kod.
      const raw = "7E8 02 43 00\n7E9 02 43 00";
      final responses = ElmParser.parse(raw, ObdBusType.can11);
      expect(responses.map((r) => r.ecu), ["7E8", "7E9"]);
      for (final r in responses) {
        expect(ElmParser.decodeDtcs(r.data, isCan: true), isEmpty);
      }
    });

    test('odpowiedź bez nagłówków (ATH0) z dwóch ECU też nie daje fikcyjnego kodu', () {
      final responses = ElmParser.parse("43 00\n43 00", ObdBusType.can11);
      expect(responses.length, 2);
      for (final r in responses) {
        expect(ElmParser.decodeDtcs(r.data, isCan: true), isEmpty);
      }
    });

    test('dekoduje kody DTC z pojedynczej ramki', () {
      final r = ElmParser.parse("7E8 06 43 02 01 33 04 20", ObdBusType.can11).single;
      expect(ElmParser.decodeDtcs(r.data, isCan: true), ["P0133", "P0420"]);
    });

    test('dekoduje kody DTC z wiadomości wieloramkowej (ISO-TP)', () {
      const raw = "7E8 10 0A 43 04 01 33 04 20\n7E8 21 00 87 C1 23 00 00 00";
      final r = ElmParser.parse(raw, ObdBusType.can11).single;
      expect(ElmParser.decodeDtcs(r.data, isCan: true), ["P0133", "P0420", "P0087", "U0123"]);
    });

    test('składa VIN z ramek ISO-TP', () {
      const raw = "7E8 10 14 49 02 01 57 56 47\n"
          "7E8 21 5A 5A 5A 31 54 5A 46\n"
          "7E8 22 57 30 31 31 34 30 37";
      final r = ElmParser.parse(raw, ObdBusType.can11).single;
      expect(r.matches(0x49, [0x02]), isTrue);
      expect(ElmParser.decodeMode09Strings(r.data).single, "WVGZZZ1TZFW011407");
    });

    test('przeplatane ramki dwóch ECU nie mieszają się', () {
      const raw = "7E8 10 17 49 0A 01 45 43 4D\n"
          "7E9 10 17 49 0A 01 54 43 4D\n"
          "7E8 21 00 2D 45 6E 67 69 6E\n"
          "7E9 21 00 2D 54 72 61 6E 73\n"
          "7E8 22 65 43 6F 6E 74 72 6F\n"
          "7E9 22 6D 69 73 43 74 72 6C\n"
          "7E8 23 6C 00 00 00 00 00 00\n"
          "7E9 23 00 00 00 00 00 00 00";
      final rs = ElmParser.parse(raw, ObdBusType.can11);
      expect(rs.length, 2);
      final ecm = ElmParser.decodeMode09Strings(rs.firstWhere((r) => r.ecu == "7E8").data, itemLength: 20);
      final tcm = ElmParser.decodeMode09Strings(rs.firstWhere((r) => r.ecu == "7E9").data, itemLength: 20);
      expect(ecm.single, "ECM-EngineControl");
      expect(tcm.single, "TCM-TransmisCtrl");
    });

    test('maska obsługiwanych PIDów', () {
      final r = ElmParser.parse("7E8 06 41 00 BE 3F A8 13", ObdBusType.can11).single;
      final pids = ElmParser.decodeSupportedPids(r.data);
      expect(pids.contains(0x01), isTrue);
      expect(pids.contains(0x02), isFalse);
      expect(pids.contains(0x0C), isTrue);
      expect(pids.contains(0x20), isTrue);
    });

    test('format bez spacji (ATS0) i komunikat SEARCHING', () {
      final r = ElmParser.parse("SEARCHING...\n7E804410C1AF8", ObdBusType.can11).single;
      expect(r.ecu, "7E8");
      expect(r.data, [0x41, 0x0C, 0x1A, 0xF8]);
    });

    test('NO DATA i błędy magistrali dają pustą listę', () {
      expect(ElmParser.parse("NO DATA", ObdBusType.can11), isEmpty);
      expect(ElmParser.parse("CAN ERROR", ObdBusType.can11), isEmpty);
      expect(ElmParser.parse("", ObdBusType.can11), isEmpty);
    });

    test('CAN 29-bit', () {
      final r = ElmParser.parse("18 DA F1 10 04 41 0C 1A F8", ObdBusType.can29).single;
      expect(r.ecu, "18DAF110");
      expect(r.data, [0x41, 0x0C, 0x1A, 0xF8]);
    });

    test('protokoły legacy (KWP / ISO 9141)', () {
      final r = ElmParser.parse("48 6B 10 41 0C 1A F8 C3", ObdBusType.legacy).single;
      expect(r.ecu, "10");
      expect(r.data, [0x41, 0x0C, 0x1A, 0xF8]);
    });

    test('numer protokołu z ATDPN', () {
      expect(ElmParser.busFromProtocolNumber("A6"), ObdBusType.can11);
      expect(ElmParser.busFromProtocolNumber("7"), ObdBusType.can29);
      expect(ElmParser.busFromProtocolNumber("A5"), ObdBusType.legacy);
    });
  });

  group('Dekodery PIDów', () {
    ObdPid pid(String code) => ObdPid.standardPids.firstWhere((p) => p.code == code);

    test('DPF ΔP (017A) pomija bajt maski i obsługuje znak', () {
      expect(pid("017A").decoder([0x01, 0x00, 0xC8]), closeTo(2.0, 0.001));
      expect(pid("017A").decoder([0x01, 0xFF, 0x38]), closeTo(-2.0, 0.001));
    });

    test('EGT (0178) bierze pierwszy obsługiwany czujnik', () {
      expect(pid("0178").decoder([0x01, 0x10, 0x68, 0, 0, 0, 0, 0, 0]), closeTo(380.0, 0.1));
      expect(pid("0178").decoder([0x02, 0, 0, 0x10, 0x68, 0, 0, 0, 0]), closeTo(380.0, 0.1));
    });

    test('pedał gazu D (0149) jest skalowany do 0-100%', () {
      expect(pid("0149").decoder([38]), closeTo(0.0, 1.0));
      expect(pid("0149").decoder([204]), closeTo(100.0, 1.0));
    });

    test('licznik wypadania zapłonów z Mode 06 (TID 0C = bieżący cykl)', () {
      final mis3 = ObdPid.getByShortName("MIS_3")!;
      expect(mis3.code, "06A4");
      expect(mis3.mode06Mid, 0xA4);
      // Dwa rekordy: TID 0B (średnia 10 cykli) = 2, TID 0C (bieżący cykl) = 7
      final data = [
        0xA4, 0x0B, 0x24, 0x00, 0x02, 0x00, 0x00, 0xFF, 0xFF,
        0xA4, 0x0C, 0x24, 0x00, 0x07, 0x00, 0x00, 0xFF, 0xFF,
      ];
      expect(mis3.decoder(data), 7);
      expect(mis3.decoder(data.sublist(0, 9)), 2);
      expect(mis3.decoder([]).isNaN, isTrue);
    });

    test('brak parametrów bez standardowego PID-u OBD-II', () {
      expect(ObdPid.getByShortName("DPF_SOOT"), isNull);
      for (final p in ObdPid.standardPids) {
        expect(p.mode01Pid != null || p.mode06Mid != null, isTrue, reason: p.code);
      }
    });
  });

  group('Rozpoznawanie pojazdu', () {
    test('VW Touran 1T z 2.0 TDI (03L906023PJ)', () {
      final v = VehicleInfo.decodeFromRawData(rawVin: "WVGZZZ1TZFW011407", rawCalId: "03L906023PJ");
      expect(v.manufacturer, "Volkswagen");
      expect(v.modelName, "Touran (1T)");
      expect(v.year, "2015");
      expect(v.profile, VehicleProfile.vag);
      expect(v.isDiesel, isTrue);
      expect(v.engineDescription, contains("EA189"));
    });

    test('typ paliwa z PID 0151 ma pierwszeństwo', () {
      final v = VehicleInfo.decodeFromRawData(rawVin: "WVWZZZ1KZ8W000001", fuelType: FuelType.petrol);
      expect(v.fuelType, FuelType.petrol);
      expect(v.modelName, "Golf V / Jetta (1K)");
    });
  });
}
