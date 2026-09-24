import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/obd_pid.dart';
import '../services/datalogger_service.dart';
import '../services/obd_service.dart';
import '../theme/app_theme.dart';

class SensorSelectScreen extends StatelessWidget {
  const SensorSelectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final obd = Provider.of<ObdService>(context);
    final logger = Provider.of<DataloggerService>(context);
    final availablePids = obd.discoveredPids;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.tune, color: AppTheme.cyan),
            SizedBox(width: 8),
            Text("Wybór Czujników"),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Podsumowanie wyboru i szacowany FPS
            _buildSamplingInfoCard(logger.selectedPidKeys.length),

            const SizedBox(height: 16),

            // Szybkie presety
            const Text(
              "SZYBKIE PROFILE LOGOWANIA",
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 8),
            _buildPresetSelector(logger),

            const SizedBox(height: 20),

            // Lista czujników z podziałem
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "DOSTĘPNE CZUJNIKI W POJEŹDZIE",
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    for (final p in availablePids) {
                      if (!logger.selectedPidKeys.contains(p.shortName)) {
                        logger.togglePid(p.shortName);
                      }
                    }
                  },
                  child: const Text("Zaznacz wszystkie", style: TextStyle(color: AppTheme.cyan, fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 6),

            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: availablePids.length,
              itemBuilder: (context, index) {
                final pid = availablePids[index];
                final isSelected = logger.selectedPidKeys.contains(pid.shortName);

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.surfaceLight : AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? Color(pid.colorValue) : AppTheme.border,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Color(pid.colorValue).withAlpha(30),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          pid.shortName,
                          style: TextStyle(
                            color: Color(pid.colorValue),
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                    title: Text(
                      pid.name,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      pid.simulatorOnly
                          ? "Tylko w symulatorze (brak standardowego PID-u OBD-II) | Jednostka: ${pid.unit}"
                          : "Kod: ${pid.code} | Jednostka: ${pid.unit} | Zakres: ${pid.minExpected.toInt()}..${pid.maxExpected.toInt()}",
                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                    trailing: Switch(
                      value: isSelected,
                      activeThumbColor: Color(pid.colorValue),
                      onChanged: (_) => logger.togglePid(pid.shortName),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSamplingInfoCard(int selectedCount) {
    // Na vLinker MC+ średni czas na 1 zapytanie PID po magistrali CAN to ok. 10-15ms
    final estHz = (selectedCount > 0) ? (250.0 / (selectedCount * 12.0)).clamp(5.0, 45.0) : 0.0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: AppTheme.surfaceLight,
            child: Icon(Icons.speed, color: AppTheme.cyan),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Wybrano: $selectedCount czujników",
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "Szacowana prędkość odświeżania na vLinker MC+: ~${estHz.toStringAsFixed(0)} próbek/s (Hz)",
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 4),
                const Text(
                  "Wskazówka: Do logowania WOT na jednym biegu wybierz 4-6 parametrów, aby uzyskać gęsty i precyzyjny wykres.",
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetSelector(DataloggerService logger) {
    return Column(
      children: LoggingPreset.presets.map((preset) {
        final isApplied = preset.pidShortNames.every((p) => logger.selectedPidKeys.contains(p)) &&
            preset.pidShortNames.length == logger.selectedPidKeys.length;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: isApplied ? AppTheme.cyan.withAlpha(20) : AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isApplied ? AppTheme.cyan : AppTheme.border,
              width: isApplied ? 1.5 : 1,
            ),
          ),
          child: ListTile(
            title: Text(
              preset.title,
              style: TextStyle(
                color: isApplied ? AppTheme.cyan : AppTheme.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            subtitle: Text(
              preset.description,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
            ),
            trailing: isApplied
                ? const Icon(Icons.check_circle, color: AppTheme.cyan)
                : ElevatedButton(
                    onPressed: () => logger.applyPreset(preset),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.surfaceLight,
                      foregroundColor: AppTheme.textPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                    child: const Text("Użyj", style: TextStyle(fontSize: 12)),
                  ),
          ),
        );
      }).toList(),
    );
  }
}
