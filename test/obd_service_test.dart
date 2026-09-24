import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/obd_pid.dart';
import 'package:autocheck/services/datalogger_service.dart';
import 'package:autocheck/services/obd_service.dart';

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
    expect(await obd.readPid(pid("F_RAIL")), closeTo(300, 0.01));
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
}
