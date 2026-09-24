import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/engine_profiles.dart';
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
}
