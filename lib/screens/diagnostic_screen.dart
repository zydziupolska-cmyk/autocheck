import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/anomaly.dart';
import '../services/datalogger_service.dart';
import '../theme/app_theme.dart';

class DiagnosticScreen extends StatelessWidget {
  final void Function(int tabIndex)? onNavigateToTab;

  const DiagnosticScreen({super.key, this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    final logger = Provider.of<DataloggerService>(context);
    final anomalies = logger.detectedAnomalies;
    final session = logger.activeSession;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.psychology, color: AppTheme.cyan),
            SizedBox(width: 8),
            Text("Asystent Diagnostyczny"),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Podsumowanie stanu silnika
            _buildHealthBanner(anomalies),

            const SizedBox(height: 16),

            // Karta parametrów szczytowych
            if (session != null) _buildSessionSummary(session),

            const SizedBox(height: 20),

            // Tytuł listy usterek
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "WYKRYTE USTERKI I ZAGROŻENIA",
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: anomalies.isEmpty ? AppTheme.green.withAlpha(30) : AppTheme.red.withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    "${anomalies.length} wykrytych",
                    style: TextStyle(
                      color: anomalies.isEmpty ? AppTheme.green : AppTheme.red,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (anomalies.isEmpty)
              _buildCleanEngineCard()
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: anomalies.length,
                itemBuilder: (context, index) {
                  return _buildAnomalyCard(context, anomalies[index]);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHealthBanner(List<Anomaly> anomalies) {
    final hasCritical = anomalies.any((a) => a.severity == AnomalySeverity.critical);
    final hasWarning = anomalies.any((a) => a.severity == AnomalySeverity.warning);

    Color color;
    IconData icon;
    String title;
    String desc;

    if (hasCritical) {
      color = AppTheme.red;
      icon = Icons.error_outline;
      title = "WYKRYTO KRYTYCZNE ZAGROŻENIE SILNIKA!";
      desc = "Zarejestrowano nieprawidłowości pod pełnym obciążeniem, które grożą uszkodzeniem silnika (np. uboga mieszanka, duży retard zapłonu lub nagła nieszczelność).";
    } else if (hasWarning) {
      color = AppTheme.orange;
      icon = Icons.warning_amber_rounded;
      title = "WYKRYTO OSTRZEŻENIA WYMAGAJĄCE UWAGI";
      desc = "Silnik pracuje, ale parametry odbiegają od optymalnych. Może występować spadek mocy lub początek usterki osprzętu.";
    } else {
      color = AppTheme.green;
      icon = Icons.check_circle_outline;
      title = "WSZYSTKIE PARAMETRY W NORMIE!";
      desc = "Układ doładowania, kąt wyprzedzenia zapłonu i skład mieszanki paliwowo-powietrznej są w bezpiecznym i stabilnym zakresie.";
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionSummary(dynamic session) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "MAKSYMALNE WARTOŚCI W PRÓBIE",
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _metricTile("MAX RPM", "${session.peakRpm.toInt()}", AppTheme.blue),
              _metricTile("MAX BOOST", "${session.peakBoost.toStringAsFixed(2)} bar", AppTheme.cyan),
              _metricTile("MIN AFR", "${session.minAfr.toStringAsFixed(1)}:1", AppTheme.purple),
              _metricTile("CZAS", "${session.durationSec.toStringAsFixed(1)} s", AppTheme.yellow),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metricTile(String label, String val, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 10)),
        const SizedBox(height: 2),
        Text(val, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildCleanEngineCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Center(
        child: Column(
          children: [
            Icon(Icons.verified, color: AppTheme.green, size: 48),
            SizedBox(height: 10),
            Text(
              "Brak wykrytych anomalii",
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              "Wykres przyspieszenia przebiegł płynnie bez zjawiska cofania zapłonu i spadków ciśnienia.",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnomalyCard(BuildContext context, Anomaly anom) {
    final color = Color(anom.severityColorHex);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: color.withAlpha(120), width: 1.2),
        ),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: CircleAvatar(
            backgroundColor: color.withAlpha(35),
            child: Icon(
              anom.severity == AnomalySeverity.critical ? Icons.dangerous : Icons.warning,
              color: color,
            ),
          ),
          title: Text(
            anom.title,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 2),
              Text(
                "${anom.startSec.toStringAsFixed(1)}s - ${anom.endSec.toStringAsFixed(1)}s (${anom.startRpm.toInt()}..${anom.endRpm.toInt()} RPM)",
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                anom.observedValueText,
                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(color: AppTheme.border),
                  const SizedBox(height: 6),

                  // Ostrzeżenie przed mylnym tropem (np. błąd czujnika vs rzeczywista usterka)
                  if (anom.falseLeadWarning != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.orange.withAlpha(25),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.orange, width: 1.2),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.psychology_alt, color: AppTheme.orange, size: 24),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              anom.falseLeadWarning!,
                              style: const TextStyle(
                                color: Color(0xFFFFD166),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Korelacja wieloczujnikowa (Stan pozostałych czujników w tej samej chwili)
                  if (anom.correlatedSignals != null && anom.correlatedSignals!.isNotEmpty) ...[
                    const Text(
                      "ODCZYTY SKORELOWANYCH CZUJNIKÓW W TYM SAMYM MOMENCIE:",
                      style: TextStyle(color: AppTheme.cyan, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: anom.correlatedSignals!.entries.map((entry) {
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceLight,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.cyan.withAlpha(100)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                "${entry.key}: ",
                                style: const TextStyle(color: AppTheme.cyan, fontSize: 11, fontWeight: FontWeight.w900),
                              ),
                              Text(
                                entry.value,
                                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Przyczyny wykluczone przez inne parametry
                  if (anom.ruledOutCauses != null && anom.ruledOutCauses!.isNotEmpty) ...[
                    const Text(
                      "CO DEFINITYWNIE WYKLUCZAJĄ POZOSTAŁE CZUJNIKI:",
                      style: TextStyle(color: AppTheme.green, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                    ),
                    const SizedBox(height: 6),
                    ...anom.ruledOutCauses!.map((ro) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.check_circle, color: AppTheme.green, size: 14),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  ro,
                                  style: const TextStyle(color: AppTheme.green, fontSize: 12, fontWeight: FontWeight.w500),
                                ),
                              ),
                            ],
                          ),
                        )),
                    const SizedBox(height: 12),
                  ],

                  // Kluczowy wniosek techniczny i mechanizm usterki
                  if (anom.rootCauseConclusion != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.purple.withAlpha(25),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.purple, width: 1.2),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.auto_awesome, color: AppTheme.purple, size: 18),
                              SizedBox(width: 8),
                              Text(
                                "GŁÓWNY WNIOSEK I MECHANIZM USTERKI:",
                                style: TextStyle(color: AppTheme.purple, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.6),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            anom.rootCauseConclusion!,
                            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12.5, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  Text(
                    anom.description,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "CO MOŻE BYĆ PRZYCZYNĄ USTERKI?",
                    style: TextStyle(color: AppTheme.cyan, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                  ),
                  const SizedBox(height: 6),
                  ...anom.hypotheses.map((h) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("• ", style: TextStyle(color: AppTheme.cyan, fontSize: 14)),
                            Expanded(
                              child: Text(h, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
                            ),
                          ],
                        ),
                      )),
                  const SizedBox(height: 12),
                  const Text(
                    "KROK PO KROKU – CO NALEŻY ZROBIĆ / SPRAWDZIĆ:",
                    style: TextStyle(color: AppTheme.orange, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                  ),
                  const SizedBox(height: 6),
                  ...anom.recommendations.map((r) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("✓ ", style: TextStyle(color: AppTheme.orange, fontSize: 14)),
                            Expanded(
                              child: Text(r, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                            ),
                          ],
                        ),
                      )),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => onNavigateToTab?.call(3), // Przejdź do wykresu
                    icon: const Icon(Icons.show_chart),
                    label: const Text("Pokaż to miejsce na wykresie"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.cyan,
                      side: const BorderSide(color: AppTheme.cyan),
                      minimumSize: const Size.fromHeight(40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  }
}
