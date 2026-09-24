import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/anomaly.dart';
import '../models/log_point.dart';
import '../models/obd_pid.dart';
import 'anomaly_engine.dart';
import 'obd_service.dart';
import 'simulator_service.dart';
import '../models/trip_report.dart';

class DataloggerService extends ChangeNotifier {
  final ObdService obdService;

  /// Czy zapisywać historię logów na dysku (wyłączane w testach).
  final bool persistHistory;

  bool _isRecording = false;
  List<LogPoint> _currentPoints = [];
  List<Anomaly> _detectedAnomalies = [];
  final List<LogSession> _sessionsHistory = [];
  LogSession? _activeSession;
  DateTime? _recordingStartTime;
  String? _recordingWarning;

  // Wybrane czujniki do logowania
  Set<String> _selectedPidKeys = {"RPM", "BOOST", "MAF", "IGN", "TPS", "AFR"};

  // Częstotliwość próbkowania (pełnych cykli odczytu na sekundę)
  int _samplesCountLastSec = 0;
  double _currentHz = 0.0;
  DateTime _lastHzCheck = DateTime.now();

  ObdConnectionStatus? _lastObdStatus;

  DataloggerService({required this.obdService, this.persistHistory = true}) {
    obdService.addListener(_onObdChanged);
    if (persistHistory) _loadHistory();
  }

  bool get isRecording => _isRecording;
  List<LogPoint> get currentPoints => _currentPoints;
  List<Anomaly> get detectedAnomalies => _detectedAnomalies;
  List<LogSession> get sessionsHistory => _sessionsHistory;
  LogSession? get activeSession => _activeSession;
  Set<String> get selectedPidKeys => _selectedPidKeys;
  double get currentHz => _currentHz;

  /// Ostrzeżenie w trakcie nagrywania (np. ECU przestało odpowiadać).
  String? get recordingWarning => _recordingWarning;

  bool get _isDiesel => obdService.vehicleInfo?.isDiesel ?? false;

  /// Po połączeniu z prawdziwym autem dopasuj wybór czujników do tego, co obsługuje ECU.
  void _onObdChanged() {
    final status = obdService.status;
    if (status == _lastObdStatus) return;
    _lastObdStatus = status;

    if (status == ObdConnectionStatus.connected) {
      final available = obdService.discoveredPids.map((p) => p.shortName).toSet();
      var selection = _selectedPidKeys.where(available.contains).toSet();
      if (selection.length < 3) {
        // Rozsądny domyślny zestaw zależnie od rodzaju silnika
        final defaults = _isDiesel
            ? ["RPM", "BOOST", "MAF", "PEDAL", "LOAD", "IAT", "ECT", "SPEED"]
            : ["RPM", "BOOST", "MAF", "IGN", "TPS", "PEDAL", "STFT", "LTFT", "IAT"];
        selection = {...selection, ...defaults.where(available.contains)};
      }
      if (_isDiesel) {
        // W dieslu TPS to klapa dławiąca — zamiast niej logujemy pedał gazu
        if (available.contains("PEDAL")) selection.add("PEDAL");
        selection.remove("AFR");
      }
      if (selection.isEmpty && available.isNotEmpty) selection = {available.first};
      _selectedPidKeys = selection;
      notifyListeners();
    } else if (_isRecording &&
        status != ObdConnectionStatus.simulated &&
        status != ObdConnectionStatus.connected) {
      // Utracono połączenie w trakcie nagrywania — zachowaj to, co już zebrano
      stopRecording();
    }
  }

  void togglePid(String shortName) {
    if (_selectedPidKeys.contains(shortName)) {
      if (_selectedPidKeys.length > 1) {
        _selectedPidKeys.remove(shortName);
      }
    } else {
      _selectedPidKeys.add(shortName);
    }
    notifyListeners();
  }

  void applyPreset(LoggingPreset preset) {
    final available = obdService.discoveredPids.map((p) => p.shortName).toSet();
    final filtered = preset.pidShortNames.where(available.contains).toSet();
    _selectedPidKeys = filtered.isNotEmpty ? filtered : {"RPM"};
    notifyListeners();
  }

