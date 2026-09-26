import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/models/vehicle_info.dart';
import 'package:autocheck/models/vin_decoder.dart';
import 'package:autocheck/services/datalogger_service.dart';
import 'package:autocheck/services/engine_memory.dart';
import 'package:autocheck/services/obd_service.dart';
import 'package:autocheck/services/vin_scan.dart';

// Peugeot 307 2.0 16V (typ silnika RFN) — przykładowy VIN o poprawnej budowie
const vin307 = "VF33HRFNC84512345";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("Wyciąganie VIN ze zdjęcia (OCR)", () {
    test("dowód rejestracyjny: pole E z odstępami i szumem wokół", () {
      const text = "REPUBLIKA POLSKA\nDOWÓD REJESTRACYJNY\nA WX 12345\nD.1 PEUGEOT\nE VF3 3HRFN C8451 2345\nP.1 1997";
      expect(VinExtractor.fromText(text).first, vin307);
    });

    test("pomylone przez OCR litery I/O są poprawiane", () {
      expect(VinExtractor.fromText("VF33HRFNC845I234S".replaceAll("S", "5")).first, vin307);
      expect(VinExtractor.fromText("VF33HRFNC84512345").first, vin307);
    });

    test("same cyfry (PESEL, numery) nie są VIN-em", () {
      expect(VinExtractor.fromText("12345678901234567\n98765432109876543"), isEmpty);
    });

    test("kod kreskowy Code 39 z prefiksem I", () {
      expect(VinExtractor.fromBarcode("I$vin307"), vin307);
      expect(VinExtractor.fromBarcode(vin307), vin307);
      expect(VinExtractor.fromBarcode("ABC"), isNull);
    });
  });

  group("Dekodowanie i walidacja VIN", () {
    test("napis zastępczy nie jest VIN-em (koniec z „BRAKVN”)", () {
      final v = VehicleInfo.decodeFromRawData(rawVin: "BRAK-VIN");
      expect(v.vin, isEmpty);
      expect(v.hasVin, isFalse);
      expect(v.label, "Pojazd");
    });

    test("Peugeot 307: model i silnik EW10 z VIN, benzyna", () {
      final v = VehicleInfo.decodeFromRawData(rawVin: vin307);
      expect(v.manufacturer, "Peugeot");
      expect(v.modelName, "307");
      expect(v.engineDescription, contains("EW10"));
      expect(v.engineDescription, contains("RFN"));
      expect(v.fuelType, FuelType.petrol);
      expect(v.label, "Peugeot 307 • $vin307");
      expect(VinDecoder.psaEngineType(vin307), "RFN");
    });

    test("ręczny VIN zachowuje dane sterownika", () {
      final base = VehicleInfo.decodeFromRawData(rawVin: "", rawCalId: "9655555580", rawEcuName: "SAGEM S2000");
      final withVin = base.applyVin(vin307);
      expect(withVin.vin, vin307);
      expect(withVin.calibrationId, "9655555580");
      expect(withVin.ecuName, "SAGEM S2000");
    });

    test("rozpoznanie silnika z VIN PSA z wysoką pewnością", () {
      final m = EngineMemory(persist: false).resolveFor(vin307, "");
      expect(m, isNotNull);
      expect(m!.profile.code, "EW10");
      expect(m.basis, contains("RFN"));
    });
  });

  test("VIN dopisany do zapisanego logu aktualizuje etykietę", () async {
    final logger = DataloggerService(obdService: ObdService(), persistHistory: false);
    final s = LogSession(
      id: "p307",
      title: "Jazda",
      createdAt: DateTime(2026, 9, 26),
      activePidKeys: const ["RPM"],
      points: [for (int i = 0; i < 10; i++) LogPoint(timeMs: i * 500.0, values: {"RPM": 800})],
    );
    logger.selectSession(s);
    await logger.setSessionVin(s, vin307);
    expect(logger.activeSession!.vin, vin307);
    expect(logger.activeSession!.vehicleLabel, "Peugeot 307 • $vin307");
  });
}
