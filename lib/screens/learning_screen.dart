import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/sniff_recording.dart';
import '../services/analysis/sniff_analyzer.dart';
import '../services/obd_service.dart';
import '../services/pid_definitions_store.dart';
import '../services/sniff_service.dart';
import '../services/torque_equation.dart';
import '../theme/app_theme.dart';

/// Nauka od innego testera: vLinker na kablu Y podsłuchuje, o co tester (np. Autel)
/// pyta moduły, a aplikacja buduje z tego własną bibliotekę parametrów.
class LearningScreen extends StatelessWidget {
  const LearningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sniff = context.watch<SniffService>();
    final obd = context.watch<ObdService>();
    final analysis = sniff.analysis;
    return Scaffold(
      appBar: AppBar(title: const Text("Nauka od testera")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _HowToCard(),
          const SizedBox(height: 12),
          _RecordCard(sniff: sniff, obd: obd),
          const SizedBox(height: 12),
          _SavedCard(sniff: sniff),
          if (analysis != null) ...[
            const SizedBox(height: 16),
            _AnalysisHeader(analysis: analysis),
            for (final ecu in analysis.ecus.values) _EcuTile(ecu: ecu),
          ],
        ],
      ),
    );
  }
}

BoxDecoration _card() => BoxDecoration(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      border: Border.all(color: AppTheme.border),
    );

