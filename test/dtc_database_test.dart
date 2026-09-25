import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/dtc_code.dart';

void main() {
  test("rozszerzona baza zawiera najczęstsze kody z pełnym opisem PL", () {
    for (final code in ["P2015", "P244A", "P244B", "P0420", "P0380", "P204F", "P0128", "P0340"]) {
      final d = DtcCode.getByCode(code);
      expect(d.code, code);
      expect(d.title.isNotEmpty, isTrue, reason: "$code tytuł");
      expect(d.commonCauses, isNotEmpty, reason: "$code przyczyny");
      expect(d.diagnosticsSteps, isNotEmpty, reason: "$code kroki");
      // opis rozbudowany, nie tylko fallback „Kod błędu OBD-II"
      expect(d.title, isNot(startsWith("Kod błędu OBD-II")), reason: "$code powinien mieć własny opis");
    }
  });

  test("P2015 to klapy wirowe kolektora — kluczowy kod VAG", () {
    final d = DtcCode.getByCode("P2015");
    expect(d.category.toLowerCase(), contains("kolektor"));
    expect(d.commonCauses.join(" ").toLowerCase(), contains("klap"));
  });

  test("nieznany kod nadal daje sensowny fallback", () {
    final d = DtcCode.getByCode("P3999");
    expect(d.code, "P3999");
    expect(d.diagnosticsSteps, isNotEmpty);
  });
}
