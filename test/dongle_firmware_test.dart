import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/obd_pid.dart';
import 'package:autocheck/models/vag_modules.dart';
import 'package:autocheck/services/obd_service.dart';

/// Aplikacja kontra firmware kostki Dynomic OBD: rdzeń firmware (ten sam kod C, co na
/// ESP32-C6) skompilowany na PC z symulatorem auta na poziomie ramek CAN.
/// Sprawdza, że aplikacja działa z kostką bez żadnych zmian po swojej stronie.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const hostDir = "hardware/dongle/host";
  Process? proc;
  int port = 0;
  String? skip;

  setUpAll(() async {
    final build = await Process.run("make", ["-C", hostDir]);
    if (build.exitCode != 0) {
      skip = "Brak kompilatora C — pomijam testy firmware (${build.stderr})";
      return;
    }
    proc = await Process.start("$hostDir/build/dx_host", ["0"]);
    final line = await proc!.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
    port = int.parse(line.split(" ").last);
  });

  tearDownAll(() => proc?.kill());

  Future<ObdService> connect() async {
    final obd = ObdService();
    final ok = await obd.connectWifi(ip: "127.0.0.1", port: port);
    expect(ok, isTrue, reason: obd.statusMessage);
    return obd;
  }

  test('łączenie: VIN, sterownik silnika, rozpoznanie kostki (STI) i STPX', () async {
    if (skip != null) return markTestSkipped(skip!);
    final obd = await connect();
    addTearDown(obd.disconnect);
    expect(obd.vehicleInfo!.vin, "WVGZZZ1TZFW011407");
    expect(obd.engineEcuAddress, "7E8");
    expect(obd.stnId, startsWith("DX1"));
    expect(obd.stpxEnabled, isTrue);
    expect(obd.multiPidEnabled, isTrue);
    expect(obd.adapterInfo["STDI (sprzęt)"], contains("Dynomic OBD"));
  });

  test('odczyt parametrów: obroty i doładowanie zadane/rzeczywiste (PID 70)', () async {
    if (skip != null) return markTestSkipped(skip!);
    final obd = await connect();
    addTearDown(obd.disconnect);
    final rpm = await obd.readPid(ObdPid.getByShortName("RPM")!);
    expect(rpm, inInclusiveRange(800, 2600));
    final keys = obd.discoveredPids.map((p) => p.shortName).toSet();
    expect(keys, containsAll(["BOOST", "TARGET_BOOST"]));
    final values = await obd.readPids(obd.discoveredPids.where((p) => p.shortName.contains("BOOST")).toList());
    expect(values["TARGET_BOOST"]! - values["BOOST"]!, closeTo(0.15, 0.02));
  });

  test('kody usterek z silnika', () async {
    if (skip != null) return markTestSkipped(skip!);
    final obd = await connect();
    addTearDown(obd.disconnect);
    final codes = await obd.readDtcCodes();
    expect(codes!.map((c) => c.code), contains("P0299"));
  });

  test('VW TP2.0 przez surowy CAN kostki: identyfikacja i usterki modułu silnika', () async {
    if (skip != null) return markTestSkipped(skip!);
    final obd = await connect();
    addTearDown(obd.disconnect);
    final r = await obd.scanVagTp20Modules(modules: const [VagTp20Module(0x01, "Silnik")]);
    expect(r.single.responded, isTrue);
    expect(r.single.identification, contains("03L906023PJ"));
    expect(r.single.dtcs, hasLength(1));
    // Po skanie kostka wraca do zwykłej pracy
    expect(await obd.readPid(ObdPid.getByShortName("RPM")!), isNotNull);
  });

  test('podsłuch (STMA): ruch w tle i powrót do pracy', () async {
    if (skip != null) return markTestSkipped(skip!);
    final obd = await connect();
    addTearDown(obd.disconnect);
    final lines = <String>[];
    expect(await obd.startMonitor(lines.add), isTrue);
    await Future.delayed(const Duration(milliseconds: 300));
    await obd.stopMonitor();
    expect(lines.where((l) => l.startsWith("280 ")).length, greaterThan(10));
    expect(await obd.readPid(ObdPid.getByShortName("RPM")!), isNotNull);
  });
}
