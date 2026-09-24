import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../models/obd_pid.dart';
import '../models/anomaly.dart';
import '../models/log_point.dart';
import '../services/datalogger_service.dart';
import '../theme/app_theme.dart';

class ChartScreen extends StatefulWidget {
  final void Function(int tabIndex)? onNavigateToTab;

  const ChartScreen({super.key, this.onNavigateToTab});

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  // Włączone linie na wykresie
  final Set<String> _visibleChannels = {"RPM", "BOOST", "TARGET_BOOST", "PEDAL", "MAF", "DPF_DP", "IGN"};

  // Aktualnie wskazany punkt dotykiem (Scrub HUD)
  LogPoint? _hoveredPoint;

  // Wybrana anomalia do podświetlenia
  Anomaly? _selectedAnomaly;

  @override
  Widget build(BuildContext context) {
    final logger = Provider.of<DataloggerService>(context);
    final points = logger.currentPoints;
    final anomalies = logger.detectedAnomalies;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.show_chart, color: AppTheme.cyan),
            SizedBox(width: 8),
            Text("Wykres Telemetrii & Anomalii"),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: AppTheme.cyan),
            tooltip: "Udostępnij log CSV",
            onPressed: () => logger.exportAndShareCsv(),
          ),
        ],
      ),
      body: points.isEmpty
          ? _buildEmptyState(context, logger)
          : Column(
              children: [
                // Pasek przełączników kanałów
                _buildChannelToggles(points),

                // Pływający pasek HUD z wartościami w miejscu dotknięcia
                _buildTelemetryHud(points),

                // Pasek wykrytych anomalii (znaczniki do szybkiego skoku)
                if (anomalies.isNotEmpty) _buildAnomaliesQuickBar(anomalies, points),

                // Główny interaktywny wykres
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 16, 16),
                    child: _buildInteractiveChart(points, anomalies),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildEmptyState(BuildContext context, DataloggerService logger) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.analytics_outlined, size: 70, color: AppTheme.textMuted),
            const SizedBox(height: 16),
            const Text(
              "Brak danych pomiarowych",
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Nagraj jazdę w zakładce „Rejestrator” albo wybierz zapisany log w „Historii”.",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  /// Kanały wykresu: klucz, etykieta, kolor, zakres do normalizacji (0-100%),
  /// jednostka i liczba miejsc po przecinku w HUD.
  static final List<_Channel> _channels = [
    _Channel("RPM", "RPM", AppTheme.blue, 0, 7500, "", 0),
    _Channel("BOOST", "Doładowanie", AppTheme.cyan, -1.0, 2.5, "b", 2),
    _Channel("TARGET_BOOST", "Doład. zadane", const Color(0xFF80FFDB), -1.0, 2.5, "b", 2),
    _Channel("PEDAL", "Pedał", const Color(0xFFB5179E), 0, 100, "%", 0),
    _Channel("TPS", "Przepustn.", const Color(0xFF7000FF), 0, 100, "%", 0),
    _Channel("LOAD", "Obciąż.", const Color(0xFF06D6A0), 0, 100, "%", 0),
    _Channel("MAF", "MAF", AppTheme.green, 0, 250, "g", 0),
    _Channel("F_RAIL", "Szyna", const Color(0xFFFF0055), 0, 200, "b", 0),
    _Channel("RAIL_TGT", "Szyna zadana", const Color(0xFFFFB3C1), 0, 200, "b", 0),
    _Channel("VGT_CMD", "VGT zadane", const Color(0xFFF72585), 0, 100, "%", 0),
    _Channel("VGT_ACT", "VGT", const Color(0xFFB5179E), 0, 100, "%", 0),
    _Channel("EGR_CMD", "EGR zadane", const Color(0xFF9C27B0), 0, 100, "%", 0),
    _Channel("EGR_ACT", "EGR", const Color(0xFFCE93D8), 0, 100, "%", 0),
    _Channel("DPF_DP", "DPF ΔP", const Color(0xFFD00000), 0, 60, "kPa", 1),
    _Channel("EXH_P", "Ciśn. spalin", const Color(0xFFFF6D00), 90, 350, "kPa", 0),
    _Channel("EGT", "EGT", const Color(0xFFFF5400), 100, 900, "°C", 0),
    _Channel("IGN", "Zapłon", AppTheme.orange, -10, 35, "°", 1),
    _Channel("AFR", "AFR", AppTheme.purple, 9, 18, "", 1),
    _Channel("LAMBDA", "Lambda", const Color(0xFFFF4D6D), 0.7, 3.0, "", 2),
    _Channel("LAMBDA_CMD", "Lambda zad.", const Color(0xFFFFB3C6), 0.7, 3.0, "", 2),
    _Channel("STFT", "STFT", AppTheme.yellow, -25, 25, "%", 1),
    _Channel("LTFT", "LTFT", const Color(0xFFFB5607), -25, 25, "%", 1),
    _Channel("TQ_DEMAND", "Moment żąd.", const Color(0xFFFFD166), 0, 100, "%", 0),
    _Channel("TQ_ACT", "Moment", const Color(0xFFEF476F), 0, 100, "%", 0),
    _Channel("SPEED", "Prędkość", const Color(0xFF9D4EDD), 0, 200, "km/h", 0),
    _Channel("IAT", "IAT", const Color(0xFF4CC9F0), -10, 80, "°C", 0),
    _Channel("ECT", "ECT", const Color(0xFF4361EE), 0, 120, "°C", 0),
  ];

  /// Kanał „zadany” (rysowany linią przerywaną na skali swojego rzeczywistego odpowiednika).
  static bool _isTarget(String key) => ObdPid.targetPairs.containsKey(key);

  /// Zakres osi dla kanału: domyślny rozszerzony do danych; pary zadane/rzeczywiste
  /// mają wspólną skalę, żeby było widać, o ile rzeczywista wartość odbiega od zadanej.
  (double, double) _range(_Channel ch, List<LogPoint> points) {
    final keys = {ch.key};
    ObdPid.targetPairs.forEach((t, a) {
      if (t == ch.key || a == ch.key) keys.addAll([t, a]);
    });
    double lo = ch.min, hi = ch.max;
    for (final p in points) {
      for (final k in keys) {
        final v = p.values[k];
        if (v == null) continue;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (hi - lo < 1e-6) hi = lo + 1;
    return (lo, hi);
  }


  /// Kanały obecne w logu (z dodatkiem rozszerzonych parametrów producenta).
  List<_Channel> _availableChannels(List<LogPoint> points) {
    final keys = <String>{for (final p in points) ...p.values.keys};
    final known = _channels.where((c) => keys.contains(c.key)).toList();
    final knownKeys = _channels.map((c) => c.key).toSet();
    for (final k in keys.where((k) => !knownKeys.contains(k))) {
      final pid = ObdPid.getByShortName(k);
      known.add(_Channel(k, k, pid != null ? Color(pid.colorValue) : AppTheme.textSecondary,
          pid?.minExpected ?? 0, pid?.maxExpected ?? 100, pid?.unit ?? "", 1));
    }
    return known;
  }

  Widget _buildChannelToggles(List<LogPoint> points) {
    final channels = _availableChannels(points);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: AppTheme.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: channels.map((ch) {
            final key = ch.key;
            final isVisible = _visibleChannels.contains(key);
            final color = ch.color;

            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(ch.label),
                selected: isVisible,
                selectedColor: color.withAlpha(50),
                backgroundColor: AppTheme.surfaceLight,
                labelStyle: TextStyle(
                  color: isVisible ? color : AppTheme.textMuted,
                  fontWeight: isVisible ? FontWeight.bold : FontWeight.normal,
                  fontSize: 12,
                ),
                side: BorderSide(color: isVisible ? color : AppTheme.border),
                onSelected: (val) {
                  setState(() {
                    if (val) {
                      _visibleChannels.add(key);
                    } else if (_visibleChannels.length > 1) {
                      _visibleChannels.remove(key);
                    }
                  });
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildTelemetryHud(List<LogPoint> points) {
    final p = _hoveredPoint ?? points.last;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Text(
              "T: ${p.timeSec.toStringAsFixed(2)}s",
              style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(width: 10),
            for (final ch in _availableChannels(points))
              if (_visibleChannels.contains(ch.key))
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    "${ch.label}: ${p.values[ch.key]?.toStringAsFixed(ch.decimals) ?? '—'}${ch.unit}",
                    style: TextStyle(color: ch.color, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnomaliesQuickBar(List<Anomaly> anomalies, List<LogPoint> points) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppTheme.red, size: 16),
            const SizedBox(width: 6),
            const Text(
              "Wykryte strefy:",
              style: TextStyle(color: AppTheme.red, fontSize: 11, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            ...anomalies.map((anom) {
              final isSel = _selectedAnomaly == anom;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  avatar: CircleAvatar(
                    backgroundColor: Color(anom.severityColorHex),
                    radius: 4,
                  ),
                  backgroundColor: isSel ? Color(anom.severityColorHex).withAlpha(50) : AppTheme.surface,
                  side: BorderSide(color: Color(anom.severityColorHex)),
                  label: Text(
                    "${anom.title.split('(').first.trim()} (${anom.startSec.toStringAsFixed(1)}s)",
                    style: TextStyle(
                      color: Color(anom.severityColorHex),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _selectedAnomaly = anom;
                      // Ustaw wskaźnik na środek anomalii
                      final midTime = (anom.startMs + anom.endMs) / 2.0;
                      _hoveredPoint = points.reduce((a, b) =>
                          (a.timeMs - midTime).abs() < (b.timeMs - midTime).abs() ? a : b);
                    });
                    _showAnomalyModal(context, anom);
                  },
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildInteractiveChart(List<LogPoint> points, List<Anomaly> anomalies) {
    final minX = points.first.timeSec;
    final maxX = points.last.timeSec;

    // Linie danych przeskalowane do wspólnej osi 0..100% dla przejrzystości
    final List<LineChartBarData> lineBars = [];

    // Długie logi (np. 30 min jazdy) przerzedzamy do ok. 1500 punktów na linię
    final stride = (points.length / 1500).ceil().clamp(1, 1 << 20);
    for (final ch in _availableChannels(points)) {
      if (!_visibleChannels.contains(ch.key)) continue;
      final (lo, hi) = _range(ch, points);
      // Tylko punkty, w których parametr został faktycznie odczytany —
      // brak odczytu nie jest rysowany jako 0.
      final spots = <FlSpot>[];
      for (int i = 0; i < points.length; i += stride) {
        final v = points[i].values[ch.key];
        if (v == null) continue;
        spots.add(FlSpot(points[i].timeSec, ((v - lo) / (hi - lo) * 100.0).clamp(0, 100).toDouble()));
      }
      if (spots.isEmpty) continue;
      final target = _isTarget(ch.key);
      lineBars.add(LineChartBarData(
        spots: spots,
        isCurved: false,
        color: ch.color,
        barWidth: target ? 1.8 : (ch.key == "BOOST" ? 3.0 : 2.2),
        dashArray: target ? [6, 4] : null,
        dotData: const FlDotData(show: false),
      ));
    }

    // Wycinki stref anomalii (pionowe pasy)
    final List<VerticalRangeAnnotation> annotations = anomalies.map((anom) {
      return VerticalRangeAnnotation(
        x1: anom.startSec,
        x2: anom.endSec,
        color: Color(anom.severityColorHex).withAlpha(45),
      );
    }).toList();

    return LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX,
        minY: 0,
        maxY: 100,
        rangeAnnotations: RangeAnnotations(verticalRangeAnnotations: annotations),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          getDrawingHorizontalLine: (val) => const FlLine(color: AppTheme.border, strokeWidth: 0.5),
          getDrawingVerticalLine: (val) => const FlLine(color: AppTheme.border, strokeWidth: 0.5),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (val, meta) => Text(
                "${val.toInt()}%",
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 9),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (val, meta) => Text(
                "${val.toStringAsFixed(1)}s",
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: AppTheme.border),
        ),
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchedSpots) => [],
          ),
          touchCallback: (event, touchResponse) {
            if (touchResponse != null && touchResponse.lineBarSpots != null && touchResponse.lineBarSpots!.isNotEmpty) {
              final spot = touchResponse.lineBarSpots!.first;
              final targetSec = spot.x;
              final matched = points.reduce((a, b) =>
                  (a.timeSec - targetSec).abs() < (b.timeSec - targetSec).abs() ? a : b);
              setState(() {
                _hoveredPoint = matched;
              });
            }
          },
        ),
        lineBarsData: lineBars,
      ),
    );
  }

  void _showAnomalyModal(BuildContext context, Anomaly anom) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Color(anom.severityColorHex).withAlpha(40),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        anom.severityLabel,
                        style: TextStyle(
                          color: Color(anom.severityColorHex),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text(
                      "${anom.startSec.toStringAsFixed(1)}s - ${anom.endSec.toStringAsFixed(1)}s (${anom.startRpm.toInt()}..${anom.endRpm.toInt()} RPM)",
                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  anom.title,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  anom.observedValueText,
                  style: TextStyle(
                    color: Color(anom.severityColorHex),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),

                // Ostrzeżenie przed mylnym tropem
                if (anom.falseLeadWarning != null) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.orange.withAlpha(25),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.orange),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.psychology_alt, color: AppTheme.orange, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            anom.falseLeadWarning!,
                            style: const TextStyle(color: Color(0xFFFFD166), fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.3),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                // Skorelowane czujniki w tym samym ułamku sekundy
                if (anom.correlatedSignals != null && anom.correlatedSignals!.isNotEmpty) ...[
                  const Text(
                    "STAN INNYCH CZUJNIKÓW W TYM SAMYM PUNKCIE:",
                    style: TextStyle(color: AppTheme.cyan, fontSize: 10.5, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: anom.correlatedSignals!.entries.map((e) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceLight,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppTheme.cyan.withAlpha(80)),
                      ),
                      child: Text(
                        "${e.key}: ${e.value}",
                        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11),
                      ),
                    )).toList(),
                  ),
                  const SizedBox(height: 10),
                ],

                // Co czujniki wykluczają
                if (anom.ruledOutCauses != null && anom.ruledOutCauses!.isNotEmpty) ...[
                  const Text(
                    "CO DEFINITYWNIE WYKLUCZONO:",
                    style: TextStyle(color: AppTheme.green, fontSize: 10.5, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  ...anom.ruledOutCauses!.map((ro) => Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: AppTheme.green, size: 12),
                        const SizedBox(width: 4),
                        Expanded(child: Text(ro, style: const TextStyle(color: AppTheme.green, fontSize: 11))),
                      ],
                    ),
                  )),
                  const SizedBox(height: 10),
                ],

                // Konkluzja przyczynowo-skutkowa
                if (anom.rootCauseConclusion != null) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.purple.withAlpha(25),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.purple),
                    ),
                    child: Text(
                      anom.rootCauseConclusion!,
                      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12, height: 1.35),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                Text(
                  anom.description,
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 16),
                const Text(
                  "Co może być przyczyną usterki?",
                  style: TextStyle(color: AppTheme.cyan, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                ...anom.hypotheses.map((h) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("• ", style: TextStyle(color: AppTheme.cyan, fontSize: 14)),
                          Expanded(
                            child: Text(
                              h,
                              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: 14),
                const Text(
                  "Zalecane kroki naprawcze:",
                  style: TextStyle(color: AppTheme.orange, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                ...anom.recommendations.map((r) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("✓ ", style: TextStyle(color: AppTheme.orange, fontSize: 14)),
                          Expanded(
                            child: Text(
                              r,
                              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.cyan,
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text("Zamknij podpowiedź"),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Channel {
  final String key;
  final String label;
  final Color color;
  final double min;
  final double max;
  final String unit;
  final int decimals;

  const _Channel(this.key, this.label, this.color, this.min, this.max, this.unit, this.decimals);
}
