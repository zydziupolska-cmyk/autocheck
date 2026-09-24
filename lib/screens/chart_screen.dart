import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
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
  final Set<String> _visibleChannels = {"RPM", "BOOST", "IGN", "AFR", "F_RAIL", "STFT"};

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
                _buildChannelToggles(),

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
              "Zarejestruj przyspieszenie w zakładce 'Rejestrator' lub załaduj gotowy log z symulatora.",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () {
                logger.loadDemoRun(logger.obdService.selectedScenario);
              },
              icon: const Icon(Icons.play_circle),
              label: const Text("Wczytaj przykładowy log z usterką"),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.cyan, foregroundColor: Colors.black),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelToggles() {
    final channels = [
      {"key": "RPM", "label": "RPM", "color": AppTheme.blue},
      {"key": "BOOST", "label": "Boost", "color": AppTheme.cyan},
      {"key": "IGN", "label": "Zapłon", "color": AppTheme.orange},
      {"key": "AFR", "label": "AFR", "color": AppTheme.purple},
      {"key": "F_RAIL", "label": "Szyna paliwa", "color": const Color(0xFFFF0055)},
      {"key": "STFT", "label": "Korekta %", "color": AppTheme.yellow},
      {"key": "MAF", "label": "MAF", "color": AppTheme.green},
      {"key": "DPF_DP", "label": "DPF ΔP", "color": const Color(0xFFD00000)},
      {"key": "EGT", "label": "EGT °C", "color": const Color(0xFFFF5400)},
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: AppTheme.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: channels.map((ch) {
            final key = ch["key"] as String;
            final isVisible = _visibleChannels.contains(key);
            final color = ch["color"] as Color;

            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(ch["label"] as String),
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
            if (_visibleChannels.contains("RPM"))
              Padding(padding: const EdgeInsets.only(right: 10), child: Text("RPM: ${p.rpm.toInt()}", style: const TextStyle(color: AppTheme.blue, fontWeight: FontWeight.bold, fontSize: 12))),
            if (_visibleChannels.contains("BOOST"))
              Padding(padding: const EdgeInsets.only(right: 10), child: Text("Boost: ${p.boost.toStringAsFixed(2)}b", style: const TextStyle(color: AppTheme.cyan, fontWeight: FontWeight.bold, fontSize: 12))),
            if (_visibleChannels.contains("IGN"))
              Padding(padding: const EdgeInsets.only(right: 10), child: Text("Ign: ${p.ign.toStringAsFixed(1)}°", style: const TextStyle(color: AppTheme.orange, fontWeight: FontWeight.bold, fontSize: 12))),
            if (_visibleChannels.contains("AFR"))
              Padding(padding: const EdgeInsets.only(right: 10), child: Text("AFR: ${p.afr.toStringAsFixed(1)}", style: const TextStyle(color: AppTheme.purple, fontWeight: FontWeight.bold, fontSize: 12))),
            if (_visibleChannels.contains("F_RAIL") && p.values.containsKey("F_RAIL"))
              Padding(padding: const EdgeInsets.only(right: 10), child: Text("Szyna: ${p.values["F_RAIL"]!.toStringAsFixed(1)}b", style: const TextStyle(color: Color(0xFFFF0055), fontWeight: FontWeight.bold, fontSize: 12))),
            if (_visibleChannels.contains("STFT"))
              Padding(padding: const EdgeInsets.only(right: 10), child: Text("STFT: ${p.stft.toStringAsFixed(1)}%", style: const TextStyle(color: AppTheme.yellow, fontWeight: FontWeight.bold, fontSize: 12))),
            if (_visibleChannels.contains("MAF"))
              Padding(padding: const EdgeInsets.only(right: 10), child: Text("MAF: ${p.maf.toStringAsFixed(0)}g", style: const TextStyle(color: AppTheme.green, fontWeight: FontWeight.bold, fontSize: 12))),
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

    if (_visibleChannels.contains("RPM")) {
      lineBars.add(LineChartBarData(
        spots: points.map((p) => FlSpot(p.timeSec, (p.rpm / 7500.0 * 100.0).clamp(0, 100))).toList(),
        isCurved: true,
        color: AppTheme.blue,
        barWidth: 2.5,
        dotData: const FlDotData(show: false),
      ));
    }

    if (_visibleChannels.contains("BOOST")) {
      lineBars.add(LineChartBarData(
        spots: points.map((p) => FlSpot(p.timeSec, ((p.boost + 1.0) / 3.5 * 100.0).clamp(0, 100))).toList(),
        isCurved: true,
        color: AppTheme.cyan,
        barWidth: 3.0,
        dotData: const FlDotData(show: false),
      ));
    }

    if (_visibleChannels.contains("IGN")) {
      lineBars.add(LineChartBarData(
        spots: points.map((p) => FlSpot(p.timeSec, ((p.ign + 10.0) / 45.0 * 100.0).clamp(0, 100))).toList(),
        isCurved: true,
        color: AppTheme.orange,
        barWidth: 2.2,
        dotData: const FlDotData(show: false),
      ));
    }

    if (_visibleChannels.contains("AFR")) {
      lineBars.add(LineChartBarData(
        spots: points.map((p) => FlSpot(p.timeSec, ((p.afr - 9.0) / 9.0 * 100.0).clamp(0, 100))).toList(),
        isCurved: true,
        color: AppTheme.purple,
        barWidth: 2.5,
        dotData: const FlDotData(show: false),
      ));
    }

    if (_visibleChannels.contains("MAF")) {
      lineBars.add(LineChartBarData(
        spots: points.map((p) => FlSpot(p.timeSec, (p.maf / 250.0 * 100.0).clamp(0, 100))).toList(),
        isCurved: true,
        color: AppTheme.green,
        barWidth: 2.0,
        dotData: const FlDotData(show: false),
      ));
    }

    if (_visibleChannels.contains("F_RAIL") && points.any((p) => p.values.containsKey("F_RAIL"))) {
      lineBars.add(LineChartBarData(
        spots: points.map((p) => FlSpot(p.timeSec, (((p.values["F_RAIL"] ?? 0.0) / 200.0) * 100.0).clamp(0, 100))).toList(),
        isCurved: true,
        color: const Color(0xFFFF0055),
        barWidth: 2.8,
        dotData: const FlDotData(show: false),
      ));
    }

    if (_visibleChannels.contains("STFT") && points.any((p) => p.values.containsKey("STFT"))) {
      lineBars.add(LineChartBarData(
        spots: points.map((p) => FlSpot(p.timeSec, (((p.stft + 25.0) / 50.0) * 100.0).clamp(0, 100))).toList(),
        isCurved: true,
        color: AppTheme.yellow,
        barWidth: 2.2,
        dotData: const FlDotData(show: false),
      ));
    }

    if (_visibleChannels.contains("DPF_DP") && points.any((p) => p.values.containsKey("DPF_DP"))) {
      lineBars.add(LineChartBarData(
        spots: points.map((p) => FlSpot(p.timeSec, (((p.dpfDp) / 60.0) * 100.0).clamp(0, 100))).toList(),
        isCurved: true,
        color: const Color(0xFFD00000),
        barWidth: 2.5,
        dotData: const FlDotData(show: false),
      ));
    }

    if (_visibleChannels.contains("EGT") && points.any((p) => p.values.containsKey("EGT"))) {
      lineBars.add(LineChartBarData(
        spots: points.map((p) => FlSpot(p.timeSec, (((p.egt - 100.0) / 800.0) * 100.0).clamp(0, 100))).toList(),
        isCurved: true,
        color: const Color(0xFFFF5400),
        barWidth: 2.2,
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
