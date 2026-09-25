import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/engine_specs.dart';

const _json = '''
{
  "source": "test",
  "engines": [
    {"code": "ALH", "make": "Audi", "fuel": "Diesel", "volumeCcm": 1896,
     "powerHp": 90, "powerKw": 66, "torqueNm": 210, "cylinders": 4,
     "boost": "Turbocharged", "yearBegin": 1998, "yearEnd": 2005, "models": ["Audi A3"]},
    {"code": "CRLB, DBGA, DEJA", "make": "Audi", "fuel": "Diesel", "volumeCcm": 1968,
     "powerHp": 150, "torqueNm": 340, "boost": "Turbocharged", "yearBegin": 2013, "yearEnd": 2020, "models": ["Audi A4"]},
    {"code": "N47D20", "make": "BMW", "fuel": "Diesel", "volumeCcm": 1995,
     "powerHp": 177, "torqueNm": 350, "boost": "Turbocharged", "yearBegin": 2007, "yearEnd": 2015, "models": ["BMW 3 series"]},
    {"code": "N47", "make": "BMW", "fuel": "Diesel", "volumeCcm": 1995, "powerHp": 143}
  ]
}
''';

void main() {
  setUp(() {
    EngineSpecs.clearForTest();
    EngineSpecs.loadFromJson(_json);
  });

  test("wczytuje bazę i rozbija zgrupowane kody", () {
    expect(EngineSpecs.isLoaded, isTrue);
    // 1 (ALH) + 3 (CRLB,DBGA,DEJA) + N47D20 + N47 = 6 kodów
    expect(EngineSpecs.count, 6);
    expect(EngineSpecs.byCode("DBGA")?.powerHp, 150);
    expect(EngineSpecs.byCode("DEJA")?.torqueNm, 340);
  });

  test("byCode działa bez wielkości liter i z białymi znakami", () {
    expect(EngineSpecs.byCode(" alh ")?.make, "Audi");
    expect(EngineSpecs.byCode("nieznany"), isNull);
  });

  test("summary po polsku z pojemnością w litrach", () {
    final s = EngineSpecs.byCode("ALH")!;
    expect(s.summary, "1.9 l • 90 KM • 210 Nm • diesel • turbo • 1998–2005");
    expect(s.isDiesel, isTrue);
    expect(s.isTurbo, isTrue);
  });

  test("findInText znajduje kod w CALID i preferuje najdłuższy", () {
    expect(EngineSpecs.findInText("VIN WBA... silnik N47D20 rok 2010")?.code, "N47D20");
    // gdy w tekście jest tylko krótki kod
    expect(EngineSpecs.findInText("engine ALH diesel")?.code, "ALH");
    // brak kodu
    expect(EngineSpecs.findInText("brak danych"), isNull);
  });

  test("preferuje najdłuższy kod, gdy pasują oba (N47 i N47D20)", () {
    expect(EngineSpecs.findInText("N47 N47D20")?.code, "N47D20");
  });
}
