import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/dtc_code.dart';
import 'package:autocheck/models/extended_pid.dart';
import 'package:autocheck/models/obd_pid.dart';
import 'package:autocheck/models/vag_modules.dart';
import 'package:autocheck/services/elm_parser.dart';
import 'package:autocheck/services/obd_service.dart';

import 'support/mock_elm327.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Opisy kodów błędów', () {
    setUpAll(() => DtcCode.loadDescriptions(File("assets/dtc/obd_descriptions_en.json").readAsStringSync()));

    test('wczytano ok. 4500 opisów', () {
      expect(DtcCode.descriptionCount, greaterThan(4000));
    });

    test('polska baza z przyczynami ma pierwszeństwo', () {
      expect(DtcCode.getByCode("P0087").title, startsWith("Ciśnienie paliwa"));
    });

    test('kod producenta (P1xxx): opis VAG tylko w aucie VAG', () {
      expect(DtcCode.getByCode("P1136", profile: VehicleProfile.vag).title, contains("Fuel Trim"));
      final other = DtcCode.getByCode("P1136", profile: VehicleProfile.generic);
      expect(other.title, "Kod błędu OBD-II P1136");
      expect(other.description, contains("kod producenta"));
    });

    test('kod standardowy w innej marce — bez numerów części VAG', () {
      final vag = DtcCode.getByCode("P0016", profile: VehicleProfile.vag).title;
      final other = DtcCode.getByCode("P0016", profile: VehicleProfile.generic).title;
      expect(vag, contains("G28"));
      expect(other, isNot(contains("G28")));
      expect(other, contains("Incorrect Correlation"));
    });

    test('U0100 — komunikacja', () {
      expect(DtcCode.getByCode("U0100").title, contains("No Communication"));
    });
  });

  test('tabela modułów VAG: silnik, skrzynia, ABS, poduszki; adresy unikalne', () {
    final byReq = {for (final m in VagModule.all) m.requestId: m};
    expect(byReq.length, VagModule.all.length);
    expect(byReq["7E0"]!.responseId, "7E8");
    expect(byReq["713"]!.name, "ABS / ESP");
    expect(byReq["715"]!.name, "Poduszki powietrzne");
    expect(VagModule.all.length, greaterThan(80));
  });

  test('dekodowanie odpowiedzi UDS 19 02 (z odpowiedzią „czekaj” 7F 19 78)', () {
    final codes = ElmParser.decodeUdsDtcs([
      0x7F, 0x19, 0x78,
      0x59, 0x02, 0xFF,
      0x00, 0x87, 0x00, 0x08, // P0087 potwierdzony
      0x50, 0x71, 0x29, 0x04, // C1071 oczekujący
      0x01, 0x23, 0x00, 0x40, // tylko historia — pomijany
    ]);
    expect(codes.map((c) => c.$1), ["P0087", "C1071"]);
    expect(codes[0].$3, isFalse);
    expect(codes[1].$3, isTrue);
    expect(codes[1].$2, 0x29);
  });

  test('skan wszystkich modułów VAG: kody z silnika, ABS; poduszki bez błędów; potem normalna praca', () async {
    final car = await MockElm327.start();
    car.engineDtcs = [
      [0x00, 0x87],
    ];
    car.vagModules["713"] = ("77D", [
      [0x50, 0x71, 0x29, 0x08], // C1071
      [0xC1, 0x00, 0x00, 0x08], // U0100
    ]);
    car.vagModules["715"] = ("77F", []);
    final obd = ObdService();
    addTearDown(() async {
      obd.disconnect();
      await car.close();
    });
    expect(await obd.connectWifi(ip: "127.0.0.1", port: car.port), isTrue);
    expect(obd.canScanVagModules, isTrue);

    final progress = <String>[];
    final results = await obd.scanVagModules(onProgress: (d, t, m) => progress.add(m.name));
    expect(progress, isNotEmpty);
    final responded = {for (final r in results.where((r) => r.responded)) r.module.name: r};
    expect(responded.keys, containsAll(["Silnik", "ABS / ESP", "Poduszki powietrzne"]));
    expect(responded["Silnik"]!.dtcs.map((d) => d.code), ["P0087"]);
    expect(responded["ABS / ESP"]!.dtcs.map((d) => d.code), ["C1071", "U0100"]);
    expect(responded["ABS / ESP"]!.dtcs.first.ecuLabel, contains("ABS / ESP (713)"));
    expect(responded["Poduszki powietrzne"]!.dtcs, isEmpty);
    expect(car.receivedCommands, containsAll(["ATSH713", "ATCRA77D", "ATFCSH713", "ATCRA", "ATFCSM0"]));

    // Po skanie zwykłe odczyty działają (nagłówek i filtr przywrócone)
    expect(await obd.readPid(ObdPid.getByShortName("RPM")!), closeTo(850, 0.01));
  });
}
