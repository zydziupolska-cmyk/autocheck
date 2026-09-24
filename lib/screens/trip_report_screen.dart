import 'package:flutter/material.dart';
import '../models/trip_report.dart';

class TripReportScreen extends StatelessWidget {
  final TripReport report;

  const TripReportScreen({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: const Text("Raport z Trasy"),
        backgroundColor: const Color(0xFF2C2C2C),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHealthHeader(),
            const SizedBox(height: 24),
            _buildStatsGrid(),
            const SizedBox(height: 24),
            _buildAnomaliesList(),
          ],
        ),
      ),
    );
  }

  Widget _buildHealthHeader() {
    Color color = Colors.green;
    IconData icon = Icons.check_circle_outline;
    String status = "Silnik w świetnej kondycji!";
    String subtitle = "Nie wykryto żadnych przewlekłych usterek w trakcie jazdy.";

    if (report.criticalCondition) {
      color = Colors.redAccent;
      icon = Icons.warning_amber_rounded;
      status = "Wykryto Poważne Usterki!";
      subtitle = "Twoje auto wymaga natychmiastowej wizyty w warsztacie.";
    } else if (report.needsAttention) {
      color = Colors.orangeAccent;
      icon = Icons.handyman_outlined;
      status = "Wymaga Uwagi";
      subtitle = "Odnaleziono problemy, które mogą wpłynąć na spalanie lub moc.";
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.5), width: 2),
      ),
      child: Column(
        children: [
          Icon(icon, size: 64, color: color),
          const SizedBox(height: 16),
          Text(
            status,
            style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Text(
            "Wynik Zdrowia: ${report.healthScore}%",
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Ciekawostki Telemetryczne",
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 2.5,
          children: [
            _statCard(Icons.timer, "Czas Trwania", "${report.duration.inMinutes} min"),
            _statCard(Icons.route, "Dystans (est.)", "${report.distanceKm.toStringAsFixed(1)} km"),
            _statCard(Icons.speed, "Max RPM", report.maxRpm.toStringAsFixed(0)),
            _statCard(Icons.air, "Max Boost", "${report.maxBoostBar.toStringAsFixed(2)} bar"),
            _statCard(Icons.thermostat, "Max Temp Płynu", "${report.maxEctC.toStringAsFixed(0)} °C"),
            _statCard(Icons.water_drop, "Śr. LTFT", "${report.avgLtft.toStringAsFixed(1)} %"),
          ],
        ),
      ],
    );
  }

  Widget _statCard(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.blueAccent, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnomaliesList() {
    if (report.aggregatedAnomalies.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Odnalezione Czerwone Flagi",
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ...report.aggregatedAnomalies.map((agg) => _buildAnomalyCard(agg)),
      ],
    );
  }

  Widget _buildAnomalyCard(AggregatedAnomaly agg) {
    final anomaly = agg.sample;
    final color = Color(anomaly.severityColorHex);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  anomaly.severityLabel,
                  style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              if (agg.occurrenceCount > 1)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    "${agg.occurrenceCount}x Wystąpień",
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            anomaly.title,
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            anomaly.description,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          if (anomaly.recommendations.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              "Co zrobić?",
              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            ...anomaly.recommendations.map((r) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("• ", style: TextStyle(color: Colors.blueAccent, fontSize: 14, fontWeight: FontWeight.bold)),
                Expanded(child: Text(r, style: const TextStyle(color: Colors.white70, fontSize: 14))),
              ],
            )),
          ]
        ],
      ),
    );
  }
}
