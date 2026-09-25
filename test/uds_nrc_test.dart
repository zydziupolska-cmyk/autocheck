import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/uds_nrc.dart';

void main() {
  test("opisy NRC po polsku dla najważniejszych kodów", () {
    expect(UdsNrc.describePl(0x33), contains("Security Access"));
    expect(UdsNrc.describePl(0x31), contains("zakres"));
    expect(UdsNrc.describePl(0x78), contains("toku"));
    expect(UdsNrc.describePl(0x83), contains("silnik"));
    expect(UdsNrc.describePl(null), "brak odpowiedzi modułu");
  });

  test("nieznany kod daje czytelny fallback z heksem", () {
    expect(UdsNrc.describePl(0xF0), "odmowa 0xF0");
    expect(UdsNrc.name(0xF0), contains("0xF0"));
  });

  test("klasyfikacja: bezpieczeństwo i warunki chwilowe", () {
    expect(UdsNrc.isSecurity(0x33), isTrue);
    expect(UdsNrc.isSecurity(0x35), isTrue);
    expect(UdsNrc.isSecurity(0x31), isFalse);
    expect(UdsNrc.isTransient(0x78), isTrue);
    expect(UdsNrc.isTransient(0x21), isTrue);
    expect(UdsNrc.isTransient(0x33), isFalse);
  });

  test("nazwa techniczna zgodna z ISO 14229", () {
    expect(UdsNrc.name(0x33), "securityAccessDenied");
    expect(UdsNrc.name(0x11), "serviceNotSupported");
  });
}
