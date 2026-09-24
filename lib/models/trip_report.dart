import 'anomaly.dart';

class TripReport {
  final Duration duration;
  final double distanceKm;
  final int totalPoints;
  final double maxRpm;
  final double maxBoostBar;
  final double maxEctC; // Coolant Temp
  final double maxIatC; // Intake Air Temp
  final double avgLtft; // Długa korekta (Average)
  
  // Zgrupowane usterki (np. 5x "Boost Leak" scalamy w jeden obiekt + ilość wystąpień)
  final List<AggregatedAnomaly> aggregatedAnomalies;
  
  final int healthScore; // 0-100%

  const TripReport({
    required this.duration,
    required this.distanceKm,
    required this.totalPoints,
    required this.maxRpm,
    required this.maxBoostBar,
    required this.maxEctC,
    required this.maxIatC,
    required this.avgLtft,
    required this.aggregatedAnomalies,
    required this.healthScore,
  });

  bool get isHealthy => healthScore >= 80;
  bool get needsAttention => healthScore >= 40 && healthScore < 80;
  bool get criticalCondition => healthScore < 40;
}

class AggregatedAnomaly {
  final Anomaly sample;
  final int occurrenceCount;
  
  const AggregatedAnomaly({
    required this.sample,
    required this.occurrenceCount,
  });
}
