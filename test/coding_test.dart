import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/vag_modules.dart';
import 'package:autocheck/services/coding_service.dart';
import 'package:autocheck/services/obd_service.dart';

import 'support/mock_elm327.dart';

/// Kodowanie i adaptacje przez UDS: odczyt, kopia i przywracanie.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockElm327 elm;
  late ObdService obd;

  setUp(() async {
    elm = await MockElm327.start();
    // Zestaw wskaźników (714) i silnik (7E0) z kodowaniem; jedno chronione
    elm.moduleCoding["714"] = {
      "0600": [0x00, 0x00, 0x03, 0x12],
      "F190": "WVGZZZ1TZFW011407".codeUnits,
      "F187": "3AA920870".codeUnits,
    };
    elm.moduleCoding["7E0"] = {
      "0600": [0x01, 0x2A],
    };
    elm.codingSecured.add("0600"); // zapis kodowania wymaga dostępu zabezpieczonego
    obd = ObdService();
    expect(await obd.connectWifi(ip: "127.0.0.1", port: elm.port), isTrue, reason: obd.statusMessage);
  });

  tearDown(() async {
    obd.disconnect();
    await elm.close();
  });

  test('odczyt kodowania i identyfikacji modułu (UDS 22)', () async {
    final r = await obd.readModuleCoding(const VagModule("Zestaw wskaźników", "", "714", "77E"));
    expect(r.responded, isTrue);
    final coding = r.values.firstWhere((v) => v.did == CodingDids.coding);
    expect(coding.readable, isTrue);
    expect(coding.hex, "00 00 03 12");
    final vin = r.values.firstWhere((v) => v.did == CodingDids.vin);
    expect(String.fromCharCodes(vin.bytes!), "WVGZZZ1TZFW011407");
    // Po odczycie kostka wraca do zwykłej pracy (odbiór wszystkich ramek)
    expect(elm.receivedCommands, containsAll(["ATSH714", "1003", "ATCRA", "ATFCSM0"]));
  });

  test('backup, a potem przywracanie — chronione wartości pominięte z powodem', () async {
    final coding = CodingService(obd: obd, persist: false);
    final readings = await coding.read([
      const VagModule("Zestaw wskaźników", "", "714", "77E"),
      const VagModule("Silnik", "", "7E0", "7E8"),
    ]);
    expect(readings.every((m) => m.responded), isTrue);

    // Zbuduj kopię w pamięci (persist=false nie zapisuje pliku)
    final backup = CodingBackup(
      createdAt: DateTime.now(),
      vehicleLabel: "VW Touran",
      vin: "WVGZZZ1TZFW011407",
      modules: {
        for (final r in readings)
          r.module.requestId: [for (final v in r.values.where((v) => v.readable)) CodingBackupEntry(v.did, v.label, v.bytes!)],
      },
    );

    final results = await coding.restore(backup);
    // Kodowanie (0600) chronione → odmowa 0x33; numery/VIN nie są zapisywalne (0600 tylko chronione)
    final codingRes = results.where((r) => r.label == "Kodowanie sterownika");
    expect(codingRes, isNotEmpty);
    expect(codingRes.every((r) => !r.ok && r.nrc == 0x33), isTrue);
    expect(codingRes.first.reason, contains("zabezpieczonego"));

    // VIN da się zapisać z powrotem (nie jest w codingSecured)
    final vinRes = results.firstWhere((r) => r.label == "VIN");
    expect(vinRes.ok, isTrue);
  });

  test('zapis wartości niechronionej faktycznie zmienia moduł', () async {
    final module = const VagModule("Zestaw wskaźników", "", "714", "77E");
    final (ok, nrc) = await obd.writeModuleDid(module, CodingDids.partNumberVag, "3AA920999".codeUnits);
    expect(ok, isTrue, reason: "NRC $nrc");
    expect(String.fromCharCodes(elm.moduleCoding["714"]!["F187"]!), "3AA920999");
  });
}
