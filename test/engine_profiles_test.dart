import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/engine_profiles.dart';
import 'package:autocheck/models/vin_decoder.dart';
import 'package:autocheck/services/engine_memory.dart';
import 'package:autocheck/services/anomaly_engine.dart';
import 'real_logs_test.dart' as r;

void main() {
  test('wykrywa silnik po CALID i danych pojazdu', () {
    expect(EngineProfiles.detect("Volkswagen Touran 03L906023PJ WVGZZ")?.code, "EA189");
    expect(EngineProfiles.detect("BMW 320d N47D20")?.code, "N47");
    expect(EngineProfiles.detect("Peugeot 308 1.6 HDI 9HZ")?.code, "DV6");
    expect(EngineProfiles.detect("Peugeot 208 1.2 PureTech HN05")?.code, "PSA_PURETECH");
    expect(EngineProfiles.detect("Volkswagen Golf 1.9 TDI ALH")?.code, "VW_19_TDI");
    expect(EngineProfiles.detect("BMW 320i N20B20")?.code, "N20");
    expect(EngineProfiles.detect("Mercedes C180 M271")?.code, "MB_M271");
    expect(EngineProfiles.detect("Hyundai ix35 2.0 GDI G4KD")?.code, "HK_THETA_GDI");
    expect(EngineProfiles.detect("Fiat Punto benzyna nieznany")?.code, isNull);
  });

  test('anomalia doładowania na EA189 dostaje notatkę o geometrii VNT', () {
    final pts = r.loadCsv("test/fixtures/touran_1t_wot_1.csv");
    final a = AnomalyEngine.analyzeSession(pts, isDiesel: true, engineInfo: "Volkswagen Touran 2.0 TDI 03L906023PJ");
    final boost = a.firstWhere((x) => x.paramKey == "BOOST");
    expect(boost.engineNote, isNotNull);
    expect(boost.engineNote, contains("EA189"));
    expect(boost.engineNote!.toLowerCase(), contains("geometria"));
  });

  test('bez rozpoznanego silnika brak notatki', () {
    final pts = r.loadCsv("test/fixtures/touran_1t_wot_1.csv");
    final a = AnomalyEngine.analyzeSession(pts, isDiesel: true, engineInfo: "Nieznane auto");
    expect(a.every((x) => x.engineNote == null), isTrue);
  });

  test('identify: kod daje wysoką pewność, zgodna marka z VIN podbija', () {
    final m = EngineProfiles.identify("Volkswagen 03L906023PJ 2.0 TDI", vinMake: "Volkswagen")!;
    expect(m.profile.code, "EA189");
    expect(m.confidence, anyOf(EngineConfidence.high, EngineConfidence.confirmed));
    expect(m.basis, isNotEmpty);
  });

  test('identify: niezgodna marka z VIN odrzuca dopasowanie', () {
    // "N47" w tekście, ale VIN mówi Toyota — profil BMW nie powinien wygrać
    final m = EngineProfiles.identify("Toyota Auris N47 coś", vinMake: "Toyota");
    expect(m?.profile.code, isNot("N47"));
  });

  test('VIN dekoder: marka i rok', () {
    final vin = VinDecoder.decode("WVGZZZ1TZFW011407");
    expect(vin.make, "Volkswagen");
    expect(vin.valid, isTrue);
  });

  test('pamięć: zapamiętany wybór wygrywa z rozpoznaniem (confirmed)', () {
    final mem = EngineMemory(persist: false);
    // resolveFor bez pamięci → rozpoznanie z danych
    final auto = mem.resolveFor("WVGZZZ1TZFW011407", "Volkswagen 03L906 2.0 TDI");
    expect(auto?.profile.code, "EA189");
    // zapamiętaj inny silnik ręcznie
    mem.remember("WVGZZZ1TZFW011407", "CR_TDI_20");
    final fixed = mem.resolveFor("WVGZZZ1TZFW011407", "Volkswagen 03L906 2.0 TDI");
    expect(fixed?.profile.code, "CR_TDI_20");
    expect(fixed?.confidence, EngineConfidence.confirmed);
  });
}
