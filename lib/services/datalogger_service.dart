import 'dart:async';
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

  bool _isRecording = false;
  List<LogPoint> _currentPoints = [];
  List<Anomaly> _detectedAnomalies = [];
  final List<LogSession> _sessionsHistory = [];
  LogSession? _activeSession;
  Timer? _pollTimer;
  DateTime? _recordingStartTime;

  // Wybrane czujniki do logowania
  Set<String> _selectedPidKeys = {"RPM", "BOOST", "MAF", "IGN", "TPS", "AFR"};

  // Licznik częstotliwości próbkowania (Hz)
  int _samplesCountLastSec = 0;
  double _currentHz = 0.0;
  DateTime _lastHzCheck = DateTime.now();

  DataloggerService({required this.obdService}) {
    // Wczytaj początkowy wzorcowy log
    loadDemoRun(SimScenario.boostLeak);
  }

  bool get isRecording => _isRecording;
  List<LogPoint> get currentPoints => _currentPoints;
  List<Anomaly> get detectedAnomalies => _detectedAnomalies;
  List<LogSession> get sessionsHistory => _sessionsHistory;
  LogSession? get activeSession => _activeSession;
  Set<String> get selectedPidKeys => _selectedPidKeys;
  double get currentHz => _currentHz;

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
    _selectedPidKeys = Set.from(preset.pidShortNames);
    notifyListeners();
  }

  /// Rozpoczyna nagrywanie logu z przyspieszenia
  void startRecording() {
    _currentPoints.clear();
    _detectedAnomalies.clear();
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
      // Prawdziwe połączenie OBD — cyklicznie odpytuj czujniki
      _startObdPolling();
    }
  }

  /// Pętla odpytywania prawdziwych czujników OBD z samochodu
  void _startObdPolling() {
    _pollTimer?.cancel();
    // Uruchom sekwencyjną pętlę (nie Timer.periodic!) żeby uniknąć nakładania się komend OBD
    _runObdLoop();
  }

  Future<void> _runObdLoop() async {
    while (_isRecording && obdService.status == ObdConnectionStatus.connected) {
      try {
        final values = <String, double>{};
        
        // Odpytaj każdy wybrany czujnik SEKWENCYJNIE — czekaj na odpowiedź przed wysłaniem następnego
        for (final pidKey in _selectedPidKeys) {
          if (!_isRecording) break;
          
          final pid = obdService.discoveredPids
              .where((p) => p.shortName == pidKey)
              .firstOrNull;
          if (pid != null) {
            final value = await obdService.readPid(pid);
            values[pidKey] = value;
          }
        }

        if (values.isNotEmpty && _isRecording) {
          final elapsed = DateTime.now().difference(_recordingStartTime!).inMilliseconds.toDouble();
          addPoint(LogPoint(timeMs: elapsed, values: values));
        }
      } catch (_) {
        // Ignoruj pojedyncze błędy odczytu, próbuj dalej
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// Zatrzymuje nagrywanie i natychmiast analizuje log
  void stopRecording() {
    if (!_isRecording && _currentPoints.isEmpty) return;
    _isRecording = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    obdService.simulator.stopLivePull();

    // Wykonaj inteligentną analizę usterek
    _detectedAnomalies = AnomalyEngine.analyzeSession(_currentPoints);

    if (_currentPoints.isNotEmpty) {
      final session = LogSession(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: "Log ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')} (${_currentPoints.length} próbek)",
        createdAt: DateTime.now(),
        activePidKeys: List.from(_selectedPidKeys),
        points: List.from(_currentPoints),
      );
      _activeSession = session;
      _sessionsHistory.insert(0, session);
    }

    notifyListeners();
  }

  TripReport stopAndGenerateTripReport() {
    stopRecording();
    if (_activeSession == null || _activeSession!.points.isEmpty) {
      return const TripReport(
        duration: Duration.zero, distanceKm: 0, totalPoints: 0,
        maxRpm: 0, maxBoostBar: 0, maxEctC: 0, maxIatC: 0, avgLtft: 0,
        aggregatedAnomalies: [], healthScore: 100,
      );
    }
    return AnomalyEngine.generateTripReport(_activeSession!.points);
  }

  /// Dodaje nowy punkt pomiarowy z OBD lub Symulatora
  void addPoint(LogPoint point) {
    _currentPoints.add(point);
    _samplesCountLastSec++;

    final now = DateTime.now();
    if (now.difference(_lastHzCheck).inMilliseconds >= 1000) {
      _currentHz = _samplesCountLastSec * 1000.0 / now.difference(_lastHzCheck).inMilliseconds;
      _samplesCountLastSec = 0;
      _lastHzCheck = now;
    }

    notifyListeners();
  }

  /// Ładuje gotowy log demonstracyjny do natychmiastowej analizy
  void loadDemoRun(SimScenario scenario) {
    _isRecording = false;
    _currentPoints = SimulatorService.generateFullRun(scenario);
    _detectedAnomalies = AnomalyEngine.analyzeSession(_currentPoints);

    final session = LogSession(
      id: "demo_${scenario.name}",
      title: scenario.title,
      createdAt: DateTime.now(),
      activePidKeys: List.from(_selectedPidKeys),
      points: List.from(_currentPoints),
    );
    _activeSession = session;
    notifyListeners();
  }

  void selectSession(LogSession session) {
    _activeSession = session;
    _currentPoints = List.from(session.points);
    _detectedAnomalies = AnomalyEngine.analyzeSession(_currentPoints);
    notifyListeners();
  }

  /// Eksportuje sesję do pliku CSV i otwiera systemowe udostępnianie (WhatsApp/E-mail)
  Future<String?> exportAndShareCsv() async {
    if (_currentPoints.isEmpty) return null;

    final StringBuffer buffer = StringBuffer();
    // Nagłówki
    final headers = ["Time_ms", "Time_s", ..._selectedPidKeys];
    buffer.writeln(headers.join(","));

    // Wiersze
    for (final p in _currentPoints) {
      final row = [
        p.timeMs.toStringAsFixed(0),
        p.timeSec.toStringAsFixed(3),
        ..._selectedPidKeys.map((k) => p.values[k]?.toStringAsFixed(2) ?? "0.0"),
      ];
      buffer.writeln(row.join(","));
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final filename = "autocheck_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.csv";
      final file = File("${dir.path}/$filename");
      await file.writeAsString(buffer.toString());

      // Wywołaj okno udostępniania
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: "Log przyspieszenia AutoCheck - ${now.toIso8601String()}",
          text: "Log parametrów silnika zarejestrowany przez AutoCheck (vLinker MC+). Wykrytych anomalii: ${_detectedAnomalies.length}",
        ),
      );

      return file.path;
    } catch (e) {
      if (kDebugMode) print("Błąd eksportu CSV: $e");
      return null;
    }
  }
}
