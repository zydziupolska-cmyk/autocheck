import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/log_point.dart';
import '../services/datalogger_service.dart';
import '../theme/app_theme.dart';
import 'trip_report_screen.dart';

class LoggerScreen extends StatelessWidget {
  final void Function(int tabIndex)? onNavigateToTab;

  const LoggerScreen({super.key, this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    final logger = Provider.of<DataloggerService>(context);
    final lastPoint = logger.currentPoints.isNotEmpty
        ? logger.currentPoints.last
        : const LogPoint(timeMs: 0, values: {
            "RPM": 850,
            "BOOST": -0.65,
            "MAF": 4.5,
            "IGN": 7.0,
            "TPS": 0,
            "AFR": 14.7,
            "IAT": 24,
            "ECT": 90,
          });

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.speed, color: AppTheme.cyan),
            SizedBox(width: 8),
            Text("Rejestrator Przyspieszenia (WOT)"),
          ],
        ),
        actions: [
          if (logger.currentPoints.isNotEmpty && !logger.isRecording)
            IconButton(
              icon: const Icon(Icons.share, color: AppTheme.cyan),
              tooltip: "Udostępnij log CSV",
              onPressed: () => logger.exportAndShareCsv(),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Pasek statusu pomiaru (czas, Hz, próbki)
            _buildMetricsBar(logger),

            const SizedBox(height: 16),

            // Duży przycisk START / STOP dostosowany do kliknięcia w aucie
            _buildBigActionButton(context, logger),

            const SizedBox(height: 20),

            // Zegary telemetryczne na żywo
            _buildLiveGaugesGrid(lastPoint),

            const SizedBox(height: 16),

            // Karta po zakończonym logu z podsumowaniem i wykrytymi anomaliami
            if (!logger.isRecording && logger.currentPoints.isNotEmpty)
              _buildPostPullSummary(context, logger),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsBar(DataloggerService logger) {
    final elapsedSec = logger.currentPoints.isEmpty
        ? 0.0
        : (logger.currentPoints.last.timeMs - logger.currentPoints.first.timeMs) / 1000.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _metricItem("CZAS LOGU", "${elapsedSec.toStringAsFixed(1)}s", AppTheme.cyan),
          _divider(),
          _metricItem("ODŚWIEŻANIE", "${logger.currentHz.toStringAsFixed(0)} Hz", AppTheme.yellow),
          _divider(),
          _metricItem("PRÓBKI", "${logger.currentPoints.length}", AppTheme.green),
          _divider(),
          _metricItem(
            "ANOMALIE",
            "${logger.detectedAnomalies.length}",
            logger.detectedAnomalies.isEmpty ? AppTheme.green : AppTheme.red,
          ),
        ],
      ),
    );
  }

  Widget _metricItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 10, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _divider() => Container(width: 1, height: 26, color: AppTheme.border);

  Widget _buildBigActionButton(BuildContext context, DataloggerService logger) {
    final isRec = logger.isRecording;

    return InkWell(
      onTap: () {
        if (isRec) {
          logger.stopRecording();
        } else {
          logger.startRecording();
        }
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: double.infinity,
        height: 100,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isRec
                ? [const Color(0xFFD50000), const Color(0xFFFF1744)]
                : [const Color(0xFF00C853), const Color(0xFF00E676)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: (isRec ? AppTheme.red : AppTheme.green).withAlpha(120),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isRec ? Icons.stop_circle : Icons.play_circle_fill,
              color: Colors.black,
              size: 44,
            ),
            const SizedBox(width: 14),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isRec ? "ZAKOŃCZ POMIAR" : "START POMIARU (WOT)",
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                Text(
                  isRec ? "Dotknij, aby zatrzymać i natychmiast przeanalizować" : "Wbij 3. bieg, wciśnij START i gaz do dechy!",
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveGaugesGrid(LogPoint p) {
    return Column(
      children: [
        // Główny pasek obrotomierza (RPM Gauge)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "OBROTY SILNIKA (RPM)",
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "${p.rpm.toInt()} obr/min",
                    style: TextStyle(
                      color: p.rpm > 6200 ? AppTheme.red : AppTheme.cyan,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      fontFamily: "monospace",
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: (p.rpm / 7500.0).clamp(0.0, 1.0),
                  minHeight: 18,
                  backgroundColor: AppTheme.surfaceLight,
                  color: p.rpm > 6200
                      ? AppTheme.red
                      : (p.rpm > 5000 ? AppTheme.yellow : AppTheme.cyan),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Kafelki 2x2 z kluczowymi zegarami
        Row(
          children: [
            Expanded(
              child: _gaugeCard(
                title: "DOŁADOWANIE",
                value: "${p.boost.toStringAsFixed(2)} bar",
                color: AppTheme.cyan,
                icon: Icons.compress,
                subtext: p.boost > 0 ? "Nadciśnienie" : "Podciśnienie",
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _gaugeCard(
                title: "SKŁAD MIESZANKI",
                value: "${p.afr.toStringAsFixed(1)}:1",
                color: p.afr > 13.2 && p.boost > 0.3 ? AppTheme.red : AppTheme.orange,
                icon: Icons.local_fire_department,
                subtext: p.afr < 12.5 ? "Bogato (Bezpiecznie)" : (p.afr > 13.0 ? "UBOGO!" : "Stechiometrycznie"),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: _gaugeCard(
                title: "ZAPŁON (IGN)",
                value: "${p.ign.toStringAsFixed(1)}°",
                color: p.ign < 5.0 && p.rpm > 3500 ? AppTheme.red : AppTheme.yellow,
                icon: Icons.flash_on,
                subtext: p.ign < 5.0 ? "Podejrzenie retardu" : "Wyprzedzenie",
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _gaugeCard(
                title: "PRZEPUSTNICA (TPS)",
                value: "${p.tps.toInt()}%",
                color: p.tps > 85 ? AppTheme.green : AppTheme.textSecondary,
                icon: Icons.airline_seat_recline_extra,
                subtext: p.tps > 85 ? "WOT (Pełny gaz)" : "Częściowy gaz",
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: _gaugeCard(
                title: "PRZEPŁYW (MAF)",
                value: "${p.maf.toStringAsFixed(0)} g/s",
                color: AppTheme.blue,
                icon: Icons.air,
                subtext: "Masa powietrza",
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _gaugeCard(
                title: "TEMP. DOLOTU (IAT)",
                value: "${p.iat.toStringAsFixed(0)}°C",
                color: p.iat > 55 ? AppTheme.red : AppTheme.cyan,
                icon: Icons.thermostat,
                subtext: "Chłodzenie dolotu",
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _gaugeCard({
    required String title,
    required String value,
    required Color color,
    required IconData icon,
    required String subtext,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Icon(icon, color: color, size: 16),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              fontFamily: "monospace",
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtext,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildPostPullSummary(BuildContext context, DataloggerService logger) {
    final anomalies = logger.detectedAnomalies;
    final hasIssues = anomalies.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: hasIssues ? AppTheme.red.withAlpha(25) : AppTheme.green.withAlpha(25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasIssues ? AppTheme.red : AppTheme.green,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasIssues ? Icons.warning_amber_rounded : Icons.check_circle,
                color: hasIssues ? AppTheme.red : AppTheme.green,
                size: 26,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  hasIssues
                      ? "WYKRYTO NIEPRAWIDŁOWOŚCI (${anomalies.length})"
                      : "PRZYSPIESZENIE WZORCOWE - BRAK BŁĘDÓW!",
                  style: TextStyle(
                    color: hasIssues ? AppTheme.red : AppTheme.green,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            hasIssues
                ? "Algorytm wykrył podejrzane zachowanie silnika (np. cofanie zapłonu lub spadek doładowania). Sprawdź zaznaczone strefy na wykresie i zapoznaj się z podpowiedziami przyczyn."
                : "Parametry silnika pod pełnym obciążeniem mieszczą się w normach bezpieczeństwa. Doładowanie, kąt zapłonu i AFR są stabilne.",
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => onNavigateToTab?.call(3), // Zakładka Wykres
                  icon: const Icon(Icons.show_chart),
                  label: const Text("Pokaż Wykres"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.cyan,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => onNavigateToTab?.call(4), // Zakładka Asystent
                  icon: const Icon(Icons.psychology),
                  label: const Text("Asystent Usterek"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: hasIssues ? AppTheme.red : AppTheme.surfaceLight,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                final report = logger.stopAndGenerateTripReport();
                Navigator.of(context).push(MaterialPageRoute(builder: (context) => TripReportScreen(report: report)));
              },
              icon: const Icon(Icons.description),
              label: const Text("Wygeneruj Raport z Trasy"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
