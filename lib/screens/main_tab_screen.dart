import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/datalogger_service.dart';
import '../theme/app_theme.dart';
import 'connection_screen.dart';
import 'sensor_select_screen.dart';
import 'logger_screen.dart';
import 'chart_screen.dart';
import 'diagnostic_screen.dart';
import 'logs_history_screen.dart';

class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _currentIndex = 2; // Domyślnie na ekranie Rejestratora (gotowy do kliknięcia START!)

  void _switchTab(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final logger = Provider.of<DataloggerService>(context);
    final anomalyCount = logger.detectedAnomalies.length;

    final screens = [
      const ConnectionScreen(),
      const SensorSelectScreen(),
      LoggerScreen(onNavigateToTab: _switchTab),
      ChartScreen(onNavigateToTab: _switchTab),
      DiagnosticScreen(onNavigateToTab: _switchTab),
      LogsHistoryScreen(onNavigateToTab: _switchTab),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: _switchTab,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            const NavigationDestination(icon: Icon(Icons.bluetooth), label: "Połączenie"),
            const NavigationDestination(icon: Icon(Icons.tune), label: "Parametry"),
            const NavigationDestination(icon: Icon(Icons.speed), label: "Rejestrator"),
            const NavigationDestination(icon: Icon(Icons.show_chart), label: "Wykres"),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: anomalyCount > 0,
                label: Text("$anomalyCount"),
                child: const Icon(Icons.fact_check_outlined),
              ),
              label: "Diagnoza",
            ),
            const NavigationDestination(icon: Icon(Icons.history), label: "Historia"),
          ],
        ),
      ),
    );
  }
}
