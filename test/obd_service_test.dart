import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/obd_pid.dart';
import 'package:autocheck/services/datalogger_service.dart';
import 'package:autocheck/services/obd_service.dart';
import 'package:autocheck/models/extended_pid.dart';
import 'package:autocheck/models/log_point.dart';

import 'support/mock_elm327.dart';

/// Test end-to-end: ObdService łączy się przez Wi-Fi (TCP) z emulatorem ELM327,
/// który zachowuje się jak VW Touran 2.0 TDI z dwoma sterownikami na CAN.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockElm327 elm;
  late ObdService obd;

  setUp(() async {
    elm = await MockElm327.start();
    obd = ObdService();
  });

  tearDown(() async {
    obd.disconnect();
    await elm.close();
  });

  Future<void> connect() async {
    final ok = await obd.connectWifi(ip: "127.0.0.1", port: elm.port);
    expect(ok, isTrue, reason: obd.statusMessage);
    expect(obd.status, ObdConnectionStatus.connected);
  }

  test('inicjalizacja wybiera ECU silnika i włącza nagłówki', () async {
    await connect();
    expect(obd.engineEcuAddress, "7E8");
    expect(elm.receivedCommands, contains("ATH1"));
    // Po wykryciu ECU zapytania idą fizycznie do silnika
    expect(elm.receivedCommands, contains("ATSH7E0"));
  });

  test('dane pojazdu pochodzą tylko ze sterownika silnika', () async {
    await connect();
    final v = obd.vehicleInfo!;
    expect(v.vin, MockElm327.vin);
    expect(v.modelName, "Touran (1T)");
    expect(v.isDiesel, isTrue);
    expect(v.ecuName, "ECM-EngineControl");
    expect(v.calibrationId, "03L906023PJ");
    expect(v.distanceSinceDtcClearedKm, 1234);
    expect(v.batteryVoltage, closeTo(14.5, 0.01));
  });

  test('brak błędów w obu sterownikach = pusta lista (bez fikcyjnego C0300)', () async {
    await connect();
    final codes = await obd.readDtcCodes();
    expect(codes, isNotNull);
    expect(codes, isEmpty);
  });

  test('prawdziwy kod błędu jest przypisany do sterownika silnika', () async {
    elm.engineDtcs = [
      [0x00, 0x87],
    ];
    await connect();
    final codes = (await obd.readDtcCodes())!;
    expect(codes.map((c) => c.code), ["P0087"]);
    expect(codes.single.ecuLabel, "Silnik (7E8)");
    expect(codes.single.pending, isFalse);

    expect(await obd.clearDtcCodes(), isTrue);
    expect(await obd.readDtcCodes(), isEmpty);
  });

  test('lista czujników zawiera tylko PIDy obsługiwane przez ECU', () async {
    await connect();
    final keys = obd.discoveredPids.map((p) => p.shortName).toSet();
    expect(keys, containsAll(["RPM", "BOOST", "MAF", "PEDAL", "ECT", "IAT", "SPEED", "EGT", "DPF_DP", "F_RAIL"]));
    // Diesel: brak kąta zapłonu, AFR, korekt, symulowanych liczników
    expect(keys, isNot(contains("IGN")));
    expect(keys, isNot(contains("AFR")));
    expect(keys, isNot(contains("MIS_1")));
    expect(keys, isNot(contains("DPF_SOOT")));
    // Pedał — wariant 0149, bo ECU nie obsługuje 015A
    expect(obd.discoveredPids.firstWhere((p) => p.shortName == "PEDAL").code, "0149");
  });

  test('odczyty czujników są poprawnie dekodowane', () async {
    await connect();
    ObdPid pid(String k) => obd.discoveredPids.firstWhere((p) => p.shortName == k);

    expect(await obd.readPid(pid("RPM")), closeTo(850, 0.01));
    // MAP 101 kPa, ciśnienie atmosferyczne 99 kPa → +0.02 bar
    expect(await obd.readPid(pid("BOOST")), closeTo(0.02, 0.001));
    expect(await obd.readPid(pid("ECT")), 90);
    // Szyna z PID 6D: zadane i rzeczywiste z jednego zapytania
    expect(await obd.readPid(pid("F_RAIL")), closeTo(298, 0.01));
    expect(await obd.readPid(pid("RAIL_TGT")), closeTo(300, 0.01));
    expect(await obd.readPid(pid("EGT")), closeTo(380, 0.1));
    expect(await obd.readPid(pid("DPF_DP")), closeTo(2.0, 0.001));

    elm.rpm = 2500;
    expect(await obd.readPid(pid("RPM")), closeTo(2500, 0.01));

    // Adapter obsługuje liczbę odpowiedzi — szybkie zapytania "010C1"
    expect(elm.receivedCommands, contains("010C1"));
  });

  test('czujnik nieobsługiwany przez ECU zwraca null, a nie 0', () async {
    await connect();
    final ign = ObdPid.getByShortName("IGN")!;
    expect(await obd.readPid(ign), isNull);
  });

  test('równoległe komendy nie mieszają odpowiedzi', () async {
    await connect();
    ObdPid pid(String k) => obd.discoveredPids.firstWhere((p) => p.shortName == k);
    final results = await Future.wait([
      obd.readPid(pid("RPM")),
      obd.readDtcCodes(),
      obd.readPid(pid("ECT")),
      obd.readPid(pid("RPM")),
    ]);
    expect(results[0], closeTo(850, 0.01));
    expect(results[1], isEmpty);
    expect(results[2], 90);
    expect(results[3], closeTo(850, 0.01));
  });

  test('rejestrator dopasowuje czujniki do diesla i zbiera prawdziwe próbki', () async {
    final logger = DataloggerService(obdService: obd, persistHistory: false);
    await connect();

    expect(logger.selectedPidKeys, contains("PEDAL"));
    expect(logger.selectedPidKeys, isNot(contains("IGN")));
    expect(logger.selectedPidKeys, isNot(contains("AFR")));

    logger.startRecording();
    await Future.delayed(const Duration(milliseconds: 800));
    logger.stopRecording();

    expect(logger.currentPoints, isNotEmpty);
    for (final p in logger.currentPoints) {
      expect(p.values["RPM"], closeTo(850, 0.01));
      expect(p.values.containsKey("IGN"), isFalse);
    }
    final session = logger.activeSession!;
    expect(session.isDiesel, isTrue);
    expect(session.vehicleLabel, contains(MockElm327.vin));
    // Log na postoju nie może generować fałszywych usterek
    expect(logger.detectedAnomalies, isEmpty);
  });

  test('brak odpowiedzi auta (zapłon wyłączony) = czytelny błąd', () async {
    elm.ignitionOff = true;
    final ok = await obd.connectWifi(ip: "127.0.0.1", port: elm.port);
    expect(ok, isFalse);
    expect(obd.status, ObdConnectionStatus.error);
    expect(obd.statusMessage, contains("Włącz zapłon"));
  });

  group('inne samochody', () {
    Future<(MockElm327, ObdService)> connectTo(MockBus bus, {bool petrol = false}) async {
      final car = await MockElm327.start(bus: bus, petrol: petrol);
      final service = ObdService();
      addTearDown(() async {
        service.disconnect();
        await car.close();
      });
      final ok = await service.connectWifi(ip: "127.0.0.1", port: car.port);
      expect(ok, isTrue, reason: service.statusMessage);
      return (car, service);
    }

    test('benzyna: korekty, zapłon i liczniki wypadania zapłonów z Mode 06', () async {
      final (car, service) = await connectTo(MockBus.can11, petrol: true);
      expect(service.vehicleInfo!.isDiesel, isFalse);
      final keys = service.discoveredPids.map((p) => p.shortName).toSet();
      expect(keys, containsAll(["IGN", "STFT", "LTFT", "MIS_1", "MIS_2", "MIS_3", "MIS_4"]));

      ObdPid pid(String k) => service.discoveredPids.firstWhere((p) => p.shortName == k);
      expect(await service.readPid(pid("IGN")), closeTo(11.0, 0.01));
      expect(await service.readPid(pid("LTFT")), closeTo(3.9, 0.1));
      expect(await service.readPid(pid("MIS_3")), 0);
      car.misfireCyl3 = 12;
      expect(await service.readPid(pid("MIS_3")), 12);
      expect(await service.readPid(pid("MIS_1")), 0);
    });

    test('diesel nie ma liczników wypadania zapłonów (brak Mode 06 MID A2+)', () async {
      final (_, service) = await connectTo(MockBus.can11);
      expect(service.discoveredPids.map((p) => p.shortName), isNot(contains("MIS_1")));
    });

    test('CAN 29-bit: dwa sterowniki, adresowanie fizyczne, VIN i brak fikcyjnych kodów', () async {
      final (car, service) = await connectTo(MockBus.can29);
      expect(service.engineEcuAddress, "18DAF110");
      expect(service.vehicleInfo!.vin, MockElm327.vin);
      expect(service.vehicleInfo!.ecuName, "ECM-EngineControl");
      expect(car.receivedCommands, containsAll(["ATCP18", "ATSHDA10F1"]));
      expect(await service.readDtcCodes(), isEmpty);
      expect(await service.readPid(ObdPid.getByShortName("RPM")!), closeTo(850, 0.01));
    });

    test('KWP2000: VIN z wielu linii, kody błędów bez licznika', () async {
      final car = await MockElm327.start(bus: MockBus.kwp);
      car.engineDtcs = [
        [0x01, 0x33],
        [0x04, 0x20],
      ];
      final service = ObdService();
      addTearDown(() async {
        service.disconnect();
        await car.close();
      });
      expect(await service.connectWifi(ip: "127.0.0.1", port: car.port), isTrue, reason: service.statusMessage);

      expect(service.engineEcuAddress, "10");
      expect(service.vehicleInfo!.vin, MockElm327.vin);
      final codes = (await service.readDtcCodes())!;
      expect(codes.map((c) => c.code), ["P0133", "P0420"]);
      expect(await service.readPid(ObdPid.getByShortName("RPM")!), closeTo(850, 0.01));
      // Bez ISO-TP nie ma adresowania fizycznego ani skróconego oczekiwania
      expect(car.receivedCommands.where((c) => c.startsWith("ATSH")), isEmpty);
    });
  });

  group('parametry zadane i rzeczywiste', () {
    test('diesel: zadane i rzeczywiste doładowanie z PID 70 — jedno zapytanie na oba kanały', () async {
      await connect();
      final keys = obd.discoveredPids.map((p) => p.shortName).toSet();
      expect(keys, containsAll(["BOOST", "TARGET_BOOST", "RAIL_TGT", "VGT_CMD", "VGT_ACT", "EGR_CMD", "EGR_ACT", "EXH_P", "TQ_DEMAND", "TQ_ACT"]));
      expect(obd.discoveredPids.firstWhere((p) => p.shortName == "BOOST").code, "0170");

      elm.targetKpa = 239; // 1.40 bar nad atmosferą (99 kPa)
      elm.mapKpa = 159; // 0.60 bar
      final before = elm.receivedCommands.where((c) => c.startsWith("0170")).length;
      final values = await obd.readPids(obd.discoveredPids.where((p) => p.code == "0170").toList());
      expect(values["TARGET_BOOST"], closeTo(1.40, 0.01));
      expect(values["BOOST"], closeTo(0.60, 0.01));
      expect(elm.receivedCommands.where((c) => c.startsWith("0170")).length - before, 1);
    });

    test('benzyna VAG: zadane doładowanie z UDS (DID 2029) z automatycznym wykryciem jednostki hPa', () async {
      final car = await MockElm327.start(petrol: true);
      final service = ObdService();
      addTearDown(() async {
        service.disconnect();
        await car.close();
      });
      expect(await service.connectWifi(ip: "127.0.0.1", port: car.port), isTrue, reason: service.statusMessage);

      final target = service.discoveredPids.firstWhere((p) => p.shortName == "TARGET_BOOST");
      expect(target, isA<ExtendedPid>());
      expect((target as ExtendedPid).requestCommand, "222029");
      // Rzeczywiste doładowanie ze standardowego PID (standard ma pierwszeństwo przed UDS)
      expect(service.discoveredPids.firstWhere((p) => p.shortName == "BOOST").code, "010B");

      car.targetKpa = 199; // 1.00 bar nad atmosferą
      expect(await service.readPid(target), closeTo(1.0, 0.02));
    });

    test('PID 4F: rozszerzony zakres MAP (0B przeskalowany) — doładowanie powyżej 1,55 bar', () async {
      final car = await MockElm327.start(petrol: true);
      car.mapRangeTens = 30; // zakres 300 kPa
      final service = ObdService();
      addTearDown(() async {
        service.disconnect();
        await car.close();
      });
      expect(await service.connectWifi(ip: "127.0.0.1", port: car.port), isTrue, reason: service.statusMessage);
      final boost = service.discoveredPids.firstWhere((p) => p.shortName == "BOOST");
      expect(boost.code, "010B");
      car.mapKpa = 280;
      // Baro z emulatora: 99 kPa
      expect(await service.readPid(boost), closeTo((280 - 99) / 100, 0.03));
      expect(service.adapterInfo["Źródło BOOST"], contains("PID 4F"));
    });
  });

  test('tryb przyspieszenia: rejestrator sam łapie przyspieszenie, a Asystent wskazuje zapchany DPF', () async {
    final logger = DataloggerService(obdService: obd, persistHistory: false);
    await connect();
    logger.setMode(LogMode.pull);
    logger.startRecording();
    expect(logger.pullState, PullState.armed);

    // Jazda przed przyspieszeniem
    elm
      ..rpm = 1500
      ..pedalPct = 20
      ..mapKpa = 130
      ..targetKpa = 130
      ..mafGs = 30
      ..dpfDpKpa = 8
      ..egrCmdPct = 0
      ..egrActPct = 0;
    await Future.delayed(const Duration(milliseconds: 1000));
    expect(logger.pullState, PullState.armed);

    // Przyspieszenie 1500 → 4200 obr/min w 4 s: turbo daje połowę zadanego, DPF stawia duży opór,
    // a napełnienie cylindrów spada wraz z obrotami (silnik „dusi się” spalinami)
    const steps = 40;
    for (int i = 0; i <= steps; i++) {
      final rpm = 1500 + 2700 * i / steps;
      final targetBar = rpm < 2500 ? 0.8 + (rpm - 1500) / 1000 * 0.6 : 1.4;
      final actualBar = rpm < 1900 ? targetBar - 0.05 : targetBar * 0.5;
      final ve = 0.9 * (1 - 0.35 * ((rpm - 1500) / 2700));
      elm
        ..rpm = rpm
        ..pedalPct = 100
        ..targetKpa = 99 + targetBar * 100
        ..mapKpa = 99 + actualBar * 100
        ..mafGs = rpm / 60 * 1.18 * (1 + actualBar) * ve
        ..dpfDpKpa = 0.33 * (rpm / 60 * 1.18 * (1 + actualBar) * ve);
      await Future.delayed(const Duration(milliseconds: 100));
      if (i == 5) expect(logger.pullState, PullState.capturing);
    }
    // Zdjęcie gazu kończy pomiar
    elm
      ..pedalPct = 0
      ..rpm = 3800;
    for (int i = 0; i < 40 && logger.isRecording; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    expect(logger.isRecording, isFalse, reason: logger.pullMessage);
    final session = logger.activeSession!;
    expect(session.mode, LogMode.pull);
    expect(session.durationSec, greaterThan(3));
    expect(session.durationSec, lessThan(8)); // tylko samo przyspieszenie (+ ok. 1 s przed)
    final dpf = logger.detectedAnomalies.where((a) => a.id.startsWith("dpf_underboost_")).toList();
    expect(dpf, hasLength(1), reason: logger.detectedAnomalies.map((a) => "${a.id}: ${a.title}").join("\n"));
    expect(dpf.single.plainSummary, contains("DPF"));
  });

  group('kilka PIDów w jednym zapytaniu', () {
    test('odczyt 6 kanałów = 1 zapytanie zamiast 6, wartości identyczne', () async {
      await connect();
      expect(obd.multiPidEnabled, isTrue);
      final keys = ["RPM", "SPEED", "LOAD", "MAF", "IAT", "ECT"];
      final pids = [for (final k in keys) obd.discoveredPids.firstWhere((p) => p.shortName == k)];
      final before = elm.receivedCommands.length;
      final values = await obd.readPids(pids);
      final sent = elm.receivedCommands.sublist(before).where((c) => c.startsWith("01")).toList();
      expect(sent, hasLength(1), reason: sent.join(", "));
      expect(values["RPM"], closeTo(850, 0.01));
      expect(values["SPEED"], 0);
      expect(values["ECT"], 90);
      expect(values["IAT"], 20);
      expect(values["MAF"], closeTo(5.0, 0.01));
    });

    test('PIDy wieloramkowe (70, 6D) też w pakiecie', () async {
      await connect();
      elm
        ..targetKpa = 239
        ..mapKpa = 159;
      final pids = obd.discoveredPids.where((p) => ["RPM", "BOOST", "TARGET_BOOST", "F_RAIL", "RAIL_TGT", "PEDAL"].contains(p.shortName)).toList();
      final before = elm.receivedCommands.length;
      final values = await obd.readPids(pids);
      expect(elm.receivedCommands.sublist(before).where((c) => c.startsWith("01")), hasLength(1));
      expect(values["TARGET_BOOST"], closeTo(1.40, 0.01));
      expect(values["BOOST"], closeTo(0.60, 0.01));
      expect(values["RAIL_TGT"], closeTo(300, 0.1));
      expect(values["F_RAIL"], closeTo(298, 0.1));
    });

    test('sterownik bez obsługi — pojedyncze zapytania jak dotąd', () async {
      elm.multiPidSupported = false;
      await connect();
      expect(obd.multiPidEnabled, isFalse);
      final pids = [for (final k in ["RPM", "SPEED"]) obd.discoveredPids.firstWhere((p) => p.shortName == k)];
      final values = await obd.readPids(pids);
      expect(values["RPM"], closeTo(850, 0.01));
      expect(values["SPEED"], 0);
    });

    test('KWP (bez CAN) — pojedyncze zapytania', () async {
      final car = await MockElm327.start(bus: MockBus.kwp);
      final service = ObdService();
      addTearDown(() async {
        service.disconnect();
        await car.close();
      });
      expect(await service.connectWifi(ip: "127.0.0.1", port: car.port), isTrue);
      expect(service.multiPidEnabled, isFalse);
    });
  });

  group('adapter STN (vLinker, OBDLink)', () {
    test('wykrywa STN i używa STPX — także dla odpowiedzi wieloramkowych', () async {
      final car = await MockElm327.start(stn: true);
      final service = ObdService();
      addTearDown(() async {
        service.disconnect();
        await car.close();
      });
      expect(await service.connectWifi(ip: "127.0.0.1", port: car.port), isTrue, reason: service.statusMessage);
      expect(service.stnId, "STN2255 v5.10.3");
      expect(service.stpxEnabled, isTrue);
      expect(service.adapterInfo["STDI (sprzęt)"], "vLinker MC+ (emulator)");

      car.targetKpa = 239;
      car.mapKpa = 159;
      final before = car.receivedCommands.length;
      final v = await service.readPids(service.discoveredPids.where((p) => ["RPM", "BOOST", "TARGET_BOOST"].contains(p.shortName)).toList());
      final sent = car.receivedCommands.sublist(before);
      expect(sent.every((c) => c.startsWith("STPX") || c.startsWith("AT")), isTrue, reason: sent.join(", "));
      expect(v["RPM"], closeTo(850, 0.01));
      expect(v["TARGET_BOOST"], closeTo(1.40, 0.01));
      // VIN (wieloramkowy) przez STPX też poprawny
      expect(service.vehicleInfo!.vin, MockElm327.vin);
    });

    test('zwykły ELM327: STI → „?”, bez STPX', () async {
      await connect();
      expect(obd.stnId, isNull);
      expect(obd.stpxEnabled, isFalse);
      expect(obd.adapterInfo["STI (układ STN)"], contains("zwykły ELM327"));
    });

    test('adapter resetujący formatowanie po ATSP (jak vLinker FS): nagłówki nadal działają, brak fikcyjnego C0300', () async {
      final car = await MockElm327.start(resetsFormattingOnProtocol: true);
      final service = ObdService();
      addTearDown(() async {
        service.disconnect();
        await car.close();
      });
      expect(await service.connectWifi(ip: "127.0.0.1", port: car.port), isTrue, reason: service.statusMessage);
      expect(service.engineEcuAddress, "7E8");
      expect(await service.readDtcCodes(), isEmpty);
      expect(service.vehicleInfo!.ecuName, "ECM-EngineControl");
    });
  });
}
