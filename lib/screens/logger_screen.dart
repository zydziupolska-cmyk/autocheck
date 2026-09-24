import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/log_point.dart';
import '../models/obd_pid.dart';
import '../services/datalogger_service.dart';
import '../services/obd_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';
import 'trip_report_screen.dart';

class LoggerScreen extends StatelessWidget {
  final void Function(int tabIndex)? onNavigateToTab;

  const LoggerScreen({super.key, this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    final logger = context.watch<DataloggerService>();
    final obd = context.watch<ObdService>();

    // Ostatnia znana wartość każdego parametru (pojedyncze nieudane odczyty nie zerują odczytów)
    final latest = <String, double>{};
    final pts = logger.currentPoints;
    for (int i = pts.length - 1; i >= 0 && i >= pts.length - 30; i--) {
      pts[i].values.forEach((k, v) => latest.putIfAbsent(k, () => v));
    }
    final gaugeKeys = logger.isRecording || pts.isEmpty
        ? logger.selectedPidKeys.toList()
        : (logger.activeSession?.activePidKeys ?? logger.selectedPidKeys.toList());

    return Scaffold(
      appBar: AppBar(
        title: const Text("Rejestrator"),
        actions: [
          if (logger.currentPoints.isNotEmpty && !logger.isRecording)
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: "Eksportuj log (CSV)",
              onPressed: () => logger.exportAndShareCsv(),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _vehicleLine(obd, logger),
          const SizedBox(height: 10),
          _modeSelector(logger),
          const SizedBox(height: 10),
          _actionButton(logger),
          if (logger.pullMessage != null) ...[
            const SizedBox(height: 10),
            Notice(logger.pullMessage!, tone: logger.pullState == PullState.armed ? AppTheme.warn : AppTheme.info),
          ],
          const SizedBox(height: 10),
          _metricsBar(logger),
          if (logger.mode == LogMode.drive && logger.isRecording) ...[
            const SizedBox(height: 10),
            _driveLiveCard(logger, obd),
          ],
          const SizedBox(height: 10),
          _rpmPanel(latest["RPM"]),
          const SizedBox(height: 10),
          _readoutGrid(latest, gaugeKeys),
          if (!logger.isRecording && logger.currentPoints.isNotEmpty) ...[
            const SizedBox(height: 16),
            _summary(context, logger),
          ],
        ],
      ),
    );
  }

  Widget _vehicleLine(ObdService obd, DataloggerService logger) {
    if (logger.recordingWarning != null) {
      return Notice(logger.recordingWarning!, tone: AppTheme.fault, icon: Icons.error_outline);
    }
    final connected = obd.status == ObdConnectionStatus.connected;
    final v = obd.vehicleInfo;
    final title = connected
        ? (v != null ? "${v.manufacturer} ${v.modelName}${v.isDiesel ? ' • diesel' : ''}" : "Pojazd")
        : "Brak połączenia";
    final sub = connected
        ? "Na żywo • ${obd.discoveredPids.length} parametrów"
        : "Połącz się z adapterem w zakładce Połączenie";
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          StatusDot(connected ? AppTheme.ok : AppTheme.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                Text(sub, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeSelector(DataloggerService logger) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<LogMode>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: LogMode.pull, label: Text("Przyspieszenie")),
          ButtonSegment(value: LogMode.drive, label: Text("Jazda diagnostyczna")),
        ],
        selected: {logger.mode},
        onSelectionChanged: logger.isRecording ? null : (s) => logger.setMode(s.first),
      ),
    );
  }

  static (String, String, IconData) _buttonTexts(DataloggerService logger) {
    if (logger.mode == LogMode.pull) {
      switch (logger.pullState) {
        case PullState.armed:
          return ("Czekam na pełny gaz", "Pomiar zacznie się sam. Dotknij, aby anulować", Icons.hourglass_top);
        case PullState.capturing:
          return ("Pomiar trwa", "Trzymaj gaz do końca, aż do wysokich obrotów", Icons.stop);
        case PullState.idle:
          return ("Zacznij pomiar", "3. bieg, ok. 1500 obr/min, potem gaz do końca", Icons.play_arrow);
      }
    }
    return logger.isRecording
        ? ("Zakończ i analizuj", "Jedź normalnie, zrób 1–2 mocne przyspieszenia", Icons.stop)
        : ("Zacznij jazdę diagnostyczną", "15–30 min jazdy, analiza całej trasy na końcu", Icons.play_arrow);
  }

  Widget _actionButton(DataloggerService logger) {
    final isRec = logger.isRecording;
    final (title, subtitle, icon) = _buttonTexts(logger);
    // Nagrywanie: neutralny przycisk z czerwoną obwódką — czerwone wypełnienie tylko dla startu
    final bg = isRec ? AppTheme.surfaceLight : AppTheme.accent;
    final fg = isRec ? AppTheme.textPrimary : AppTheme.onAccent;
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: isRec ? const BorderSide(color: AppTheme.accent, width: 1.5) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: () => isRec ? logger.stopRecording() : logger.startRecording(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Icon(icon, color: isRec ? AppTheme.accent : fg, size: 30),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(color: fg.withAlpha(215), fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metricsBar(DataloggerService logger) {
    final elapsedSec = logger.currentPoints.isEmpty
        ? 0.0
        : (logger.currentPoints.last.timeMs - logger.currentPoints.first.timeMs) / 1000.0;
    final faults = logger.detectedAnomalies.length;
    Widget cell(String label, String value, {Color color = AppTheme.textPrimary}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                Text(value, style: AppTheme.readout.copyWith(fontSize: 15, color: color)),
              ],
            ),
          ),
        );
    const div = VerticalDivider(width: 1);
    return Panel(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          children: [
            cell("Czas", "${elapsedSec.toStringAsFixed(1)} s"),
            div,
            cell("Częstość", "${logger.currentHz.toStringAsFixed(0)} Hz"),
            div,
            cell("Próbki", "${logger.currentPoints.length}"),
            div,
            cell("Usterki", logger.currentPoints.isEmpty ? "—" : "$faults", color: faults > 0 ? AppTheme.fault : AppTheme.textPrimary),
          ],
        ),
      ),
    );
  }

  Widget _driveLiveCard(DataloggerService logger, ObdService obd) {
    final s = logger.liveStats;
    final keys = logger.latestValues.keys.toSet();
    final hints = s.hints(keys, isDiesel: obd.vehicleInfo?.isDiesel ?? false);
    String mmss(double sec) => "${(sec ~/ 60)}:${(sec % 60).toInt().toString().padLeft(2, '0')}";
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel("Zebrane dane"),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              Readout(label: "Czas jazdy", value: mmss(s.durationSec), size: 17),
              Readout(label: "Dystans", value: s.distanceKm.toStringAsFixed(1), unit: "km", size: 17),
              Readout(label: "Przyspieszenia", value: "${s.pullsDetected}", size: 17),
              Readout(label: "Bieg jałowy", value: mmss(s.idleSec), size: 17),
              if (s.maxBoost.isFinite) Readout(label: "Maks. doładowanie", value: s.maxBoost.toStringAsFixed(2), unit: "bar", size: 17),
            ],
          ),
          for (final h in hints) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.arrow_right, color: AppTheme.warn, size: 18)),
                const SizedBox(width: 4),
                Expanded(child: Text(h, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12.5))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _rpmPanel(double? rpm) {
    final r = rpm ?? 0;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Obroty", style: AppTheme.label),
          const SizedBox(height: 2),
          Text.rich(TextSpan(children: [
            TextSpan(
              text: rpm != null ? "${rpm.toInt()}" : "—",
              style: AppTheme.readout.copyWith(fontSize: 30, color: r > 6200 ? AppTheme.fault : AppTheme.textPrimary),
            ),
            const TextSpan(text: "  obr/min", style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          ])),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (r / 7000.0).clamp(0.0, 1.0),
              minHeight: 6,
              color: r > 6200 ? AppTheme.fault : AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final t in const ["0", "1750", "3500", "5250", "7000"])
                Text(t, style: const TextStyle(color: AppTheme.textMuted, fontSize: 10, fontFeatures: AppTheme.tabular)),
            ],
          ),
        ],
      ),
    );
  }

  static int _decimals(String key, String unit) {
    if (key == "BOOST" || key == "TARGET_BOOST" || key == "O2_V" || key == "LAMBDA") return 2;
    if (unit == "%" || unit == "°C" || unit == "km/h" || unit == "obr/min" || unit == "bar" && key.contains("RAIL")) return 0;
    return 1;
  }

  Widget _readoutGrid(Map<String, double> latest, List<String> keys) {
    // Wartości zadane pokazujemy pod rzeczywistymi, a nie jako osobne kafelki
    final targetOf = {for (final e in ObdPid.targetPairs.entries) e.value: e.key};
    final hidden = {"RPM", ...keys.where((k) => ObdPid.targetPairs.containsKey(k) && keys.contains(ObdPid.targetPairs[k]))};
    final tiles = keys.where((k) => !hidden.contains(k)).toList();
    if (tiles.isEmpty) return const SizedBox.shrink();

    Widget tile(String key) {
      final pid = ObdPid.getByShortName(key);
      final unit = pid?.unit ?? "";
      final d = _decimals(key, unit);
      final value = latest[key];
      String? note;
      Color? noteColor;
      final tKey = targetOf[key];
      if (tKey != null && keys.contains(tKey)) {
        final t = latest[tKey];
        if (t != null) {
          note = "zadane ${t.toStringAsFixed(d)}";
          if (value != null && key == "BOOST" && t - value > 0.2) noteColor = AppTheme.fault;
        }
      } else if ((key == "PEDAL" || key == "TPS") && (value ?? 0) > 85) {
        note = "pełny gaz";
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Readout(
          label: pid?.name ?? key,
          value: value == null ? "—" : value.toStringAsFixed(d),
          unit: unit,
          note: note ?? " ",
          noteColor: noteColor,
          size: 19,
        ),
      );
    }

    final rows = <Widget>[];
    for (int i = 0; i < tiles.length; i += 2) {
      if (i > 0) rows.add(const Divider());
      rows.add(IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: tile(tiles[i])),
            const VerticalDivider(width: 1),
            Expanded(child: i + 1 < tiles.length ? tile(tiles[i + 1]) : const SizedBox()),
          ],
        ),
      ));
    }
    return Panel(padding: EdgeInsets.zero, child: Column(children: rows));
  }

  Widget _summary(BuildContext context, DataloggerService logger) {
    final anomalies = logger.detectedAnomalies;
    final hasIssues = anomalies.isNotEmpty;
    return Panel(
      stripe: hasIssues ? AppTheme.fault : AppTheme.ok,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hasIssues ? "Wykryte usterki: ${anomalies.length}" : "Bez usterek",
            style: AppTheme.sectionTitle,
          ),
          const SizedBox(height: 8),
          if (hasIssues)
            for (final a in anomalies.take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text("• ${a.title}", style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
              )
          else
            Text(
              logger.activeSession?.mode == LogMode.pull
                  ? "Doładowanie nadąża za zadanym, a pozostałe parametry są w normie."
                  : "Analiza całej jazdy nie wykazała nieprawidłowości w dostępnych parametrach.",
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => onNavigateToTab?.call(4),
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text("Diagnoza"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => onNavigateToTab?.call(3),
                  icon: const Icon(Icons.show_chart, size: 18),
                  label: const Text("Wykres"),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                final report = logger.stopAndGenerateTripReport();
                Navigator.of(context).push(MaterialPageRoute(builder: (context) => TripReportScreen(report: report)));
              },
              icon: const Icon(Icons.description_outlined, size: 18),
              label: const Text("Raport z trasy"),
            ),
          ),
        ],
      ),
    );
  }
}
