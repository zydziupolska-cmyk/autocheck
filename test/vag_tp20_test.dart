import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/dtc_code.dart';
import 'package:autocheck/models/obd_pid.dart';
import 'package:autocheck/services/obd_service.dart';
import 'package:autocheck/services/vag_tp20.dart';

import 'support/mock_elm327.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    DtcCode.loadDescriptions(File("assets/dtc/obd_descriptions_en.json").readAsStringSync());
    DtcCode.loadVagDescriptions(File("assets/dtc/vag_fault_codes_en.json").readAsStringSync());
  });

  test('kody VAG 16384+ to zakodowane kody P', () {
    expect(Tp20Client.vagToObdCode(16684), "P0300");
    expect(Tp20Client.vagToObdCode(17978), "P1570");
    expect(Tp20Client.vagToObdCode(16989), "P0605");
    expect(Tp20Client.vagToObdCode(532), isNull);
  });

  test('opisy 5-cyfrowych kodów VAG', () {
    expect(DtcCode.fromVagFault(532).title, "Supply Voltage B+");
    expect(DtcCode.fromVagFault(588).title, contains("Airbag Igniter"));
    final p = DtcCode.fromVagFault(16684, obdCode: "P0300");
    expect(p.code, "16684 / P0300");
    expect(p.title, contains("zapłon"));
  });

  test('ramki z nagłówkami (ze spacjami i bez)', () {
    final f = Tp20Client.parseFrames("300 A1 0F 8A FF 4A FF\r3001000045850\r201 00 D0 00 03 40 07 01");
    expect(f.first.id, 0x300);
    expect(f.first.data, [0xA1, 0x0F, 0x8A, 0xFF, 0x4A, 0xFF]);
    expect(f.last.id, 0x201);
  });

  test('skan TP2.0: silnik, ABS (długa odpowiedź z ACK w trakcie), poduszki („czekaj”); potem normalna praca', () async {
    final car = await MockElm327.start(resetsFormattingOnProtocol: true);
    car.tp20Modules[0x01] = [(16684, 0x23), (532, 0x21)];
    car.tp20Modules[0x03] = [for (int i = 0; i < 10; i++) (1276 + i, 0x27)];
    car.tp20Modules[0x15] = [(588, 0x24)];
    car.tp20SlowModules.add(0x15);
    final obd = ObdService();
    addTearDown(() async {
      obd.disconnect();
      await car.close();
    });
    expect(await obd.connectWifi(ip: "127.0.0.1", port: car.port), isTrue, reason: obd.statusMessage);

    final progress = <String>[];
    final results = await obd.scanVagTp20Modules(onProgress: (d, t, name) => progress.add(name));
    final responded = {for (final r in results.where((r) => r.responded)) r.module.name: r};
    expect(responded.keys.toSet(), {"Silnik", "ABS / ESP", "Poduszki powietrzne"});
    expect(results.length, greaterThan(20));

    final engine = responded["Silnik"]!;
    expect(engine.dtcs.map((d) => d.code), ["16684 / P0300", "00532"]);
    expect(engine.dtcs[1].title, "Supply Voltage B+");
    expect(engine.identification, contains("03L906023PJ"));

    expect(responded["ABS / ESP"]!.dtcs, hasLength(10));
    expect(responded["ABS / ESP"]!.dtcs.first.code, "01276");
    expect(responded["Poduszki powietrzne"]!.dtcs.single.title, contains("Airbag Igniter"));

    // Adapter wrócił do normalnej pracy (protokół 6, nagłówki włączone mimo resetu formatowania)
    expect(car.receivedCommands, containsAll(["ATPBC001", "ATSPB", "ATSP6", "ATST32"]));
    expect(await obd.readPid(ObdPid.getByShortName("RPM")!), closeTo(850, 0.01));
    expect(await obd.readDtcCodes(), isEmpty);
  });
}
