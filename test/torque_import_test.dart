import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/extended_pid.dart';
import 'package:autocheck/models/log_point.dart';
import 'package:autocheck/models/torque_csv.dart';
import 'package:autocheck/services/anomaly_engine.dart';
import 'package:autocheck/services/obd_service.dart';
import 'package:autocheck/services/pid_definitions_store.dart';
import 'package:autocheck/services/torque_equation.dart';

import 'support/mock_elm327.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Równania Torque', () {
    double eval(String eq, List<int> b) => TorqueEquation.parse(eq).evaluate(b);

    test('zmienne, arytmetyka, wielkość liter', () {
      expect(eval("(A*256+B)/4", [0x1A, 0xF8]), 1726);
      expect(eval("(a*256+b)/4", [0x1A, 0xF8]), 1726);
      expect(eval("(G/2)-40", [0, 0, 0, 0, 0, 0, 150]), 35);
    });

    test('SIGNED, przesunięcia bitowe, bity, zmienne dwuliterowe, MAX', () {
      final b = List<int>.generate(40, (i) => i);
      b[22] = 0xFF; // W
      b[21] = 0x38; // V
      expect(eval("(SIGNED(W)*256+V)/1000", b), closeTo(-0.2, 1e-9));
      b[5] = 0x01; // F
      b[6] = 0x2C; // G
      expect(eval("((f<8)+g)/100", b), closeTo(3.0, 1e-9));
      expect(eval("{g:2}", b), 1);
      b[29] = 123; // AD
      expect(eval("ad*0.1", b), closeTo(12.3, 1e-9));
      b[31] = 250; // AF
      expect(eval("(MAX(0:64*(0.8-(af/200)))/45)*60", b), 0);
    });

    test('INT16/INT32 ze znakiem i BIT()', () {
      expect(eval("Int16(a:b)/10", [0xFF, 0x38]), closeTo(-20.0, 1e-9));
      expect(eval("INT32(A:B:C:D)", [0x00, 0x01, 0x00, 0x00]), 65536);
      expect(eval("(Bit(a:5) -1) * -1", [0x20]), 0);
      expect(eval("(Bit(a:5) -1) * -1", [0x00]), 1);
    });

    test('literówka z nadmiarowym nawiasem (jak w plikach społeczności)', () {
      final b = List<int>.filled(60, 0);
      b[55] = 0x01; // BD
      b[56] = 0x02; // BE
      expect(eval("(Signed(BD)*256))+BE", b), 258);
    });

    test('brakujące bajty = brak wartości, a nie 0', () {
      expect(eval("A*256+B", [1]).isNaN, isTrue);
    });

    test('odwołania val{} i nieznane funkcje są odrzucane', () {
      expect(() => TorqueEquation.parse("val{000_Battery DC Voltage}/96"), throwsA(isA<TorqueEquationException>()));
      expect(() => TorqueEquation.parse("FOO(A)"), throwsA(isA<TorqueEquationException>()));
    });
  });

  test('wszystkie pliki Torque z repozytorium dają się zaimportować', () {
    final files = Directory("scratch_ev_pids").listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith(".csv"));
    int total = 0;
    for (final f in files) {
      final r = TorqueCsvImporter.parse(f.readAsStringSync(), sourceName: f.path);
      // Pomijane mogą być tylko pola wyliczane z innych parametrów (val{...})
      for (final s in r.skipped) {
        expect(s, contains("val{"), reason: "${f.path}: $s");
      }
      total += r.pids.length;
    }
    expect(total, greaterThan(300));
  });

  group('Rozpoznawanie parametrów po nazwie', () {
    ExtendedPid one(String line) => TorqueCsvImporter.parse(line).pids.single;

    test('doładowanie zadane i rzeczywiste', () {
      expect(one("Charge pressure specified,Boost tgt,22202A,(A*256+B)*0.1,0,3000,hPa,7E0").shortName, "TARGET_BOOST");
      expect(one("Charge pressure actual,Boost,22202B,(A*256+B)*0.1,0,3000,hPa,7E0").shortName, "BOOST");
      expect(one("Ladedruck Sollwert,LD soll,22202C,A,0,255,mbar,7E0").shortName, "TARGET_BOOST");
    });

    test('korekty wtryskiwaczy i stuk na cylinder', () {
      expect(one("Injector correction cyl 1,Inj1,221234,SIGNED(A)/10,-5,5,mg/str,7E0").shortName, "INJ_CORR_1");
      expect(one("Laufruhe Zyl. 2,LR2,221235,SIGNED(A)/10,-5,5,mg/H,7E0").shortName, "INJ_CORR_2");
      expect(one("Timing correction cyl 3,TC3,22200C,SIGNED(A)/10,-10,0,deg,7E0").shortName, "KNOCK_3");
    });

    test('jednostki: szyna w kPa → bar, EGT w °F → °C, DPF w mbar → kPa', () {
      final rail = one("Fuel rail pressure actual,Rail,22F423,(A*256+B)*10,0,200000,kPa,7E0");
      expect(rail.shortName, "F_RAIL");
      expect(rail.decoder([0x0F, 0xA0]) * rail.scale + rail.offset, closeTo(400, 0.01)); // 40000 kPa
      final egt = one("Exhaust gas temperature,EGT,221111,A*4,0,2000,F,7E0");
      expect(egt.decoder([100]) * egt.scale + egt.offset, closeTo((400 - 32) * 5 / 9, 0.01));
      final dp = one("DPF differential pressure,DPF dP,221112,A*10,0,1000,mbar,7E0");
      expect(dp.shortName, "DPF_DP");
      expect(dp.decoder([25]) * dp.scale, closeTo(25, 0.01));
    });

    test('nierozpoznane parametry pod własną nazwą', () {
      expect(one("Outdoor Temperature,Outdoor Temperature,220100,(G/2)-40,-50,50,degC,7B3").shortName, "U_OUTDOOR_TEMPERATURE");
    });
  });

  test('import → połączenie → auto odpowiada na korekty wtryskiwaczy → Asystent wskazuje cylinder 3', () async {
    final car = await MockElm327.start(petrol: true);
    // Korekty 4 wtryskiwaczy w jednej odpowiedzi UDS (DID 1234), wartości ze znakiem / 10
    car.udsDids["1234"] = [0x02, 0xFE, 0xB0, 0x01]; // +0.2, -0.2, -8.0, +0.1
    final obd = ObdService();
    final store = PidDefinitionsStore(obd: obd, persist: false);
    addTearDown(() async {
      obd.disconnect();
      await car.close();
    });

    await store.importCsv("moje_auto.csv", """
Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header
Injector correction cyl 1,Inj1,0x221234,SIGNED(A)/10,-10,10,mg/str,7E0
Injector correction cyl 2,Inj2,0x221234,SIGNED(B)/10,-10,10,mg/str,7E0
Injector correction cyl 3,Inj3,0x221234,SIGNED(C)/10,-10,10,mg/str,7E0
Injector correction cyl 4,Inj4,0x221234,SIGNED(D)/10,-10,10,mg/str,7E0
Parametr którego auto nie ma,Brak,0x229999,A,0,100,%,7E0
""");
    expect(obd.importedPids, hasLength(5));

    expect(await obd.connectWifi(ip: "127.0.0.1", port: car.port), isTrue, reason: obd.statusMessage);
    final keys = obd.discoveredPids.map((p) => p.shortName).toSet();
    expect(keys, containsAll(["INJ_CORR_1", "INJ_CORR_2", "INJ_CORR_3", "INJ_CORR_4"]));
    expect(keys, isNot(contains("U_BRAK")));

    // Cztery kanały z jednej odpowiedzi = jedno zapytanie
    final pids = obd.discoveredPids.where((p) => p.shortName.startsWith("INJ_CORR_")).toList();
    final before = car.receivedCommands.length;
    final v = await obd.readPids(pids);
    expect(car.receivedCommands.sublist(before).where((c) => c.startsWith("221234")), hasLength(1));
    expect(v["INJ_CORR_3"], closeTo(-8.0, 1e-9));
    expect(v["INJ_CORR_1"], closeTo(0.2, 1e-9));

    // Wolne obroty z lejącym wtryskiem: niskie ciśnienie, bogata mieszanka, korekta cyl. 3 odstaje
    final pts = [
      for (int i = 0; i < 100; i++)
        LogPoint(timeMs: i * 200.0, values: {
          "RPM": 780 + (i % 5) * 10.0, "SPEED": 0, "PEDAL": 0, "F_RAIL": 19, "STFT": -13, "LTFT": -8, ...v,
        }),
      for (int i = 0; i < 20; i++)
        LogPoint(timeMs: 20000 + i * 200.0, values: {
          "RPM": 2500 + i * 100.0, "SPEED": 60, "PEDAL": 100, "F_RAIL": 150, "STFT": 0, "LTFT": -8, ...v,
        }),
    ];
    final rail = AnomalyEngine.analyzeSession(pts).firstWhere((a) => a.paramKey == "F_RAIL");
    expect(rail.id, startsWith("rail_low_idle_cyl3_"));
    expect(rail.plainSummary, contains("Korekta wtryskiwacza cylindra 3 wyraźnie odstaje"));
  });

  test('korekta jednego wtryskiwacza odstaje, ale bez innych objawów — ostrzeżenie', () {
    final pts = [
      for (int i = 0; i < 60; i++)
        LogPoint(timeMs: i * 200.0, values: {
          "RPM": 800, "SPEED": 0, "PEDAL": 0, "F_RAIL": 42,
          "INJ_CORR_1": 0.1, "INJ_CORR_2": -0.2, "INJ_CORR_3": 0.0, "INJ_CORR_4": 2.4,
        }),
    ];
    final a = AnomalyEngine.analyzeSession(pts).single;
    expect(a.id, startsWith("inj_outlier_cyl4_"));
    expect(a.severity.name, "warning");
  });
}