class _HowToCard extends StatelessWidget {
  const _HowToCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _card(),
      child: const ExpansionTile(
        leading: Icon(Icons.help_outline, color: AppTheme.textSecondary),
        title: Text("Jak to działa", style: TextStyle(fontWeight: FontWeight.w600)),
        childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(
            "1. Podłącz rozdzielacz OBD (kabel Y): Autel i vLinker jednocześnie.\n"
            "2. Połącz aplikację z vLinkerem jak zwykle, potem naciśnij „Nagrywaj”.\n"
            "   vLinker przechodzi w cichy nasłuch — nic nie wysyła na magistralę, więc nie przeszkadza Autelowi.\n"
            "3. W Autelu wejdź w moduł i otwórz parametry na żywo (np. doładowanie zadane/rzeczywiste, korekty wtrysków). "
            "Najlepiej przegazuj lub przejedź się — zmieniające się wartości łatwiej rozpoznać.\n"
            "4. Zatrzymaj nagrywanie. Aplikacja pokaże, o jakie identyfikatory pytał Autel i jakie dostawał odpowiedzi.\n"
            "5. Porównaj wartości z ekranem Autela i zapisz parametr do Mojej biblioteki — od tej pory odczytasz go samym vLinkerem, "
            "a analizator użyje go w diagnozie.\n\n"
            "Działa na magistrali CAN (większość aut od ok. 2008 r.). W starszych VAG (TP2.0) bloki pomiarowe są od razu "
            "rozszyfrowane dzięki formułom z odpowiedzi modułu.",
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _RecordCard extends StatefulWidget {
  final SniffService sniff;
  final ObdService obd;
  const _RecordCard({required this.sniff, required this.obd});

  @override
  State<_RecordCard> createState() => _RecordCardState();
}

class _RecordCardState extends State<_RecordCard> {
  final _label = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  String _fmt(Duration d) => "${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}";

  Future<void> _toggle() async {
    setState(() => _busy = true);
    final sniff = widget.sniff;
    if (sniff.isRecording) {
      final f = await sniff.stop();
      if (mounted && f != null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Nagranie zapisane.")));
      }
    } else {
      final label = _label.text.trim().isNotEmpty ? _label.text.trim() : (widget.obd.vehicleInfo?.vin ?? "");
      await sniff.start(label: label);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final sniff = widget.sniff;
    final obd = widget.obd;
    final recording = sniff.isRecording;
    final canStart = obd.canMonitor;
    return Container(
      decoration: _card(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(recording ? Icons.fiber_manual_record : Icons.hearing, color: recording ? AppTheme.fault : AppTheme.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(recording ? "Nagrywanie… ${_fmt(sniff.elapsed)}" : "Podsłuch magistrali",
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!recording)
            TextField(
              controller: _label,
              decoration: const InputDecoration(
                labelText: "Opis (np. model auta, silnik) — opcjonalnie",
                isDense: true,
              ),
            ),
          if (recording) ...[
            Text("Ramek: ${sniff.lineCount}   •   parametrów: ${sniff.analysis?.allParams.length ?? 0}",
                style: const TextStyle(color: AppTheme.textSecondary)),
            if (obd.monitorRestarts > 0)
              Text(
                "Adapter nie nadążał ${obd.monitorRestarts}× (przepełniony bufor) — część ramek mogła przepaść.",
                style: const TextStyle(color: AppTheme.warn, fontSize: 12),
              ),
            const SizedBox(height: 4),
            const Text("Odczyty aplikacji (logger, kody) czekają do zatrzymania nagrywania.",
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _busy || (!recording && !canStart) ? null : _toggle,
            icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record),
            label: Text(recording ? "Zatrzymaj i przeanalizuj" : "Nagrywaj"),
          ),
          if (!recording && !canStart)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text("Najpierw połącz się z autem (magistrala CAN).",
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            ),
          if (sniff.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(sniff.error!, style: const TextStyle(color: AppTheme.fault, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

class _SavedCard extends StatelessWidget {
  final SniffService sniff;
  const _SavedCard({required this.sniff});

  Future<void> _load(BuildContext context) async {
    try {
      final picked = await FilePicker.pickFiles(dialogTitle: "Wybierz nagranie magistrali");
      if (picked.isEmpty) return;
      final bytes = await picked.first.readAsBytes();
      String text;
      try {
        text = utf8.decode(bytes);
      } catch (_) {
        text = latin1.decode(bytes);
      }
      sniff.open(SniffRecording.fromText(text));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Nie udało się wczytać pliku: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _card(),
      child: ExpansionTile(
        leading: const Icon(Icons.folder_open, color: AppTheme.textSecondary),
        title: Text("Zapisane nagrania (${sniff.saved.length})"),
        children: [
          for (final f in sniff.saved)
            ListTile(
              dense: true,
              title: Text(f.uri.pathSegments.last, style: const TextStyle(fontSize: 13)),
              onTap: sniff.isRecording ? null : () => sniff.openFile(f),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(Icons.share, size: 18), onPressed: () => sniff.share(f)),
                  IconButton(icon: const Icon(Icons.delete_outline, size: 18), onPressed: () => _confirmDelete(context, f)),
                ],
              ),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.upload_file, size: 18),
            title: const Text("Wczytaj nagranie z pliku"),
            onTap: sniff.isRecording ? null : () => _load(context),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Usunąć nagranie?"),
        content: Text(f.uri.pathSegments.last),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("Anuluj")),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text("Usuń")),
        ],
      ),
    );
    if (ok == true) await sniff.delete(f);
  }
}

class _AnalysisHeader extends StatelessWidget {
  final SniffAnalysis analysis;
  const _AnalysisHeader({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final params = analysis.allParams;
    final changing = params.where((p) => p.changes).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Co odczytywał tester", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            analysis.ecus.isEmpty
                ? "Nie znaleziono zapytań diagnostycznych (${analysis.frames} ramek). Czy tester był w trakcie odczytu parametrów?"
                : "${analysis.ecus.length} moduł(y), ${params.length} parametrów, w tym $changing zmieniających się. "
                    "Zmieniające się są na górze — porównaj je z ekranem testera.",
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

String _hexBytes(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(" ");

String _num(double v) {
  if (v.abs() >= 100 || v == v.roundToDouble()) return v.toStringAsFixed(0);
  if (v.abs() >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(2);
}

/// Wartość do podglądu: formuła VAG albo proponowane równanie.
String _preview(LearnedParam p) {
  if (p.samples.isEmpty) return "";
  if (p.kind == LearnedKind.tp20Block) {
    final v = p.decodedValues.last;
    final f = p.formula;
    return v == null ? _hexBytes(p.samples.last.bytes) : "${_num(v)} ${f?.unit ?? ''}".trim();
  }
  return _hexBytes(p.samples.last.bytes.take(6).toList()) + (p.length > 6 ? " …" : "");
}

class _EcuTile extends StatelessWidget {
  final SniffEcu ecu;
  const _EcuTile({required this.ecu});

  @override
  Widget build(BuildContext context) {
    final params = ecu.params.values.toList()
      ..sort((a, b) {
        if (a.changes != b.changes) return a.changes ? -1 : 1;
        final c = a.identifier.compareTo(b.identifier);
        return c != 0 ? c : (a.field ?? 0).compareTo(b.field ?? 0);
      });
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: _card(),
      child: ExpansionTile(
        leading: const Icon(Icons.memory, color: AppTheme.textSecondary),
        title: Text(ecu.label, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [if (ecu.identification != null) ecu.identification!, "${params.length} parametrów"].join("\n"),
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
        children: [
          for (final p in params)
            ListTile(
              dense: true,
              title: Text(p.title),
              subtitle: Text(
                "${p.samples.length} odczytów • ${p.length} B • ${p.changes ? 'zmienia się (${p.distinctValues} wartości)' : 'stała'}"
                "${p.dynamicDefinition != null ? ' • dynamiczny' : ''}",
                style: TextStyle(color: p.changes ? AppTheme.ok : AppTheme.textMuted, fontSize: 11),
              ),
              trailing: Text(_preview(p), style: const TextStyle(fontFamily: "monospace", fontSize: 12)),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => LearnedParamScreen(ecu: ecu, param: p)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Szczegóły parametru: próbki, interpretacje i zapis do biblioteki.
class LearnedParamScreen extends StatefulWidget {
  final SniffEcu ecu;
  final LearnedParam param;
  const LearnedParamScreen({super.key, required this.ecu, required this.param});

  @override
  State<LearnedParamScreen> createState() => _LearnedParamScreenState();
}

class _LearnedParamScreenState extends State<LearnedParamScreen> {
  late final TextEditingController _name;
  late final TextEditingController _equation;
  late final TextEditingController _unit;
  String? _eqError;
  List<double> _values = [];
  bool _saving = false;

  /// Nazwy, które analizator rozpoznaje i używa w diagnozie.
  static const _presets = <(String, String)>[
    ("Doładowanie rzeczywiste", "mbar"),
    ("Doładowanie zadane", "mbar"),
    ("Ciśnienie paliwa rzeczywiste", "bar"),
    ("Ciśnienie paliwa zadane", "bar"),
    ("Korekta wtryskiwacza cyl. 1", "mg/H"),
    ("Korekta wtryskiwacza cyl. 2", "mg/H"),
    ("Korekta wtryskiwacza cyl. 3", "mg/H"),
    ("Korekta wtryskiwacza cyl. 4", "mg/H"),
    ("Różnica ciśnień DPF", "mbar"),
    ("Sadza DPF masa", "g"),
    ("Temperatura spalin", "°C"),
    ("Temperatura oleju", "°C"),
    ("Kierownice VGT pozycja", "%"),
    ("Kierownice VGT zadane", "%"),
    ("Zawór EGR pozycja", "%"),
    ("Zawór EGR zadany", "%"),
    ("Masa powietrza", "kg/h"),
    ("Lambda", "λ"),
  ];

  LearnedParam get p => widget.param;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _equation = TextEditingController(text: p.suggestEquation());
    _unit = TextEditingController(text: p.formula?.unit ?? "");
    _evaluate();
  }

  @override
  void dispose() {
    _name.dispose();
    _equation.dispose();
    _unit.dispose();
    super.dispose();
  }

  void _evaluate() {
    if (p.kind == LearnedKind.tp20Block) {
      _values = [for (final v in p.decodedValues) ?v];
      return;
    }
    try {
      final eq = TorqueEquation.parse(_equation.text);
      _values = [
        for (final s in p.samples)
          if (eq.evaluate(s.bytes) case final v when v.isFinite) v,
      ];
      _eqError = _values.isEmpty ? "Równanie wymaga więcej bajtów niż ma odpowiedź" : null;
    } on TorqueEquationException catch (e) {
      _eqError = e.message;
      _values = [];
    }
  }

  Future<void> _save() async {
    final cmd = p.requestCommand;
    if (cmd == null) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _eqError = "Podaj nazwę parametru");
      return;
    }
    setState(() => _saving = true);
    final store = context.read<PidDefinitionsStore>();
    final obd = context.read<ObdService>();
    final err = await store.addToLibrary(
      name: name,
      command: cmd,
      equation: _equation.text.trim(),
      unit: _unit.text.trim(),
      header: p.requestHeader,
    );
    if (err == null && obd.status == ObdConnectionStatus.connected && !obd.isMonitoring) {
      await obd.probeImportedNow();
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err ?? "Zapisano „$name” w Mojej bibliotece (${PidDefinitionsStore.libraryFile})."),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final samples = p.samples;
    final canSave = p.requestCommand != null && p.kind != LearnedKind.obdPid;
    final varying = p.varyingBytes.map(LearnedParam.byteName).join(", ");
    return Scaffold(
      appBar: AppBar(title: Text(p.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.ecu.label, style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          Text(
            [
              if (p.requestCommand != null) "Zapytanie: ${p.requestCommand}",
              if (p.requestHeader != null) "nagłówek ${p.requestHeader}",
              "${samples.length} odczytów",
              if (varying.isNotEmpty) "zmienne bajty: $varying" else "wartość stała",
            ].join(" • "),
            style: const TextStyle(fontSize: 13),
          ),
          if (p.dynamicDefinition != null) ...[
            const SizedBox(height: 8),
            Text(
              "Uwaga: ten DID tester złożył dynamicznie (UDS 2C) z: ${p.dynamicDefinition}. "
              "Samo zapytanie 22 może nie działać — lepiej zapisz DID źródłowy.",
              style: const TextStyle(color: AppTheme.warn, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          if (_values.length >= 2) _Sparkline(values: _values),
          if (_values.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                "Min ${_num(_values.reduce((a, b) => a < b ? a : b))}   •   "
                "maks ${_num(_values.reduce((a, b) => a > b ? a : b))}   •   ostatnia ${_num(_values.last)} ${_unit.text}",
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
          if (p.kind == LearnedKind.tp20Block)
            Text(
              "Blok pomiarowy TP2.0 — wartość wyliczona formułą VAG nr 0x${samples.last.bytes[0].toRadixString(16).toUpperCase()}"
              "${p.formula != null ? ' (${p.formula!.name})' : ' (nieznana formuła)'}. "
              "Odczyt bloków TP2.0 na żywo samym vLinkerem jeszcze nie jest obsługiwany, więc tego parametru nie da się na razie zapisać do biblioteki.",
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            )
          else if (p.kind == LearnedKind.obdPid)
            const Text("To standardowy PID OBD — aplikacja odczytuje go już sama.",
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12))
          else ...[
            const Text("Zapisz do Mojej biblioteki", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (n, u) in _presets)
                  ActionChip(
                    label: Text(n, style: const TextStyle(fontSize: 11)),
                    onPressed: () => setState(() {
                      _name.text = n;
                      if (_unit.text.isEmpty) _unit.text = u;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(controller: _name, decoration: const InputDecoration(labelText: "Nazwa (jak na ekranie testera)")),
            TextField(
              controller: _equation,
              decoration: InputDecoration(labelText: "Równanie (A = pierwszy bajt danych)", errorText: _eqError),
              onChanged: (_) => setState(_evaluate),
            ),
            TextField(controller: _unit, decoration: const InputDecoration(labelText: "Jednostka"), onChanged: (_) => setState(() {})),
            const SizedBox(height: 6),
            const Text(
              "Dobierz równanie tak, żeby wartość zgadzała się z Autelem. Typowo: (A*256)+B, potem skala, np. ((A*256)+B)/10. "
              "Znak ze znakiem: INT16(A:B). Nazwy z listy analizator rozpoznaje i używa w diagnozie.",
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: !canSave || _saving || _eqError != null ? null : _save,
              icon: const Icon(Icons.library_add),
              label: const Text("Dodaj do biblioteki"),
            ),
          ],
          const SizedBox(height: 20),
          const Text("Ostatnie odczyty", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (final s in samples.reversed.take(40)) _SampleRow(sample: s),
        ],
      ),
    );
  }
}

class _SampleRow extends StatelessWidget {
  final LearnedSample sample;
  const _SampleRow({required this.sample});

  @override
  Widget build(BuildContext context) {
    final b = sample.bytes;
    final parts = <String>[];
    if (b.length >= 2) {
      final u16 = (b[0] << 8) | b[1];
      parts.add("AB=$u16");
      parts.add("±${u16 >= 0x8000 ? u16 - 0x10000 : u16}");
    }
    if (b.isNotEmpty) parts.add("A=${b[0]}");
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text("${(sample.tMs / 1000).toStringAsFixed(1)} s", style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          ),
          Expanded(child: Text(_hexBytes(b), style: const TextStyle(fontFamily: "monospace", fontSize: 12))),
          Text(parts.join("  "), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
        ],
      ),
    );
  }
}

class _Sparkline extends StatelessWidget {
  final List<double> values;
  const _Sparkline({required this.values});

  @override
  Widget build(BuildContext context) {
    // Najwyżej ~300 punktów
    final step = (values.length / 300).ceil().clamp(1, 1 << 30);
    final spots = <FlSpot>[
      for (int i = 0; i < values.length; i += step) FlSpot(i.toDouble(), values[i]),
    ];
    return SizedBox(
      height: 140,
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(spots: spots, isCurved: false, dotData: const FlDotData(show: false), color: AppTheme.accent, barWidth: 2),
          ],
        ),
      ),
    );
  }
}
