import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/dtc_code.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Opisy PL „dla Kowalskiego" są w zasobie JSON — wczytaj je jak w aplikacji.
    DtcCode.loadPlDescriptions(await rootBundle.loadString("assets/data/dtc_pl.json"));
  });

  test("zasób JSON z opisami PL wczytuje się i ma sensowną liczbę kodów", () {
    expect(DtcCode.plOverlayCount, greaterThan(40));
  });

  test("opisy PL z JSON są dostępne przez getByCode", () {
    for (final code in [
      "P2015", "P244A", "P244B", "P0420", "P0380", "P204F", "P0128", "P0340",
      "P0100", "P0130", "P0351", "P0500", "P0700", "P0741", "U0101", "P0606",
    ]) {
      final d = DtcCode.getByCode(code);
      expect(d.code, code);
      expect(d.title, isNot(startsWith("Kod błędu OBD-II")), reason: "$code powinien mieć opis PL");
      expect(d.commonCauses, isNotEmpty, reason: "$code przyczyny");
      expect(d.diagnosticsSteps, isNotEmpty, reason: "$code kroki");
    }
  });

  test("P2015 to klapy wirowe kolektora — kluczowy kod VAG", () {
    final d = DtcCode.getByCode("P2015");
    expect(d.category.toLowerCase(), contains("kolektor"));
    expect(d.commonCauses.join(" ").toLowerCase(), contains("klap"));
  });

  test("wbudowane kody z kodu (database) nadal mają pierwszeństwo", () {
    expect(DtcCode.getByCode("P0087").title, startsWith("Ciśnienie paliwa"));
  });

  test("własny opis użytkownika ma najwyższy priorytet", () {
    DtcCode.setUserDescription("P0420", {
      "title": "Mój opis kata",
      "description": "Notatka warsztatowa",
      "commonCauses": ["moja przyczyna"],
      "diagnosticsSteps": ["mój krok"],
    });
    final d = DtcCode.getByCode("P0420");
    expect(d.title, "Mój opis kata");
    expect(d.commonCauses, contains("moja przyczyna"));
    DtcCode.setUserDescription("P0420", null); // sprzątanie
    expect(DtcCode.getByCode("P0420").title, isNot("Mój opis kata"));
  });

  test("nieznany kod nadal daje sensowny fallback", () {
    final d = DtcCode.getByCode("P3999");
    expect(d.code, "P3999");
    expect(d.diagnosticsSteps, isNotEmpty);
  });
}
