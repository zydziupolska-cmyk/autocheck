import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/anomaly.dart';
import '../models/log_point.dart';
import '../models/obd_pid.dart';
import 'analysis/drive_state.dart';
import 'anomaly_engine.dart';
import 'obd_service.dart';
import '../models/trip_report.dart';

/// Stan pomiaru przyspieszenia.
enum PullState {
  /// Nie nagrywa.
  idle,

  /// Nagrywa w tle i czeka na wciśnięcie gazu do końca.
  armed,

  /// Trwa przyspieszenie.
  capturing,
}

/// Podsumowanie jazdy diagnostycznej aktualizowane na żywo.
class DriveLiveStats {
  double durationSec = 0;
  double distanceKm = 0;
  double idleSec = 0;
  double fullThrottleSec = 0;
  int pullsDetected = 0;
  double maxBoost = double.nan;
  double maxEct = double.nan;

  /// Podpowiedzi, czego jeszcze brakuje do pełnej diagnozy.
  List<String> hints(Set<String> keys, {required bool isDiesel}) {
    final out = <String>[];
    if (pullsDetected == 0 && durationSec > 60) {
      out.add("Wykonaj przynajmniej jedno mocne przyspieszenie (np. 3. bieg od ok. 1500 obr/min, gaz do końca) — bez tego nie da się ocenić turbo i paliwa pod obciążeniem.");
    }
    if (idleSec < 30 && durationSec > 120) {
      out.add("Zatrzymaj się na ok. 30 s na wolnych obrotach — pozwoli to ocenić bieg jałowy.");
    }
    if (keys.contains("ECT") && maxEct.isFinite && maxEct < 75 && durationSec > 600) {
      out.add("Silnik wciąż jest niedogrzany (${maxEct.toStringAsFixed(0)}°C) — kontynuuj jazdę; po 10+ min to może oznaczać otwarty termostat.");
    }
    return out;
  }
}

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
  Set<String> _selectedPidKeys = {"RPM", "PEDAL", "TPS", "BOOST", "TARGET_BOOST", "MAF"};

  // Częstotliwość próbkowania (pełnych cykli odczytu na sekundę)
  int _samplesCountLastSec = 0;
  double _currentHz = 0.0;
  DateTime _lastHzCheck = DateTime.now();

  ObdConnectionStatus? _lastObdStatus;

  // --- Tryby pomiaru ---
  LogMode _mode = LogMode.pull;
  PullState _pullState = PullState.idle;
  String? _pullMessage;
  final Map<String, double> _latest = {}; // ostatnie znane wartości (do wykrywania stanu)
  int _pullStartIndex = 0;
  double _pullStartMs = 0;
  double _pullPeakRpm = 0;
  double _pullStartRpm = 0;
  double? _releaseSinceMs;

  // --- Jazda diagnostyczna ---
  final DriveLiveStats _live = DriveLiveStats();
  bool _liveInPull = false;
  double _liveWotStartMs = 0;
  double _liveWotStartRpm = 0;
  double _liveWotPeakRpm = 0;
  String? _sessionId;
  DateTime _lastAutosave = DateTime.now();

  static const int _pullPreRollMs = 1000;

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
  LogMode get mode => _mode;
  PullState get pullState => _pullState;
  String? get pullMessage => _pullMessage;
  DriveLiveStats get liveStats => _live;
  Map<String, double> get latestValues => _latest;

  /// Ostrzeżenie w trakcie nagrywania (np. ECU przestało odpowiadać).
  String? get recordingWarning => _recordingWarning;

  bool get _isDiesel => obdService.vehicleInfo?.isDiesel ?? false;

  /// Tekst do rozpoznania silnika w bazie silników (producent, opis, CALID, model, VIN).
  String get _engineInfo {
    final v = obdService.vehicleInfo;
    if (v == null) return "";
    return [v.manufacturer, v.modelName, v.engineDescription, v.calibrationId, v.ecuName, v.vin].join(" ");
  }

  void setMode(LogMode mode) {
    if (_isRecording) return;
    _mode = mode;
    notifyListeners();
  }

  /// Po połączeniu z prawdziwym autem wybierz automatycznie wszystko, czego
  /// potrzebuje Asystent (i co ECU faktycznie obsługuje).
  int _lastDiscoveredCount = 0;

  void _onObdChanged() {
    final status = obdService.status;
    // Nowe parametry po imporcie definicji w trakcie połączenia — dołącz te, których
    // potrzebuje Asystent (np. korekty wtryskiwaczy)
    if (status == _lastObdStatus && status == ObdConnectionStatus.connected &&
        obdService.discoveredPids.length != _lastDiscoveredCount) {
      _lastDiscoveredCount = obdService.discoveredPids.length;
      final auto = LoggingPreset.presets.first.pidShortNames.toSet();
      _selectedPidKeys.addAll(obdService.discoveredPids.map((p) => p.shortName).where(auto.contains));
      notifyListeners();
      return;
    }
    if (status == _lastObdStatus) return;
    _lastObdStatus = status;
    _lastDiscoveredCount = obdService.discoveredPids.length;

    if (status == ObdConnectionStatus.connected) {
      final available = obdService.discoveredPids.map((p) => p.shortName).toSet();
      final auto = LoggingPreset.presets.first.pidShortNames;
      var selection = auto.where(available.contains).toSet();
      // W dieslu TPS to klapa dławiąca, a AFR/lambda benzynowa nie ma sensu
      if (_isDiesel) {
        if (available.contains("PEDAL")) selection.remove("TPS");
        selection.remove("AFR");
      }
      if (selection.isEmpty && available.isNotEmpty) selection = {available.first};
      _selectedPidKeys = selection;
      notifyListeners();
    } else if (_isRecording && status != ObdConnectionStatus.connected) {
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

  /// Kanały profilu przefiltrowane do tych, które auto naprawdę udostępnia
  /// (w dieslu bez TPS, jeśli jest pedał). To samo, co ustawia [applyPreset].
  Set<String> _presetSelection(LoggingPreset preset) {
    final available = obdService.discoveredPids.map((p) => p.shortName).toSet();
    final filtered = preset.pidShortNames.where(available.contains).toSet();
    if (_isDiesel && filtered.contains("PEDAL")) filtered.remove("TPS");
    return filtered.isNotEmpty ? filtered : {"RPM"};
  }

  void applyPreset(LoggingPreset preset) {
    _selectedPidKeys = _presetSelection(preset);
    notifyListeners();
  }

  /// Czy aktualny wybór kanałów dokładnie odpowiada temu profilowi (po odfiltrowaniu
  /// kanałów nieobsługiwanych przez auto).
  bool isPresetApplied(LoggingPreset preset) {
    final target = _presetSelection(preset);
    return target.length == _selectedPidKeys.length && target.every(_selectedPidKeys.contains);
  }

  /// Rozpoczyna nagrywanie. W trybie przyspieszenia rejestrator „uzbraja się”
  /// i sam wyłapie moment wciśnięcia gazu do końca.
  void startRecording() {
    if (_isRecording) return;
    _currentPoints = [];
    _detectedAnomalies = [];
    _recordingWarning = null;
    _pullMessage = null;
    _latest.clear();
    _isRecording = true;
    _lastHzCheck = DateTime.now();
    _samplesCountLastSec = 0;
    _currentHz = 0.0;
    _recordingStartTime = DateTime.now();
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _lastAutosave = DateTime.now();

    _pullState = _mode == LogMode.pull ? PullState.armed : PullState.idle;
    _releaseSinceMs = null;
    _live
      ..durationSec = 0
      ..distanceKm = 0
      ..idleSec = 0
      ..fullThrottleSec = 0
      ..pullsDetected = 0
      ..maxBoost = double.nan
      ..maxEct = double.nan;
    _liveInPull = false;
    notifyListeners();

    if (obdService.status == ObdConnectionStatus.connected) {
      _runObdLoop();
    } else {
      _isRecording = false;
      _pullState = PullState.idle;
      _recordingWarning = "Brak połączenia z adapterem — połącz się w zakładce „Połączenie”.";
      notifyListeners();
    }
  }

  /// Pętla odpytywania — sekwencyjna, z priorytetami jak w profesjonalnych loggerach:
  /// szybkie kanały (obroty, pedał, doładowanie) w każdym cyklu, normalne co 2 cykle,
  /// wolne (temperatury, liczniki) co 8 cykli. Kanały z tego samego zapytania
  /// (np. zadane i rzeczywiste doładowanie) są odczytywane razem.
  Future<void> _runObdLoop() async {
    int failedCycles = 0;
    int cycle = 0;
    while (_isRecording && obdService.status == ObdConnectionStatus.connected) {
      final due = _dueChannels(cycle++);
      final values = await obdService.readPids(due);

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

  List<ObdPid> _dueChannels(int cycle) {
    final selected = obdService.discoveredPids.where((p) => _selectedPidKeys.contains(p.shortName)).toList();
    // Grupy według zapytania — kanał grupy dziedziczy najszybszy priorytet
    final groups = <String, List<ObdPid>>{};
    for (final p in selected) {
      groups.putIfAbsent(p.command.toUpperCase(), () => []).add(p);
    }
    final capturing = _pullState == PullState.capturing;
    final due = <ObdPid>[];
    int normalIdx = 0;
    int slowIdx = 0;
    for (final group in groups.values) {
      final rate = group.map((p) => p.rate).reduce((a, b) => a.index < b.index ? a : b);
      final bool isDue;
      switch (rate) {
        case PollRate.fast:
          isDue = true;
        case PollRate.normal:
          isDue = (normalIdx++ + cycle) % 2 == 0;
        case PollRate.slow:
          // W trakcie przyspieszenia wolne kanały czekają — maksymalna częstotliwość
          isDue = !capturing && (slowIdx++ + cycle) % 8 == 0;
      }
      if (isDue) due.addAll(group);
    }
    return due;
  }

  /// Zatrzymuje nagrywanie i natychmiast analizuje log
  void stopRecording() {
    if (!_isRecording) return;
    _isRecording = false;
    final wasPull = _mode == LogMode.pull;
    final pullCaptured = wasPull && _pullState == PullState.capturing;
    _pullState = PullState.idle;

    // W trybie przyspieszenia przerwanym ręcznie zachowujemy tylko samo przyspieszenie
    if (pullCaptured) {
      _currentPoints = _currentPoints.sublist(_pullStartIndex);
    } else if (wasPull && _currentPoints.isNotEmpty) {
      _pullMessage = "Nie wykryto przyspieszenia (gazu wciśniętego do końca) — log zapisano w całości.";
    }

    _finishSession(wasPull ? LogMode.pull : LogMode.drive);
  }

  void _finishSession(LogMode mode) {
    final isDiesel = _isDiesel;
    _detectedAnomalies = AnomalyEngine.analyzeSession(_currentPoints, isDiesel: isDiesel, engineInfo: _engineInfo);

    if (_currentPoints.isNotEmpty) {
      final session = _buildSession(mode);
      _activeSession = session;
      _sessionsHistory.removeWhere((s) => s.id == session.id);
      _sessionsHistory.insert(0, session);
      if (persistHistory) _saveSession(session);
      // Kody błędów ze sterowników są dla Asystenta dodatkowym dowodem (np. P0087 + P0301)
      if (obdService.status == ObdConnectionStatus.connected) _attachDtcs(session);
    }
    notifyListeners();
  }

  bool _readingDtcs = false;

  /// Czy trwa odczyt kodów błędów po zakończeniu logu (analiza zostanie uzupełniona).
  bool get isReadingDtcs => _readingDtcs;

  Future<void> _attachDtcs(LogSession session) async {
    _readingDtcs = true;
    notifyListeners();
    try {
      final codes = await obdService.readDtcCodes();
      if (codes == null) return;
      final list = codes.map((c) => c.code).toSet().toList();
      final updated = session.withDtcCodes(list);
      final idx = _sessionsHistory.indexWhere((s) => s.id == session.id);
      if (idx >= 0) _sessionsHistory[idx] = updated;
      if (_activeSession?.id == session.id) {
        _activeSession = updated;
        _detectedAnomalies = AnomalyEngine.analyzeSession(updated.points, isDiesel: updated.isDiesel, dtcCodes: list, engineInfo: updated.engineInfo);
      }
      if (persistHistory) await _saveSession(updated);
    } finally {
      _readingDtcs = false;
      notifyListeners();
    }
  }

  LogSession _buildSession(LogMode mode) {
    final now = DateTime.now();
    final info = obdService.vehicleInfo;
    final usedKeys = <String>{for (final p in _currentPoints) ...p.values.keys};
    final label = mode == LogMode.pull ? "Przyspieszenie" : "Jazda";
    return LogSession(
      id: _sessionId ?? now.millisecondsSinceEpoch.toString(),
      title: "$label ${_two(now.hour)}:${_two(now.minute)} (${(_currentPoints.isEmpty ? 0 : (_currentPoints.last.timeMs - _currentPoints.first.timeMs) / 1000).toStringAsFixed(0)} s)",
      createdAt: _recordingStartTime ?? now,
      activePidKeys: usedKeys.toList(),
      points: List.from(_currentPoints),
      isDiesel: _isDiesel,
      vehicleLabel: info != null ? "${info.manufacturer} ${info.modelName} • ${info.vin}" : null,
      engineInfo: _engineInfo,
      mode: mode,
    );
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
    return AnomalyEngine.generateTripReport(session.points, isDiesel: session.isDiesel, dtcCodes: session.dtcCodes);
  }

  /// Dodaje nowy punkt pomiarowy
  void addPoint(LogPoint point) {
    final prevTime = _currentPoints.isNotEmpty ? _currentPoints.last.timeMs : point.timeMs;
    _currentPoints.add(point);
    _latest.addAll(point.values);
    _samplesCountLastSec++;

    final now = DateTime.now();
    final elapsedMs = now.difference(_lastHzCheck).inMilliseconds;
    if (elapsedMs >= 1000) {
      _currentHz = _samplesCountLastSec * 1000.0 / elapsedMs;
      _samplesCountLastSec = 0;
      _lastHzCheck = now;
    }

    if (_isRecording) {
      if (_mode == LogMode.pull) {
        _updatePull(point);
      } else {
        _updateDrive(point, (point.timeMs - prevTime) / 1000.0);
      }
    }
    notifyListeners();
  }

  /// Wykrywanie przyspieszenia: start przy pełnym gazie, koniec po zdjęciu gazu,
  /// spadku obrotów (zmiana biegu / odcięcie) lub po 30 s.
  void _updatePull(LogPoint point) {
    if (!_isRecording) return;
    final diesel = _isDiesel;
    final rpm = _latest["RPM"];

    if (_pullState == PullState.armed) {
      if (DriveState.isFullThrottle(_latest, isDiesel: diesel) && rpm != null) {
        _pullState = PullState.capturing;
        _pullStartMs = point.timeMs;
        _pullStartRpm = rpm;
        _pullPeakRpm = rpm;
        _releaseSinceMs = null;
        // Zachowaj ok. 1 s przed startem (widać, jak turbo zaczyna się budzić)
        final preRoll = point.timeMs - _pullPreRollMs;
        _pullStartIndex = _currentPoints.indexWhere((p) => p.timeMs >= preRoll);
        if (_pullStartIndex < 0) _pullStartIndex = _currentPoints.length - 1;
        _pullMessage = null;
      } else {
        // Uzbrojony: trzymaj tylko ostatnie kilka sekund
        final cutoff = point.timeMs - 3000;
        final firstKeep = _currentPoints.indexWhere((p) => p.timeMs >= cutoff);
        if (firstKeep > 50) _currentPoints = _currentPoints.sublist(firstKeep);
      }
      return;
    }

    if (_pullState != PullState.capturing) return;
    if (rpm != null && rpm > _pullPeakRpm) _pullPeakRpm = rpm;

    final released = DriveState.isThrottleReleased(_latest, isDiesel: diesel);
    if (released) {
      _releaseSinceMs ??= point.timeMs;
    } else {
      _releaseSinceMs = null;
    }
    final rpmDropped = rpm != null && rpm < _pullPeakRpm - 400;
    final tooLong = point.timeMs - _pullStartMs > 30000;
    final releasedLongEnough = _releaseSinceMs != null && point.timeMs - _releaseSinceMs! >= 300;
    if (!(rpmDropped || tooLong || releasedLongEnough)) return;

    final duration = point.timeMs - _pullStartMs;
    final gain = _pullPeakRpm - _pullStartRpm;
    if (duration >= 1500 && gain >= 1000) {
      _currentPoints = _currentPoints.sublist(_pullStartIndex);
      _isRecording = false;
      _pullState = PullState.idle;
      _pullMessage = "Zarejestrowano przyspieszenie ${_pullStartRpm.toStringAsFixed(0)} → ${_pullPeakRpm.toStringAsFixed(0)} obr/min (${(duration / 1000).toStringAsFixed(1)} s).";
      _finishSession(LogMode.pull);
    } else {
      _pullState = PullState.armed;
      _pullMessage = gain < 1000
          ? "Za krótkie przyspieszenie (+${gain.toStringAsFixed(0)} obr/min). Zacznij od niższych obrotów (ok. 1500) i trzymaj gaz do końca aż do wysokich obrotów."
          : "Za krótkie przyspieszenie (${(duration / 1000).toStringAsFixed(1)} s). Trzymaj gaz dłużej.";
    }
  }

  void _updateDrive(LogPoint point, double dtSec) {
    if (dtSec <= 0 || dtSec > 5) dtSec = 0;
    final diesel = _isDiesel;
    _live.durationSec = (point.timeMs - _currentPoints.first.timeMs) / 1000.0;
    final speed = _latest["SPEED"];
    if (speed != null) _live.distanceKm += speed * dtSec / 3600.0;
    if (DriveState.isIdle(_latest, isDiesel: diesel)) _live.idleSec += dtSec;
    final boost = _latest["BOOST"];
    if (boost != null && (!_live.maxBoost.isFinite || boost > _live.maxBoost)) _live.maxBoost = boost;
    final ect = _latest["ECT"];
    if (ect != null && (!_live.maxEct.isFinite || ect > _live.maxEct)) _live.maxEct = ect;

    final rpm = _latest["RPM"] ?? 0;
    final wot = DriveState.isFullThrottle(_latest, isDiesel: diesel);
    if (wot) {
      _live.fullThrottleSec += dtSec;
      if (!_liveInPull) {
        _liveInPull = true;
        _liveWotStartMs = point.timeMs;
        _liveWotStartRpm = rpm;
        _liveWotPeakRpm = rpm;
      } else if (rpm > _liveWotPeakRpm) {
        _liveWotPeakRpm = rpm;
      }
    } else if (_liveInPull) {
      _liveInPull = false;
      if (point.timeMs - _liveWotStartMs >= 1500 && _liveWotPeakRpm - _liveWotStartRpm >= 1000) {
        _live.pullsDetected++;
      }
    }

    // Autozapis co minutę — długa jazda nie przepadnie przy awarii aplikacji
    if (persistHistory && DateTime.now().difference(_lastAutosave).inSeconds >= 60) {
      _lastAutosave = DateTime.now();
      _saveSession(_buildSession(LogMode.drive));
    }
  }

  void selectSession(LogSession session) {
    if (_isRecording) return;
    _activeSession = session;
    _currentPoints = List.from(session.points);
    _detectedAnomalies = AnomalyEngine.analyzeSession(_currentPoints, isDiesel: session.isDiesel, dtcCodes: session.dtcCodes, engineInfo: session.engineInfo);
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

  /// Eksportuje sesję do pliku CSV i otwiera systemowe udostępnianie (WhatsApp/E-mail).
  /// Bez [session] — sesja aktywna (bieżące nagranie albo log wczytany na wykres).
  Future<String?> exportAndShareCsv({LogSession? session}) async {
    final points = session?.points ?? _currentPoints;
    if (points.isEmpty) return null;
    final source = session ?? _activeSession;

    // Kolumny z sesji (a nie z bieżącego wyboru), żeby pasowały do danych
    final keys = source?.activePidKeys.isNotEmpty == true
        ? source!.activePidKeys
        : <String>{for (final p in points) ...p.values.keys}.toList();
    final anomalyCount = session == null
        ? _detectedAnomalies.length
        : AnomalyEngine.analyzeSession(points, isDiesel: session.isDiesel, dtcCodes: session.dtcCodes, engineInfo: session.engineInfo).length;

    final StringBuffer buffer = StringBuffer();
    buffer.writeln(["Time_ms", "Time_s", ...keys].join(","));
    for (final p in points) {
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
      final now = source?.createdAt ?? DateTime.now();
      final filename = "dynomic_${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.csv";
      final file = File("${dir.path}/$filename");
      await file.writeAsString(buffer.toString());

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: "Log Dynomic Diag - ${source?.title ?? now.toIso8601String()}",
          text: "Log parametrów silnika zarejestrowany przez Dynomic Diag. "
              "${source?.vehicleLabel ?? ''} Wykrytych anomalii: $anomalyCount",
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