  /// Rozpoczyna nagrywanie logu
  void startRecording() {
    if (_isRecording) return;
    _currentPoints = [];
    _detectedAnomalies = [];
    _recordingWarning = null;
    _isRecording = true;
    _lastHzCheck = DateTime.now();
    _samplesCountLastSec = 0;
    _currentHz = 0.0;
    _recordingStartTime = DateTime.now();
    notifyListeners();

    if (obdService.status == ObdConnectionStatus.simulated) {
      obdService.simulator.startLivePull(
        scenario: obdService.selectedScenario,
        onPoint: addPoint,
        onFinished: stopRecording,
      );
    } else if (obdService.status == ObdConnectionStatus.connected) {
      _runObdLoop();
    } else {
      _isRecording = false;
      _recordingWarning = "Brak połączenia z adapterem — połącz się w zakładce „Połączenie”.";
      notifyListeners();
    }
  }

  /// Pętla odpytywania czujników — sekwencyjna, bez nakładania się komend.
  Future<void> _runObdLoop() async {
    int failedCycles = 0;
    while (_isRecording && obdService.status == ObdConnectionStatus.connected) {
      final values = <String, double>{};
      final pids = obdService.discoveredPids.where((p) => _selectedPidKeys.contains(p.shortName)).toList();

      for (final pid in pids) {
        if (!_isRecording) break;
        final value = await obdService.readPid(pid);
        // Brak odpowiedzi = brak wartości (a nie 0), żeby nie fałszować wykresu i analizy
        if (value != null) values[pid.shortName] = value;
      }

      if (!_isRecording) break;
      if (values.isNotEmpty) {
        failedCycles = 0;
        if (_recordingWarning != null) _recordingWarning = null;
        final elapsed = DateTime.now().difference(_recordingStartTime!).inMilliseconds.toDouble();
        addPoint(LogPoint(timeMs: elapsed, values: values));
      } else {
        failedCycles++;
        if (failedCycles == 3) {
          _recordingWarning = "Sterownik nie odpowiada na zapytania. Sprawdź, czy zapłon jest włączony.";
          notifyListeners();
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// Zatrzymuje nagrywanie i natychmiast analizuje log
  void stopRecording() {
    if (!_isRecording) return;
    _isRecording = false;
    obdService.simulator.stopLivePull();

    final isDiesel = _isDiesel;
    _detectedAnomalies = AnomalyEngine.analyzeSession(_currentPoints, isDiesel: isDiesel);

    if (_currentPoints.isNotEmpty) {
      final now = DateTime.now();
      final info = obdService.vehicleInfo;
      final isSim = obdService.status == ObdConnectionStatus.simulated;
      final usedKeys = <String>{for (final p in _currentPoints) ...p.values.keys};
      final session = LogSession(
        id: now.millisecondsSinceEpoch.toString(),
        title: "${isSim ? 'Symulacja' : 'Log'} ${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)} (${_currentPoints.length} próbek)",
        createdAt: now,
        activePidKeys: _selectedPidKeys.where(usedKeys.contains).toList(),
        points: List.from(_currentPoints),
        isDiesel: isDiesel,
        vehicleLabel: info != null ? "${info.manufacturer} ${info.modelName} • ${info.vin}" : null,
      );
      _activeSession = session;
      _sessionsHistory.insert(0, session);
      if (persistHistory) _saveSession(session);
    }

    notifyListeners();
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  TripReport stopAndGenerateTripReport() {
    stopRecording();
    final session = _activeSession;
    if (session == null || session.points.isEmpty) {
      return const TripReport(
        duration: Duration.zero, distanceKm: 0, totalPoints: 0,
        maxRpm: 0, maxBoostBar: 0, maxEctC: 0, maxIatC: 0, avgLtft: 0,
        aggregatedAnomalies: [], healthScore: 100,
      );
    }
    return AnomalyEngine.generateTripReport(session.points, isDiesel: session.isDiesel);
  }

  /// Dodaje nowy punkt pomiarowy z OBD lub Symulatora
  void addPoint(LogPoint point) {
    _currentPoints.add(point);
    _samplesCountLastSec++;

    final now = DateTime.now();
    final elapsedMs = now.difference(_lastHzCheck).inMilliseconds;
    if (elapsedMs >= 1000) {
      _currentHz = _samplesCountLastSec * 1000.0 / elapsedMs;
      _samplesCountLastSec = 0;
      _lastHzCheck = now;
    }

    notifyListeners();
  }

  /// Ładuje gotowy log demonstracyjny do natychmiastowej analizy
  void loadDemoRun(SimScenario scenario) {
    if (_isRecording) stopRecording();
    _currentPoints = SimulatorService.generateFullRun(scenario);
    _detectedAnomalies = AnomalyEngine.analyzeSession(_currentPoints);
    final keys = <String>{for (final p in _currentPoints) ...p.values.keys};

    _activeSession = LogSession(
      id: "demo_${scenario.name}",
      title: "DEMO: ${scenario.title}",
      createdAt: DateTime.now(),
      activePidKeys: keys.toList(),
      points: List.from(_currentPoints),
      isDemo: true,
    );
    notifyListeners();
  }

  void selectSession(LogSession session) {
    if (_isRecording) return;
    _activeSession = session;
    _currentPoints = List.from(session.points);
    _detectedAnomalies = AnomalyEngine.analyzeSession(_currentPoints, isDiesel: session.isDiesel);
    notifyListeners();
  }

  Future<void> deleteSession(LogSession session) async {
    _sessionsHistory.removeWhere((s) => s.id == session.id);
    if (_activeSession?.id == session.id) {
      _activeSession = null;
      _currentPoints = [];
      _detectedAnomalies = [];
    }
    notifyListeners();
    if (!persistHistory) return;
    try {
      final file = File("${(await _historyDir()).path}/${session.id}.json");
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Trwała historia logów (pliki JSON w katalogu aplikacji)
  // ---------------------------------------------------------------------------

  Future<Directory> _historyDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory("${docs.path}/sessions");
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _saveSession(LogSession session) async {
    try {
      final file = File("${(await _historyDir()).path}/${session.id}.json");
      await file.writeAsString(jsonEncode(session.toJson()));
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd zapisu logu: $e");
    }
  }

  Future<void> _loadHistory() async {
    try {
      final dir = await _historyDir();
      final loaded = <LogSession>[];
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith(".json")) continue;
        try {
          final json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          loaded.add(LogSession.fromJson(json));
        } catch (_) {
          // Uszkodzony plik — pomiń
        }
      }
      loaded.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final existing = _sessionsHistory.map((s) => s.id).toSet();
      _sessionsHistory.addAll(loaded.where((s) => !existing.contains(s.id)));
      _sessionsHistory.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd odczytu historii: $e");
    }
  }

  /// Eksportuje aktywną sesję do pliku CSV i otwiera systemowe udostępnianie (WhatsApp/E-mail)
  Future<String?> exportAndShareCsv() async {
    if (_currentPoints.isEmpty) return null;

    // Kolumny z sesji (a nie z bieżącego wyboru), żeby pasowały do danych
    final keys = _activeSession?.activePidKeys.isNotEmpty == true
        ? _activeSession!.activePidKeys
        : <String>{for (final p in _currentPoints) ...p.values.keys}.toList();

    final StringBuffer buffer = StringBuffer();
    buffer.writeln(["Time_ms", "Time_s", ...keys].join(","));
    for (final p in _currentPoints) {
      final row = [
        p.timeMs.toStringAsFixed(0),
        p.timeSec.toStringAsFixed(3),
        // Brak odczytu = pusta komórka (a nie fałszywe 0)
        ...keys.map((k) => p.values[k]?.toStringAsFixed(2) ?? ""),
      ];
      buffer.writeln(row.join(","));
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final filename = "autocheck_${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.csv";
      final file = File("${dir.path}/$filename");
      await file.writeAsString(buffer.toString());

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: "Log AutoCheck - ${now.toIso8601String()}",
          text: "Log parametrów silnika zarejestrowany przez AutoCheck. "
              "${_activeSession?.vehicleLabel ?? ''} Wykrytych anomalii: ${_detectedAnomalies.length}",
        ),
      );

      return file.path;
    } catch (e) {
      if (kDebugMode) debugPrint("Błąd eksportu CSV: $e");
      return null;
    }
  }

  @override
  void dispose() {
    obdService.removeListener(_onObdChanged);
    super.dispose();
  }
}
