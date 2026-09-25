import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/models/extended_pid.dart';

void main() {
  group("Kanoniczne mapowanie kanałów producenta", () {
    test("aliasy diesla trafiają do kanałów używanych przez analizator", () {
      // DPF — różnica ciśnień (kluczowe dla oceny zatkania filtra)
      for (final a in ["DPFDP", "DPFDIFFP", "DPFDIFF", "DPFPRESS", "PDPF", "SOOTP"]) {
        expect(ExtendedPid.canonicalKeyFor(a), "DPF_DP", reason: a);
      }
      // EGR — zadane i rzeczywiste
      for (final a in ["EGRCMD", "EGRDES", "EGRSET"]) {
        expect(ExtendedPid.canonicalKeyFor(a), "EGR_CMD", reason: a);
      }
      for (final a in ["EGRACT", "EGRPOS", "EGRFB"]) {
        expect(ExtendedPid.canonicalKeyFor(a), "EGR_ACT", reason: a);
      }
      // EGT, olej, MAF, VGT, sadza
      expect(ExtendedPid.canonicalKeyFor("EXHTEMP"), "EGT");
      expect(ExtendedPid.canonicalKeyFor("OILTEMP"), "OIL_T");
      expect(ExtendedPid.canonicalKeyFor("AIRMASS"), "MAF");
      expect(ExtendedPid.canonicalKeyFor("VNTACT"), "VGT_ACT");
      expect(ExtendedPid.canonicalKeyFor("DPFLOAD"), "DPF_SOOT");
    });

    test("bez wielkości liter", () {
      expect(ExtendedPid.canonicalKeyFor("egrcmd"), "EGR_CMD");
      expect(ExtendedPid.canonicalKeyFor("DpFdP"), "DPF_DP");
    });

    test("nieznana nazwa pozostaje bez zmian", () {
      expect(ExtendedPid.canonicalKeyFor("FOOBAR"), "FOOBAR");
      expect(ExtendedPid.canonicalKeyFor("RPM"), "RPM");
    });

    test("wbudowane tabele VAG/BMW dają kanoniczne kanały", () {
      final vag = ExtendedPid.channelsFor(VehicleProfile.vag).map((p) => p.shortName).toSet();
      expect(vag, containsAll(["BOOST", "TARGET_BOOST", "F_RAIL"]));

      final bmw = ExtendedPid.channelsFor(VehicleProfile.bmw).map((p) => p.shortName).toSet();
      expect(bmw, containsAll(["BOOST", "TARGET_BOOST", "EGT", "DPF_SOOT"]));
    });

    test("ciśnienie doładowania z UDS ma jednostkę bar i szybki odczyt", () {
      final boost = ExtendedPid.channelsFor(VehicleProfile.vag).firstWhere((p) => p.shortName == "BOOST");
      expect(boost.unit, "bar");
    });
  });
}
