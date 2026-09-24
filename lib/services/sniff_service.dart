import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/sniff_recording.dart';
import 'analysis/sniff_analyzer.dart';
import 'elm_parser.dart';
import 'obd_service.dart';

/// Nagrywanie podsłuchu magistrali (nauka od innego testera) i zapisane nagrania.
class SniffService extends ChangeNotifier {
  final ObdService obd;
  final bool persist;

  SniffRecording? _current;
  final Stopwatch _clock = Stopwatch();
  Timer? _tick;
  SniffAnalysis? _analysis;
  List<File> _saved = [];
  String? _error;

  SniffService({required this.obd, this.persist = true}) {
    if (persist) refreshSaved();
  }

  bool get isRecording => _current != null && obd.isMonitoring;
  SniffRecording? get current => _current;
  SniffAnalysis? get analysis => _analysis;
  List<File> get saved => List.unmodifiable(_saved);
  String? get error => _error;
  Duration get elapsed => _clock.elapsed;
  int get lineCount => _current?.lines.length ?? 0;

  Future<bool> start({String label = ""}) async {
    if (isRecording) return true;
    _error = null;
    final rec = SniffRecording(
      start: DateTime.now(),
      extendedIds: obd.busType == ObdBusType.can29,
      label: label,
    );
    _current = rec;
    _analysis = null;
    _clock
      ..reset()
      ..start();
    final ok = await obd.startMonitor((line) => rec.lines.add(SniffLine(_clock.elapsedMilliseconds, line)));
    if (!ok) {
      _current = null;
      _clock.stop();
      _error = "Podsłuch działa tylko po połączeniu z autem na magistrali CAN.";
      notifyListeners();
      return false;
    }
    // Odświeżanie licznika i podglądu analizy
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_current != null) _analysis = SniffAnalyzer.analyze(_current!);
      notifyListeners();
    });
    notifyListeners();
    return true;
  }

  /// Zatrzymuje nagrywanie, analizuje i zapisuje nagranie. Zwraca zapisany plik.
  Future<File?> stop() async {
    final rec = _current;
    if (rec == null) return null;
    _tick?.cancel();
    _tick = null;
    await obd.stopMonitor();
    _clock.stop();
    _analysis = SniffAnalyzer.analyze(rec);
    File? file;
    if (persist && rec.lines.isNotEmpty) {
      try {
        final dir = await _dir();
        final ts = rec.start.toIso8601String().replaceAll(":", "-").split(".").first;
        file = File("${dir.path}/sniff_$ts.txt");
        await file.writeAsString(rec.toText());
        await refreshSaved();
      } catch (e) {
        _error = "Nie udało się zapisać nagrania: $e";
      }
    }
    notifyListeners();
    return file;
  }

  /// Wczytuje nagranie (zapisane lub przysłane) i analizuje je.
  void open(SniffRecording rec) {
    if (isRecording) return;
    _current = rec;
    _analysis = SniffAnalyzer.analyze(rec);
    notifyListeners();
  }

  Future<void> openFile(File f) async {
    open(SniffRecording.fromText(await f.readAsString()));
  }

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory("${docs.path}/sniff");
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> refreshSaved() async {
    try {
      final dir = await _dir();
      final files = <File>[
        await for (final f in dir.list())
          if (f is File && f.path.endsWith(".txt")) f,
      ];
      files.sort((a, b) => b.path.compareTo(a.path));
      _saved = files;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd listy nagrań: $e");
    }
  }

  Future<void> delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
    await refreshSaved();
  }

  Future<void> share(File f) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: "Nagranie magistrali Dynomic Diag"));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}
