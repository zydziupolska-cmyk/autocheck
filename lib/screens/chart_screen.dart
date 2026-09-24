import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../models/obd_pid.dart';
import '../models/anomaly.dart';
import '../models/log_point.dart';
import '../services/datalogger_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';
import 'diagnostic_screen.dart';

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
        title: const Text("Wykres"),
        actions: [
          if (points.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: "Eksportuj log (CSV)",
              onPressed: () => logger.exportAndShareCsv(),
            ),
        ],
      ),
      body: points.isEmpty
          ? _buildEmptyState(context, logger)
          : Column(
              children: [
                _buildChannelToggles(points),
                _buildTelemetryHud(points),
                if (anomalies.isNotEmpty) _buildAnomaliesQuickBar(anomalies, points),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 16, 12),
                    child: _buildInteractiveChart(points, anomalies),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildEmptyState(BuildContext context, DataloggerService logger) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.show_chart, size: 40, color: AppTheme.textMuted),
            SizedBox(height: 12),
            Text("Brak danych", style: AppTheme.sectionTitle),
            SizedBox(height: 6),
            Text(
              "Nagraj pomiar w zakładce Rejestrator albo wybierz zapisany log w Historii.",
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
  // Barwy serii: para zadane/rzeczywiste ma jedną barwę (zadane linią przerywaną)
  static const _cRpm = Color(0xFFB9BEC5);
  static const _cBoost = AppTheme.accent;
  static const _cPedal = Color(0xFF9B8AFB);
  static const _cMaf = AppTheme.info;
  static const _cRail = Color(0xFFD9A63E);
  static const _cVgt = Color(0xFF3FB6A8);
  static const _cEgr = Color(0xFFB08968);
  static const _cDpf = Color(0xFFC06CD8);
  static const _cLambda = Color(0xFF57B8FF);
  static const _cTorque = Color(0xFF7BC67E);
  static const _cTemp = Color(0xFFE08A5E);
  static const _cMisc = Color(0xFF8A9099);

  static final List<_Channel> _channels = [
    _Channel("RPM", "Obroty", _cRpm, 0, 7500, "", 0),
    _Channel("BOOST", "Doładowanie", _cBoost, -1.0, 2.5, " bar", 2),
    _Channel("TARGET_BOOST", "Doład. zadane", _cBoost, -1.0, 2.5, " bar", 2),
    _Channel("PEDAL", "Pedał", _cPedal, 0, 100, "%", 0),
    _Channel("TPS", "Przepustnica", _cPedal, 0, 100, "%", 0),
    _Channel("LOAD", "Obciążenie", _cMisc, 0, 100, "%", 0),
    _Channel("MAF", "MAF", _cMaf, 0, 250, " g/s", 0),
    _Channel("F_RAIL", "Szyna", _cRail, 0, 200, " bar", 0),
    _Channel("RAIL_TGT", "Szyna zadana", _cRail, 0, 200, " bar", 0),
    _Channel("VGT_CMD", "VGT zadane", _cVgt, 0, 100, "%", 0),
    _Channel("VGT_ACT", "VGT", _cVgt, 0, 100, "%", 0),
    _Channel("EGR_CMD", "EGR zadane", _cEgr, 0, 100, "%", 0),
    _Channel("EGR_ACT", "EGR", _cEgr, 0, 100, "%", 0),
    _Channel("DPF_DP", "DPF ΔP", _cDpf, 0, 60, " kPa", 1),
    _Channel("EXH_P", "Ciśn. spalin", _cDpf, 90, 350, " kPa", 0),
    _Channel("EGT", "EGT", _cTemp, 100, 900, "°C", 0),
    _Channel("IGN", "Zapłon", _cTemp, -10, 35, "°", 1),
    _Channel("AFR", "AFR", _cLambda, 9, 18, "", 1),
    _Channel("LAMBDA", "Lambda", _cLambda, 0.7, 3.0, "", 2),
    _Channel("LAMBDA_CMD", "Lambda zadana", _cLambda, 0.7, 3.0, "", 2),
    _Channel("STFT", "STFT", _cRail, -25, 25, "%", 1),
    _Channel("LTFT", "LTFT", _cVgt, -25, 25, "%", 1),
    _Channel("TQ_DEMAND", "Moment żądany", _cTorque, 0, 100, "%", 0),
    _Channel("TQ_ACT", "Moment", _cTorque, 0, 100, "%", 0),
    _Channel("SPEED", "Prędkość", _cMisc, 0, 200, " km/h", 0),
    _Channel("IAT", "IAT", _cTemp, -10, 80, "°C", 0),
    _Channel("ECT", "ECT", _cTemp, 0, 120, "°C", 0),
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
      known.add(_Channel(k, pid?.name ?? k, _cMisc,
          pid?.minExpected ?? 0, pid?.maxExpected ?? 100, pid?.unit ?? "", 1));
    }
    return known;
  }

  Widget _buildChannelToggles(List<LogPoint> points) {
    final channels = _availableChannels(points);
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final ch in channels)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
              child: _toggle(ch, _visibleChannels.contains(ch.key)),
            ),
        ],
      ),
    );
  }

  Widget _toggle(_Channel ch, bool on) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      onTap: () => setState(() {
        if (!on) {
          _visibleChannels.add(ch.key);
        } else if (_visibleChannels.length > 1) {
          _visibleChannels.remove(ch.key);
        }
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: on ? AppTheme.surfaceLight : Colors.transparent,
          border: Border.all(color: on ? AppTheme.textMuted : AppTheme.border),
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _swatch(ch, on),
            const SizedBox(width: 6),
            Text(ch.label, style: TextStyle(color: on ? AppTheme.textPrimary : AppTheme.textMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  /// Próbka linii: ciągła dla rzeczywistych, przerywana dla zadanych.
  Widget _swatch(_Channel ch, bool on) {
    final c = on ? ch.color : AppTheme.textMuted;
    if (!_isTarget(ch.key)) return Container(width: 12, height: 2.5, color: c);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 4, height: 2, color: c),
      const SizedBox(width: 2),
      Container(width: 4, height: 2, color: c),
    ]);
  }

  Widget _buildTelemetryHud(List<LogPoint> points) {
    final p = _hoveredPoint ?? points.last;
    final visible = _availableChannels(points).where((c) => _visibleChannels.contains(c.key)).toList();
    Widget cell(String label, String value, Widget? swatch) => Padding(
          padding: const EdgeInsets.only(right: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (swatch != null) ...[swatch, const SizedBox(width: 5)],
                Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              ]),
              Text(value, style: AppTheme.readout.copyWith(fontSize: 15)),
            ],
          ),
        );
    return Panel(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            cell("Czas", "${p.timeSec.toStringAsFixed(1)} s", null),
            for (final ch in visible)
              cell(ch.label, "${p.values[ch.key]?.toStringAsFixed(ch.decimals) ?? '—'}${ch.unit}", _swatch(ch, true)),
          ],
        ),
      ),
    );
  }

  Widget _buildAnomaliesQuickBar(List<Anomaly> anomalies, List<LogPoint> points) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        children: [
          for (final anom in anomalies)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                onTap: () {
                  setState(() {
                    _selectedAnomaly = anom;
                    final midTime = (anom.startMs + anom.endMs) / 2.0;
                    _hoveredPoint = points.reduce((a, b) => (a.timeMs - midTime).abs() < (b.timeMs - midTime).abs() ? a : b);
                  });
                  _showAnomalyModal(context, anom);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: _selectedAnomaly == anom ? AppTheme.surfaceLight : AppTheme.surface,
                    border: Border.all(color: AppTheme.border),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusDot(DiagnosticScreen.toneOf(anom.severity), size: 7),
                      const SizedBox(width: 6),
                      Text(
                        "${anom.title.split('(').first.split('—').first.trim()} • ${anom.startSec.toStringAsFixed(1)} s",
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
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
        barWidth: target ? 1.6 : (ch.key == "BOOST" ? 2.4 : 1.8),
        dashArray: target ? [5, 4] : null,
        dotData: const FlDotData(show: false),
      ));
    }

    // Wycinki stref anomalii (pionowe pasy)
    final List<VerticalRangeAnnotation> annotations = anomalies.map((anom) {
      return VerticalRangeAnnotation(
        x1: anom.startSec,
        x2: anom.endSec,
        // Neutralne pasmo — kolor zostaje dla linii danych
        color: AppTheme.textPrimary.withAlpha(anom == _selectedAnomaly ? 26 : 12),
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
          horizontalInterval: 25,
          getDrawingHorizontalLine: (val) => const FlLine(color: AppTheme.border, strokeWidth: 0.6),
          getDrawingVerticalLine: (val) => const FlLine(color: AppTheme.border, strokeWidth: 0.6),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 25,
              getTitlesWidget: (val, meta) => Text(
                "${val.toInt()}%",
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 9.5, fontFeatures: AppTheme.tabular),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (val, meta) => Text(
                "${val.toStringAsFixed(0)} s",
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 10, fontFeatures: AppTheme.tabular),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
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
        extraLinesData: ExtraLinesData(verticalLines: [
          if (_hoveredPoint != null)
            VerticalLine(x: _hoveredPoint!.timeSec, color: AppTheme.textSecondary, strokeWidth: 1),
        ]),
        lineBarsData: lineBars,
      ),
    );
  }

  void _showAnomalyModal(BuildContext context, Anomaly anom) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [AnomalyCard(anomaly: anom)],
        ),
      ),
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
