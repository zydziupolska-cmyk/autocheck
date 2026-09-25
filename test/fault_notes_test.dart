import 'package:flutter_test/flutter_test.dart';
import 'package:autocheck/services/fault_notes.dart';

void main() {
  test("dodaje, czyta i usuwa notatki per kod silnika", () async {
    final n = FaultNotes(persist: false);
    expect(n.isEmpty, isTrue);

    await n.add("EA189", "Zawór EGR", "Zapieka się, błąd przepływu");
    await n.add("EA189", "DPF", "Zapchany przy krótkich trasach");
    await n.add("N47", "Łańcuch rozrządu", "Rozciąga się ~150 tys.");

    expect(n.notesFor("EA189").length, 2);
    expect(n.notesFor("n47").length, 1); // bez wielkości liter
    expect(n.totalCount, 3);
    expect(n.notesFor("EA189").first.title, "Zawór EGR");

    final id = n.notesFor("EA189").first.id;
    await n.remove("EA189", id);
    expect(n.notesFor("EA189").length, 1);
    expect(n.notesFor("EA189").first.title, "DPF");
  });

  test("ignoruje pusty tytuł i pusty kod", () async {
    final n = FaultNotes(persist: false);
    await n.add("EA189", "   ", "coś");
    await n.add("", "Tytuł", "coś");
    expect(n.totalCount, 0);
  });

  test("notesFor dla nieznanego kodu zwraca pustą listę", () {
    final n = FaultNotes(persist: false);
    expect(n.notesFor("XYZ"), isEmpty);
    expect(n.notesFor(null), isEmpty);
  });
}
